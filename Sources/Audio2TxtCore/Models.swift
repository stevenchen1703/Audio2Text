import Foundation

public struct AppConfig: Sendable {
    public let volcAppKey: String
    public let volcAccessKey: String
    public let volcResourceId: String

    public let tosRegion: String
    public let tosEndpoint: String
    public let tosBucket: String
    public let tosAccessKey: String
    public let tosSecretKey: String
    public let tosSecurityToken: String?
    public let tosObjectPrefix: String
    public let tosSignExpiresSec: Int

    public let pollIntervalSec: Int
    public let maxWaitMin: Int
    public let maxConcurrentJobs: Int
    public let deleteTemporaryObject: Bool
    public let saveRawJSON: Bool
    public let translationEnabled: Bool
    public let translationSourceLang: String
    public let translationTargetLang: String

    public init(env: [String: String]) throws {
        self.volcAppKey = try AppConfig.required("VOLC_APP_KEY", env)
        self.volcAccessKey = try AppConfig.required("VOLC_ACCESS_KEY", env)
        self.volcResourceId = env["VOLC_RESOURCE_ID"] ?? "volc.lark.minutes"

        self.tosRegion = try AppConfig.required("TOS_REGION", env)
        self.tosEndpoint = try AppConfig.required("TOS_ENDPOINT", env)
        self.tosBucket = try AppConfig.required("TOS_BUCKET", env)
        self.tosAccessKey = try AppConfig.required("TOS_AK", env)
        self.tosSecretKey = try AppConfig.required("TOS_SK", env)
        self.tosSecurityToken = env["TOS_STS_TOKEN"]
        self.tosObjectPrefix = env["TOS_OBJECT_PREFIX"] ?? "audio2txt/"
        self.tosSignExpiresSec = Int(env["TOS_SIGN_EXPIRES_SEC"] ?? "14400") ?? 14400

        self.pollIntervalSec = Int(env["POLL_INTERVAL_SEC"] ?? "30") ?? 30
        self.maxWaitMin = Int(env["MAX_WAIT_MIN"] ?? "120") ?? 120
        self.maxConcurrentJobs = max(1, Int(env["MAX_CONCURRENT_JOBS"] ?? "2") ?? 2)
        self.deleteTemporaryObject = (env["DELETE_TEMP_OBJECT"] ?? "true").lowercased() == "true"
        self.saveRawJSON = (env["SAVE_RAW_JSON"] ?? "true").lowercased() == "true"
        self.translationEnabled = (env["TRANSLATION_ENABLE"] ?? "false").lowercased() == "true"
        self.translationSourceLang = env["TRANSLATION_SOURCE_LANG"] ?? "en_us"
        self.translationTargetLang = env["TRANSLATION_TARGET_LANG"] ?? "zh_cn"
    }

    private static func required(_ key: String, _ env: [String: String]) throws -> String {
        guard let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Audio2TxtError.missingConfig(key)
        }
        return value
    }
}

public struct UploadedObject: Sendable {
    public let key: String
    public let signedGetURL: URL
}

public struct TranscriptSegment: Hashable, Sendable {
    public let startMs: Int
    public let endMs: Int?
    public let speaker: String?
    public let text: String

    public init(startMs: Int, endMs: Int?, speaker: String?, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }
}

public enum JobStatus: String, Sendable {
    case running
    case success
    case failed
    case unknown
}

public struct QueryResult: Sendable {
    public let status: JobStatus
    public let errCode: Int?
    public let errMessage: String?
    public let transcriptionFileURL: URL?
    public let summarizationFileURL: URL?
    public let translationFileURL: URL?
    public let progressPercent: Double?
}

public enum Audio2TxtError: Error, LocalizedError {
    case missingConfig(String)
    case invalidURL(String)
    case requestFailed(String)
    case parseFailed(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let key):
            return "缺少配置项: \(key)"
        case .invalidURL(let message):
            return "URL 无效: \(message)"
        case .requestFailed(let message):
            return "请求失败: \(message)"
        case .parseFailed(let message):
            return "解析失败: \(message)"
        case .timeout(let message):
            return "超时: \(message)"
        }
    }
}
