import Foundation

public enum EnvLoader {
    public static func load(from path: String = ".env") throws -> [String: String] {
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let envURL = URL(fileURLWithPath: path, relativeTo: cwdURL)

        guard FileManager.default.fileExists(atPath: envURL.path) else {
            throw Audio2TxtError.missingConfig(".env 文件不存在: \(envURL.path)")
        }

        let content = try String(contentsOf: envURL, encoding: .utf8)
        var result: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let splitIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: splitIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }
}
