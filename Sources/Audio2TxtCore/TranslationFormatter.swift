import Foundation

enum TranslationFormatter {
    private struct Line {
        let startMs: Int
        let text: String
    }

    static func render(fromJSONData data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
            let lines = extractLines(from: obj)
            if !lines.isEmpty {
                return lines
                    .sorted(by: { $0.startMs < $1.startMs })
                    .map { "\(formatMs($0.startMs))\n\($0.text)" }
                    .joined(separator: "\n\n")
            }
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }

    private static func extractLines(from node: Any) -> [Line] {
        var lines: [Line] = []
        walk(node, out: &lines)
        return dedup(lines)
    }

    private static func walk(_ node: Any, out: inout [Line]) {
        if let dict = node as? [String: Any] {
            if let line = parseLine(dict) {
                out.append(line)
            }
            for value in dict.values {
                walk(value, out: &out)
            }
            return
        }
        if let array = node as? [Any] {
            for item in array {
                walk(item, out: &out)
            }
        }
    }

    private static func parseLine(_ dict: [String: Any]) -> Line? {
        let textKeys = [
            "translation_content", "TranslationContent", "translationContent",
            "translation", "Translation",
            "text", "Text",
            "content", "Content",
            "sentence", "Sentence",
            "value", "Value"
        ]
        var text: String?
        for key in textKeys {
            if let raw = dict[key] as? String {
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    text = normalized
                    break
                }
            }
        }
        guard let text else { return nil }

        guard let startMs = detectTimeMs(
            dict,
            keys: [
                "start_ms", "StartMs", "startMs",
                "start_time_ms", "StartTimeMs",
                "start_time", "StartTime",
                "start", "Start",
                "offset", "Offset",
                "timestamp", "Timestamp"
            ]
        ) else { return nil }

        return Line(startMs: startMs, text: text)
    }

    private static func detectTimeMs(_ dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key], let ms = toMs(value, key: key) {
                return ms
            }
        }
        return nil
    }

    private static func toMs(_ value: Any, key: String) -> Int? {
        let n: Double?
        switch value {
        case let v as Int:
            n = Double(v)
        case let v as Double:
            n = v
        case let v as NSNumber:
            n = v.doubleValue
        case let v as String:
            n = Double(v)
        default:
            n = nil
        }
        guard let n, n.isFinite else { return nil }

        let lower = key.lowercased()
        if lower.contains("ms") { return Int(n.rounded()) }
        if lower == "start_time" || lower == "end_time" || lower == "starttime" || lower == "endtime" {
            if n >= 1000 { return Int(n.rounded()) }
            return Int((n * 1000).rounded())
        }
        if n > 100_000 { return Int(n.rounded()) }
        return Int((n * 1000).rounded())
    }

    private static func dedup(_ lines: [Line]) -> [Line] {
        var seen: Set<String> = []
        var result: [Line] = []
        for line in lines {
            let key = "\(line.startMs)|\(line.text)"
            if seen.insert(key).inserted {
                result.append(line)
            }
        }
        return result
    }

    private static func formatMs(_ ms: Int) -> String {
        let sec = max(0, ms) / 1000
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
