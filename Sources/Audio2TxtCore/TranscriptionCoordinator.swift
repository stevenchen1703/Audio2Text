import Foundation
import AVFoundation

public final class TranscriptionCoordinator: @unchecked Sendable {
    public struct Result: Sendable {
        public let text: String
        public let taskID: String
        public let tosObjectKey: String
        public let rawJSONData: Data
        public let audioDurationMs: Int?
        public let summaryText: String?
        public let summaryKeywords: [String]
        public let translationText: String?
    }

    private let config: AppConfig
    private let tosClient: TOSClient
    private let minutesClient: VolcMinutesClient

    public init(config: AppConfig) {
        self.config = config
        self.tosClient = TOSClient(config: config)
        self.minutesClient = VolcMinutesClient(config: config)
    }

    public func transcribe(
        audioFileURL: URL,
        logger: @Sendable @escaping (String) -> Void,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        progress?(0.02)
        let uploaded = try await tosClient.uploadAudio(fileURL: audioFileURL, logger: logger)
        progress?(0.18)
        logger("音频上传完成，已生成临时可访问 URL")

        let requestID = UUID().uuidString.lowercased()
        logger("提交妙记任务")
        let taskID = try await submitWithRetry(fileURL: uploaded.signedGetURL, requestID: requestID, logger: logger)
        progress?(0.25)
        logger("任务已提交，TaskID=\(taskID)")

        let deadline = Date().addingTimeInterval(TimeInterval(config.maxWaitMin * 60))
        var finalQuery: QueryResult?
        var rateLimitBackoffSec = max(config.pollIntervalSec, 5)
        var networkBackoffSec = 3

        while Date() < deadline {
            let queryResult: QueryResult
            do {
                queryResult = try await minutesClient.query(taskID: taskID, requestID: requestID)
                rateLimitBackoffSec = max(config.pollIntervalSec, 5)
                networkBackoffSec = 3
            } catch {
                if isHTTP429(error) {
                    rateLimitBackoffSec = min(rateLimitBackoffSec * 2, 180)
                    let waitSec = rateLimitBackoffSec + Int.random(in: 0...6)
                    logger("查询触发限流(429)，\(waitSec)s 后重试")
                    try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                    continue
                }
                if isTransientNetworkError(error) {
                    networkBackoffSec = min(networkBackoffSec * 2, 45)
                    let waitSec = networkBackoffSec + Int.random(in: 0...4)
                    logger("查询网络波动(\((error as NSError).localizedDescription))，\(waitSec)s 后重试")
                    try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                    continue
                }
                throw error
            }
            finalQuery = queryResult

            switch queryResult.status {
            case .success:
                progress?(0.96)
                logger("任务完成 ✅ ，开始下载结果 ⏬")
                guard let fileURL = queryResult.transcriptionFileURL else {
                    throw Audio2TxtError.parseFailed("任务成功但缺少 AudioTranscriptionFile")
                }
                let jsonData = try await minutesClient.downloadTranscriptionJSON(from: fileURL)
                let durationMs = audioDurationMs(for: audioFileURL)
                let text = TranscriptFormatter.renderTXT(fromJSONData: jsonData, expectedDurationMs: durationMs)
                var summaryText: String?
                var keywords: [String] = []
                var translationText: String?
                if let summarizationURL = queryResult.summarizationFileURL {
                    do {
                        let summaryData = try await minutesClient.downloadTranscriptionJSON(from: summarizationURL)
                        let summaryContent = SummaryKeywordExtractor.extractContent(fromJSONData: summaryData)
                        summaryText = summaryContent.summaryText
                        keywords = summaryContent.keywords
                        if let summaryText, !summaryText.isEmpty {
                            logger("全文总结提取成功")
                        } else if !keywords.isEmpty {
                            logger("全文总结未命中正文，关键词提取成功: \(keywords.count) 个")
                        } else {
                            logger("全文总结已返回，但未提取到正文/关键词")
                        }
                    } catch {
                        logger("全文总结下载/解析失败(已忽略): \(error.localizedDescription)")
                    }
                }

                if config.translationEnabled, let translationURL = queryResult.translationFileURL {
                    do {
                        let translationData = try await minutesClient.downloadTranscriptionJSON(from: translationURL)
                        translationText = TranslationFormatter.render(fromJSONData: translationData)
                        if translationText?.isEmpty == false {
                            logger("翻译结果提取成功")
                        } else {
                            logger("翻译结果已返回，但未提取到有效文本")
                        }
                    } catch {
                        logger("翻译结果下载/解析失败(已忽略): \(error.localizedDescription)")
                    }
                }

                if config.deleteTemporaryObject {
                    await tosClient.deleteObject(key: uploaded.key, logger: logger)
                }
                progress?(1.0)
                return Result(
                    text: text,
                    taskID: taskID,
                    tosObjectKey: uploaded.key,
                    rawJSONData: jsonData,
                    audioDurationMs: durationMs,
                    summaryText: summaryText,
                    summaryKeywords: keywords,
                    translationText: translationText
                )

            case .failed:
                let message = queryResult.errMessage ?? "未知错误"
                if config.deleteTemporaryObject {
                    await tosClient.deleteObject(key: uploaded.key, logger: logger)
                }
                throw Audio2TxtError.requestFailed("妙记任务失败: \(message)")

            case .running, .unknown:
                if let p = queryResult.progressPercent {
                    let normalized = 0.25 + max(0.0, min(100.0, p)) / 100.0 * 0.70
                    progress?(normalized)
                    let waitSec = config.pollIntervalSec + Int.random(in: 0...4)
                    logger("任务进行中，进度约 \(Int(p.rounded()))%，\(waitSec)s 后重试")
                    try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                } else {
                    progress?(0.30)
                    let waitSec = config.pollIntervalSec + Int.random(in: 0...4)
                    logger("任务进行中，\(waitSec)s 后重试")
                    try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                }
            }
        }

        if config.deleteTemporaryObject {
            await tosClient.deleteObject(key: uploaded.key, logger: logger)
        }
        let err = finalQuery?.errMessage ?? "超时未完成"
        throw Audio2TxtError.timeout(err)
    }

