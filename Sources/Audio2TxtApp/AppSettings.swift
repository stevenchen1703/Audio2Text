import Foundation

struct AppSettings: Codable, Equatable {
    var volcAppKey: String = ""
    var volcAccessKey: String = ""
    var volcResourceId: String = "volc.lark.minutes"

    var tosRegion: String = "cn-beijing"
    var tosEndpoint: String = "tos-cn-beijing.volces.com"
    var tosBucket: String = ""
    var tosAK: String = ""
    var tosSK: String = ""
    var tosStsToken: String = ""

    var tosObjectPrefix: String = "audio2txt/"
    var tosSignExpiresSec: Int = 14400
    var pollIntervalSec: Int = 30
    var maxWaitMin: Int = 120
    var maxConcurrentJobs: Int = 10
    var deleteTempObject: Bool = true
    var saveRawJSON: Bool = false
    var translationEnabled: Bool = false
    var translationSourceLang: String = "en_us"
    var translationTargetLang: String = "zh_cn"
    var completionSoundEnabled: Bool = true

    func mergedEnv(base: [String: String]) -> [String: String] {
        var env = base
        setIfNonEmpty(&env, "VOLC_APP_KEY", volcAppKey)
        setIfNonEmpty(&env, "VOLC_ACCESS_KEY", volcAccessKey)
        setIfNonEmpty(&env, "VOLC_RESOURCE_ID", volcResourceId)

        setIfNonEmpty(&env, "TOS_REGION", tosRegion)
        setIfNonEmpty(&env, "TOS_ENDPOINT", tosEndpoint)
        setIfNonEmpty(&env, "TOS_BUCKET", tosBucket)
        setIfNonEmpty(&env, "TOS_AK", tosAK)
        setIfNonEmpty(&env, "TOS_SK", tosSK)
        setIfNonEmpty(&env, "TOS_STS_TOKEN", tosStsToken)

        setIfNonEmpty(&env, "TOS_OBJECT_PREFIX", tosObjectPrefix)
        env["TOS_SIGN_EXPIRES_SEC"] = String(max(60, tosSignExpiresSec))
        env["POLL_INTERVAL_SEC"] = String(max(1, pollIntervalSec))
        env["MAX_WAIT_MIN"] = String(max(1, maxWaitMin))
        env["MAX_CONCURRENT_JOBS"] = String(max(1, maxConcurrentJobs))
        env["DELETE_TEMP_OBJECT"] = deleteTempObject ? "true" : "false"
        env["SAVE_RAW_JSON"] = saveRawJSON ? "true" : "false"
        env["TRANSLATION_ENABLE"] = translationEnabled ? "true" : "false"
        setIfNonEmpty(&env, "TRANSLATION_SOURCE_LANG", translationSourceLang)
        setIfNonEmpty(&env, "TRANSLATION_TARGET_LANG", translationTargetLang)
        return env
    }

    private func setIfNonEmpty(_ env: inout [String: String], _ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            env[key] = trimmed
        }
    }
}

enum AppSettingsStore {
    private static let storageKey = "audio2txt.app.settings.v1"

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        var normalized = decoded
        // 保证默认行为：raw json 默认关闭；如旧配置为 true，则自动回写为 false
        if normalized.saveRawJSON {
            normalized.saveRawJSON = false
            save(normalized)
        }
        return normalized
    }

    static func save(_ settings: AppSettings) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
