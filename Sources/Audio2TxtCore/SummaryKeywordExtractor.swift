import Foundation

struct SummaryContent: Sendable {
    let summaryText: String?
    let keywords: [String]
}

enum SummaryKeywordExtractor {
    static func extractContent(fromJSONData data: Data) -> SummaryContent {
        // 部分 SummarizationFile 可能直接返回纯文本而不是 JSON。
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, text.count >= 12 {
                return SummaryContent(summaryText: text, keywords: [])
            }
            return SummaryContent(summaryText: nil, keywords: [])
        }

        var keywordCandidates: [String] = []
        var summaryCandidates: [String] = []
        var genericLongTextCandidates: [String] = []
        collect(from: obj, parentKey: nil, keywords: &keywordCandidates, summaries: &summaryCandidates)
        collectGenericLongText(from: obj, out: &genericLongTextCandidates)

        let keywords = dedupKeywords(keywordCandidates)
        let summary = bestSummary(from: summaryCandidates) ?? bestSummary(from: genericLongTextCandidates)

        return SummaryContent(summaryText: summary, keywords: keywords)
    }

    private static func collect(from node: Any, parentKey: String?, keywords: inout [String], summaries: inout [String]) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                let lower = key.lowercased()
                if lower.contains("keyword") || key.contains("关键词") {
                    appendKeywordValue(value, out: &keywords)
                }
                if lower.contains("summary") || key.contains("总结") || key.contains("摘要") {
                    appendSummaryValue(value, out: &summaries)
                }
                collect(from: value, parentKey: key, keywords: &keywords, summaries: &summaries)
            }
            return
        }

        if let array = node as? [Any] {
            for item in array {
                collect(from: item, parentKey: parentKey, keywords: &keywords, summaries: &summaries)
            }
            return
        }

        if let p = parentKey?.lowercased(), p.contains("keyword"), let text = node as? String {
            keywords.append(contentsOf: splitKeywordLine(text))
        }
        if let p = parentKey?.lowercased(), (p.contains("summary") || p.contains("摘要") || p.contains("总结")), let text = node as? String {
            summaries.append(text)
        }
    }

    private static func appendSummaryValue(_ value: Any, out: inout [String]) {
        if let text = value as? String {
            let normalized = normalizeSummary(text)
            if !normalized.isEmpty {
                out.append(normalized)
            }
            return
        }

        if let array = value as? [Any] {
            for item in array {
                if let text = item as? String {
                    let normalized = normalizeSummary(text)
                    if !normalized.isEmpty {
                        out.append(normalized)
                    }
                    continue
                }
                if let dict = item as? [String: Any] {
                    let keys = ["summary", "Summary", "text", "Text", "content", "Content", "value", "Value"]
                    for key in keys {
                        if let text = dict[key] as? String {
                            let normalized = normalizeSummary(text)
                            if !normalized.isEmpty {
                                out.append(normalized)
                            }
                            break
                        }
                    }
                }
            }
        }
    }

    private static func appendKeywordValue(_ value: Any, out: inout [String]) {
        if let text = value as? String {
            out.append(contentsOf: splitKeywordLine(text))
            return
        }
        if let array = value as? [Any] {
            for item in array {
                if let s = item as? String {
                    out.append(contentsOf: splitKeywordLine(s))
                } else if let d = item as? [String: Any] {
                    let keys = ["keyword", "Keyword", "text", "Text", "word", "Word", "name", "Name", "value", "Value"]
                    for k in keys {
                        if let s = d[k] as? String {
                            out.append(contentsOf: splitKeywordLine(s))
                            break
                        }
                    }
                }
            }
        }
    }

    private static func dedupKeywords(_ values: [String]) -> [String] {
        var dedup: [String] = []
        var seen: Set<String> = []

        for raw in values {
            let normalized = normalizeKeyword(raw)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                dedup.append(normalized)
            }
            if dedup.count >= 20 { break }
        }
        return dedup
    }

    private static func bestSummary(from values: [String]) -> String? {
        let cleaned = values
            .map(normalizeSummary)
            .filter { !$0.isEmpty }

        if cleaned.isEmpty { return nil }
        // Prefer longer paragraph-like summary.
        return cleaned.max(by: { $0.count < $1.count })
    }

    private static func splitKeywordLine(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;；、|/\n\t")
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeKeyword(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count > 24 { return "" }
        return trimmed
    }

    private static func normalizeSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count < 12 { return "" }
        return trimmed
    }

    private static func collectGenericLongText(from node: Any, out: inout [String]) {
        if let dict = node as? [String: Any] {
            for (_, value) in dict {
                collectGenericLongText(from: value, out: &out)
            }
            return
        }
        if let array = node as? [Any] {
            for item in array {
                collectGenericLongText(from: item, out: &out)
            }
            return
        }
        if let text = node as? String {
            let normalized = normalizeSummary(text)
            // 兜底候选尽量过滤掉过短或明显非段落字段
            if normalized.count >= 20 {
                out.append(normalized)
            }
        }
    }
}