    private func audioDurationMs(for fileURL: URL) -> Int? {
        let asset = AVURLAsset(url: fileURL)
        let sec = CMTimeGetSeconds(asset.duration)
        guard sec.isFinite, sec > 0 else { return nil }
        return Int((sec * 1000).rounded())
    }

    private func isHTTP429(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("http 429") || message.contains(" 429")
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .dataNotAllowed,
                 .internationalRoamingOff,
                 .callIsActive,
                 .cannotLoadFromNetwork,
                 .resourceUnavailable:
                return true
            default:
                break
            }
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("网络连接已中断")
            || message.contains("network connection was lost")
            || message.contains("timed out")
            || message.contains("not connected")
    }

    private func submitWithRetry(
        fileURL: URL,
        requestID: String,
        logger: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        var backoffSec = 4
        let maxAttempts = 6

        for attempt in 1...maxAttempts {
            do {
                return try await minutesClient.submit(fileURL: fileURL, requestID: requestID)
            } catch {
                if isSubmitQPSLimited(error), attempt < maxAttempts {
                    let waitSec = backoffSec + Int.random(in: 0...3)
                    logger("提交触发 QPS 限流，\(waitSec)s 后重试（\(attempt)/\(maxAttempts)）")
                    try await Task.sleep(nanoseconds: UInt64(waitSec) * 1_000_000_000)
                    backoffSec = min(backoffSec * 2, 45)
                    continue
                }
                throw error
            }
        }
        throw Audio2TxtError.requestFailed("submit 重试次数耗尽")
    }

    private func isSubmitQPSLimited(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("45000292")
            || message.contains("quota exceeded for types: qps")
            || message.contains("qps")
    }
}
