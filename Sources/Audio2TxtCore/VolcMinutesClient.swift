import Foundation

public final class VolcMinutesClient: @unchecked Sendable {
    private let config: AppConfig
    private let session: URLSession

    public init(config: AppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func submit(fileURL: URL, requestID: String) async throws -> String {
        guard let url = URL(string: "https://openspeech.bytedance.com/api/v3/auc/lark/submit") else {
            throw Audio2TxtError.invalidURL("submit 地址无效")
        }

        let baseBody: [String: Any] = [
            "Input": [
                "Offline": [
                    "FileURL": fileURL.absoluteString,
                    "FileType": "audio"
                ]
            ],
            "Params": [
                "AllActivate": false,
                "SourceLang": config.translationEnabled ? config.translationSourceLang : "zh_cn",
                "AudioTranscriptionEnable": true,
                "AudioTranscriptionParams": [
                    "SpeakerIdentification": true,
                    "NumberOfSpeaker": 0,
                    "HotWords": "",
                    "NeedWordTimeSeries": false
                ],
                // 仅启用“全文总结”单功能，避免开启集合功能导致额外计费。
                "SummarizationEnabled": true,
                "SummarizationParams": [
                    "Types": ["summary"]
                ],
                "TranslationEnable": config.translationEnabled,
                "TranslationParams": [
                    "TargetLang": config.translationTargetLang
                ],
                "InformationExtractionEnabled": false,
                "ChapterEnabled": false
            ]
        ]

        return try await submitOnce(url: url, requestID: requestID, body: baseBody)
    }

    public func query(taskID: String, requestID _: String) async throws -> QueryResult {
        guard let url = URL(string: "https://openspeech.bytedance.com/api/v3/auc/lark/query") else {
            throw Audio2TxtError.invalidURL("query 地址无效")
        }

        let body: [String: Any] = ["TaskID": taskID]
        let request = try makeRequest(url: url, requestID: taskID, includeSequence: true, jsonBody: body)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, context: "query")

        let json = try parseJSONDictionary(data)
        let dataObject = json["Data"] as? [String: Any] ?? [:]
        let statusRaw = (dataObject["Status"] as? String ?? "").lowercased()
        let status = JobStatus(rawValue: statusRaw) ?? .unknown
        let errCode = dataObject["ErrCode"] as? Int
        let errMessage = dataObject["ErrMessage"] as? String
        let progress = extractProgressPercent(from: dataObject)

        let resultObj = dataObject["Result"] as? [String: Any] ?? [:]
        let fileURLString = resultObj["AudioTranscriptionFile"] as? String
        let fileURL = fileURLString.flatMap { URL(string: $0) }
        let summarizationURLString = resultObj["SummarizationFile"] as? String
        let summarizationURL = summarizationURLString.flatMap { URL(string: $0) }
        let translationURLString = resultObj["TranslationFile"] as? String
        let translationURL = translationURLString.flatMap { URL(string: $0) }

        return QueryResult(
            status: status,
            errCode: errCode,
            errMessage: errMessage,
            transcriptionFileURL: fileURL,
            summarizationFileURL: summarizationURL,
            translationFileURL: translationURL,
            progressPercent: progress
        )
    }

    public func downloadTranscriptionJSON(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response: response, context: "下载转写结果")
        return data
    }

    private func makeRequest(url: URL, requestID: String, includeSequence: Bool, jsonBody: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.volcAppKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.volcAccessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(config.volcResourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        if includeSequence {
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        return request
    }

    private func validateHTTP(response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw Audio2TxtError.requestFailed("\(context) 无 HTTP 响应")
        }
        guard 200..<300 ~= http.statusCode else {
            throw Audio2TxtError.requestFailed("\(context) HTTP \(http.statusCode)")
        }
    }

    private func parseJSONDictionary(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw Audio2TxtError.parseFailed("响应不是 JSON 对象")
        }
        return dict
    }

    private func submitOnce(url: URL, requestID: String, body: [String: Any]) async throws -> String {
        let request = try makeRequest(url: url, requestID: requestID, includeSequence: true, jsonBody: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Audio2TxtError.requestFailed("submit 无 HTTP 响应")
        }
        guard 200..<300 ~= http.statusCode else {
            let errorText = String(data: data, encoding: .utf8) ?? "submit HTTP \(http.statusCode)"
            throw Audio2TxtError.requestFailed(errorText)
        }

        let json = try parseJSONDictionary(data)
        let statusHeader = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let messageHeader = http.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        if !statusHeader.isEmpty, statusHeader != "20000000", statusHeader != "0" {
            let bodyMessage = (json["Message"] as? String) ?? (json["message"] as? String) ?? ""
            let finalMessage = [messageHeader, bodyMessage]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            throw Audio2TxtError.requestFailed("submit 业务失败(\(statusHeader)): \(finalMessage)")
        }

        if let taskID = extractTaskID(from: json), !taskID.isEmpty {
            return taskID
        }
        let snippet = (String(data: data, encoding: .utf8) ?? "")
            .prefix(600)
            .replacingOccurrences(of: "\n", with: " ")
        throw Audio2TxtError.parseFailed("submit 返回中缺少 TaskID，响应片段: \(snippet)")
    }

    private func extractTaskID(from json: [String: Any]) -> String? {
        let dataObj = (json["Data"] as? [String: Any]) ?? (json["data"] as? [String: Any]) ?? [:]
        let keys = ["TaskID", "TaskId", "task_id", "taskId"]
        for key in keys {
            if let text = dataObj[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let num = dataObj[key] as? NSNumber {
                return num.stringValue
            }
        }

        for key in keys {
            if let text = json[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let num = json[key] as? NSNumber {
                return num.stringValue
            }
        }
        return nil
    }

    private func extractProgressPercent(from dataObject: [String: Any]) -> Double? {
        let keys = ["Progress", "progress", "Process", "process", "Percent", "percent"]
        for key in keys {
            if let v = parseNumericPercent(dataObject[key]) {
                return v
            }
        }
        if let result = dataObject["Result"] as? [String: Any] {
            for key in keys {
                if let v = parseNumericPercent(result[key]) {
                    return v
                }
            }
        }
        return nil
    }

    private func parseNumericPercent(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        let value: Double?
        switch raw {
        case let d as Double:
            value = d
        case let i as Int:
            value = Double(i)
        case let n as NSNumber:
            value = n.doubleValue
        case let s as String:
            value = Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""))
        default:
            value = nil
        }
        guard let v = value, v.isFinite else { return nil }
        if v <= 1.0 {
            return max(0.0, min(100.0, v * 100.0))
        }
        return max(0.0, min(100.0, v))
    }
}
