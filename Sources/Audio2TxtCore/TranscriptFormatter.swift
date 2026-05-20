import Foundation

public enum TranscriptFormatter {
    public static func renderTXT(fromJSONData data: Data, expectedDurationMs: Int? = nil) -> String {
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            return renderTXT(from: json, expectedDurationMs: expectedDurationMs)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return "# 转写结果不是合法 JSON，原始内容如下\n\n\(raw)"
        }
    }

    public static func renderTXT(from json: Any, expectedDurationMs: Int? = nil) -> String {
        let extracted = extractBestSegments(from: json, expectedDurationMs: expectedDurationMs)
        if extracted.isEmpty {
            if let pretty = try? prettyPrinted(json: json) {
                return "# 未识别到标准句段，以下为原始结果 JSON\n\n\(pretty)"
            }
            return "# 未识别到标准句段，且结果无法序列化。"
        }

        let normalized = normalizeSegments(extracted, expectedDurationMs: expectedDurationMs)
        return renderReadableParagraphs(normalized)
    }

    public static func formatMs(_ ms: Int) -> String {
        let positive = max(0, ms)
        let hours = positive / 3_600_000
        let minutes = (positive % 3_600_000) / 60_000
        let seconds = (positive % 60_000) / 1_000
        let millis = positive % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    private struct Candidate {
        let segments: [TranscriptSegment]
        let score: Double
    }

    private static func extractBestSegments(from json: Any, expectedDurationMs: Int?) -> [TranscriptSegment] {
        var candidates: [Candidate] = []

        func walk(_ node: Any) {
            if let array = node as? [Any] {
                if let candidate = buildCandidate(from: array, expectedDurationMs: expectedDurationMs) {
                    candidates.append(candidate)
                }
                for item in array {
                    walk(item)
                }
                return
            }

            if let dict = node as? [String: Any] {
                for value in dict.values {
                    walk(value)
                }
            }
        }

        walk(json)
        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            return []
        }
        return best.segments
    }

    private static func buildCandidate(from array: [Any], expectedDurationMs: Int?) -> Candidate? {
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(array.count)

        for item in array {
            if let dict = item as? [String: Any], let seg = parseSegment(dict: dict) {
                segments.append(seg)
            }
        }

        segments = deduplicate(segments)
        guard segments.count >= 2 else { return nil }
        segments.sort { $0.startMs < $1.startMs }

        let trimmed = removeTimelineOutliers(segments)
        guard trimmed.count >= 2 else { return nil }

        let calibrated = calibrateTimeScale(trimmed, expectedDurationMs: expectedDurationMs)
        let clipped = pruneByExpectedDuration(calibrated, expectedDurationMs: expectedDurationMs)
        guard clipped.count >= 2 else { return nil }

        let score = scoreSegments(clipped, expectedDurationMs: expectedDurationMs)
        return Candidate(segments: clipped, score: score)
    }

    private static func deduplicate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var seen: Set<String> = []
        var result: [TranscriptSegment] = []
        result.reserveCapacity(segments.count)

        for seg in segments {
            let key = "\(seg.startMs)|\(seg.speaker ?? "")|\(seg.text)"
            if seen.insert(key).inserted {
                result.append(seg)
            }
        }
        return result
    }

    private static func scoreSegments(_ segments: [TranscriptSegment], expectedDurationMs: Int?) -> Double {
        guard let first = segments.first, let last = segments.last else { return -9999 }

        let count = Double(segments.count)
        let avgLen = segments.reduce(0.0) { $0 + Double($1.text.count) } / count

        let tinyCount = Double(segments.filter { isTinyPhrase($0) }.count)
        let longCount = Double(segments.filter { isLongPhrase($0) }.count)
        let punctCount = Double(segments.filter { endsWithStopPunctuation($0.text) }.count)

        let tinyRatio = tinyCount / count
        let longRatio = longCount / count
        let punctRatio = punctCount / count

        let durationSec = max(1.0, Double(last.startMs - first.startMs) / 1000.0)
        let density = count / durationSec

        var score = 0.0
        score += log(count + 1.0) * 4.0
        score += avgLen * 1.8
        score += longRatio * 8.0
        score += punctRatio * 5.0
        score -= tinyRatio * 6.0

        if density > 2.0 {
            score -= (density - 2.0) * 8.0
        }
        if avgLen < 3.0 {
            score -= 20.0
        }
        if count > 1000 && avgLen < 6.0 {
            score -= 40.0
        }

        if let expected = expectedDurationMs, expected > 0 {
            let expectedD = Double(expected)
            let lastD = Double(last.startMs)
            let spanD = max(1.0, Double(last.startMs - first.startMs))
            let coverageRatio = max(0.0001, lastD / expectedD)
            let spanRatio = max(0.0001, spanD / expectedD)

            score -= abs(log(coverageRatio)) * 12.0
            score -= abs(log(spanRatio)) * 4.0

            if coverageRatio > 1.6 {
                score -= (coverageRatio - 1.6) * 40.0
            }
            if coverageRatio < 0.2 {
                score -= (0.2 - coverageRatio) * 30.0
            }
        }

        return score
    }

    private static func normalizeSegments(_ segments: [TranscriptSegment], expectedDurationMs: Int?) -> [TranscriptSegment] {
        let sorted = segments
            .map {
                TranscriptSegment(
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    speaker: $0.speaker,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { lhs, rhs in
                if lhs.startMs == rhs.startMs {
                    return lhs.text.count > rhs.text.count
                }
                return lhs.startMs < rhs.startMs
            }

        guard !sorted.isEmpty else { return [] }
        let timelineTrimmed: [TranscriptSegment]
        if expectedDurationMs != nil {
            timelineTrimmed = pruneByExpectedDuration(sorted, expectedDurationMs: expectedDurationMs)
        } else {
            timelineTrimmed = removeTimelineOutliers(sorted)
        }
        guard !timelineTrimmed.isEmpty else { return [] }
        let deduped = collapseNearDuplicates(timelineTrimmed)

        let tinyCount = deduped.filter(isTinyPhrase).count
        if tinyCount >= max(4, deduped.count / 3) {
            return mergeConsecutiveWordLikeSegments(deduped)
        }

        return deduped
    }

    private static func removeTimelineOutliers(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard segments.count >= 4 else { return segments }

        let starts = segments.map(\.startMs)
        var gaps: [Int] = []
        for idx in 1..<starts.count {
            gaps.append(max(0, starts[idx] - starts[idx - 1]))
        }
        let sortedGaps = gaps.sorted()
        let medianGap = sortedGaps[sortedGaps.count / 2]
        let threshold = max(120_000, medianGap * 8)

        var cutIndex: Int?
        for idx in 1..<starts.count {
            let gap = starts[idx] - starts[idx - 1]
            if gap > threshold {
                cutIndex = idx
                break
            }
        }

        guard let cut = cutIndex else { return segments }
        let head = Array(segments[..<cut])
        let tail = Array(segments[cut...])
        let headEnd = head.last?.startMs ?? 0
        let tailEnd = tail.last?.startMs ?? 0

        if head.count >= 3 && tail.count <= 2 {
            return head
        }

        if head.count >= 3 && tail.count >= 3 {
            let headSpan = max(1, headEnd - (head.first?.startMs ?? 0))
            let tailSpan = max(1, tailEnd - (tail.first?.startMs ?? 0))
            // Prefer the denser / more realistic earlier cluster when huge jump appears.
            let headDensity = Double(head.count) / Double(headSpan)
            let tailDensity = Double(tail.count) / Double(tailSpan)
            if headDensity >= tailDensity * 0.6 {
                return head
            }
        }
        return segments
    }

    private static func pruneByExpectedDuration(_ segments: [TranscriptSegment], expectedDurationMs: Int?) -> [TranscriptSegment] {
        guard let expected = expectedDurationMs, expected > 0 else { return segments }
        let maxAllowed = Int(Double(expected) * 1.35) + 8_000
        return segments.filter { $0.startMs >= 0 && $0.startMs <= maxAllowed }
    }

    private static func calibrateTimeScale(_ segments: [TranscriptSegment], expectedDurationMs: Int?) -> [TranscriptSegment] {
        guard let expected = expectedDurationMs, expected > 0, !segments.isEmpty else {
            return segments
        }

        let factors: [Double] = [1.0, 0.5, 0.2, 0.1, 1.0 / 3.0, 1.0 / 6.0, 1.0 / 10.0, 1.0 / 30.0, 1.0 / 60.0, 1.0 / 100.0, 1.0 / 1000.0]
        let target = Double(expected)

        var bestFactor = 1.0
        var bestPenalty = Double.greatestFiniteMagnitude

        for factor in factors {
            let scaled = segments.map { seg in
                TranscriptSegment(
                    startMs: Int((Double(seg.startMs) * factor).rounded()),
                    endMs: seg.endMs.map { Int((Double($0) * factor).rounded()) },
                    speaker: seg.speaker,
                    text: seg.text
                )
            }
            let pruned = pruneByExpectedDuration(scaled, expectedDurationMs: expectedDurationMs)
            guard pruned.count >= 2, let scaledFirstItem = pruned.first, let scaledLastItem = pruned.last else {
                continue
            }

            let scaledFirst = Double(scaledFirstItem.startMs)
            let scaledLast = Double(scaledLastItem.startMs)
            let scaledSpan = max(1.0, scaledLast - scaledFirst)
            let coverageRatio = max(0.0001, scaledLast / target)
            let spanRatio = max(0.0001, scaledSpan / target)
            let keepRatio = Double(pruned.count) / Double(max(1, scaled.count))

            var penalty = 0.0
            penalty += abs(log(coverageRatio)) * 8.0
            penalty += abs(log(spanRatio)) * 3.0
            penalty += (1.0 - keepRatio) * 30.0

            if scaledLast > target * 2.0 + 30_000 {
                penalty += 30.0
            }
            if scaledLast < target * 0.15 {
                penalty += 10.0
            }
            if pruned.count < max(3, scaled.count / 8) {
                penalty += 12.0
            }
            penalty -= log(Double(pruned.count) + 1.0) * 1.2

            if penalty < bestPenalty {
                bestPenalty = penalty
                bestFactor = factor
            }
        }

        guard abs(bestFactor - 1.0) > 0.001 else { return segments }
        return segments.map { seg in
            TranscriptSegment(
                startMs: Int((Double(seg.startMs) * bestFactor).rounded()),
                endMs: seg.endMs.map { Int((Double($0) * bestFactor).rounded()) },
                speaker: seg.speaker,
                text: seg.text
            )
        }
    }

    private static func collapseNearDuplicates(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        var result: [TranscriptSegment] = []
        result.reserveCapacity(segments.count)

        for seg in segments {
            guard let last = result.last else {
                result.append(seg)
                continue
            }

            let sameSpeaker = last.speaker == seg.speaker
            let closeStart = abs(last.startMs - seg.startMs) <= 120

            if sameSpeaker && closeStart {
                if last.text == seg.text { continue }
                if last.text.contains(seg.text) { continue }
                if seg.text.contains(last.text) {
                    result[result.count - 1] = seg
                    continue
                }
            }
            result.append(seg)
        }
        return result
    }

    private struct Paragraph {
        var startMs: Int
        var speaker: String?
        var text: String
        var sentenceCount: Int
    }

    private static func renderReadableParagraphs(_ segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let speakers = Set(segments.compactMap(\.speaker).filter { !$0.isEmpty })
        let showSpeaker = speakers.count > 1
        let paragraphs = buildParagraphs(segments, showSpeaker: showSpeaker)

        var blocks: [String] = []
        blocks.reserveCapacity(paragraphs.count)
        for paragraph in paragraphs {
            let ts = formatReadableTime(paragraph.startMs)
            let speakerPrefix = showSpeaker ? "[\(paragraph.speaker ?? "SPK")] " : ""
            blocks.append("\(ts)\n\(speakerPrefix)\(paragraph.text)")
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func buildParagraphs(_ segments: [TranscriptSegment], showSpeaker: Bool) -> [Paragraph] {
        var result: [Paragraph] = []
        result.reserveCapacity(max(1, segments.count / 2))

        var current: Paragraph?
        var previousStart: Int?

        func flushCurrent() {
            guard let c = current else { return }
            result.append(c)
            current = nil
        }

        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if current == nil {
                current = Paragraph(startMs: seg.startMs, speaker: seg.speaker, text: text, sentenceCount: 1)
                previousStart = seg.startMs
                continue
            }

            guard var paragraph = current else { continue }
            let deltaFromStart = seg.startMs - paragraph.startMs
            let gap = previousStart.map { seg.startMs - $0 } ?? 0
            let speakerChanged = showSpeaker && paragraph.speaker != seg.speaker
            let shouldBreakBySpan = deltaFromStart >= 35_000
            let shouldBreakByGap = gap >= 12_000 && paragraph.text.count >= 48
            let shouldBreakByLength = paragraph.text.count >= 220 && endsWithStopPunctuation(paragraph.text)

            if speakerChanged || shouldBreakBySpan || shouldBreakByGap || shouldBreakByLength {
                flushCurrent()
                current = Paragraph(startMs: seg.startMs, speaker: seg.speaker, text: text, sentenceCount: 1)
                previousStart = seg.startMs
                continue
            }

            paragraph.text = joinForReadableText(left: paragraph.text, right: text)
            paragraph.sentenceCount += 1
            current = paragraph
            previousStart = seg.startMs
        }

        flushCurrent()
        return result
    }

    private static func joinForReadableText(left: String, right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let leftLast = left.last
        let rightFirst = right.first
        if let l = leftLast, let r = rightFirst {
            if isAsciiWordChar(l) && isAsciiWordChar(r) {
                return left + " " + right
            }
            if "，。！？；：,.!?".contains(l) {
                return left + right
            }
        }
        return left + right
    }

    private static func isAsciiWordChar(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        let v = scalar.value
        return (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v)
    }

    private static func formatReadableTime(_ ms: Int) -> String {
        let positive = max(0, ms)
        let totalSec = positive / 1000
        let hour = totalSec / 3600
        let minute = (totalSec % 3600) / 60
        let second = totalSec % 60
        if hour > 0 {
            return String(format: "%02d:%02d:%02d", hour, minute, second)
        }
        return String(format: "%02d:%02d", minute, second)
    }

    private static func mergeConsecutiveWordLikeSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        var bucket: [TranscriptSegment] = []

        func flush() {
            guard !bucket.isEmpty else { return }
            if bucket.count == 1 {
                merged.append(bucket[0])
                bucket.removeAll()
                return
            }

            let text = bucket.map(\.text).joined(separator: "")
            let start = bucket.first!.startMs
            let end = bucket.last!.endMs
            let speaker = bucket.first!.speaker
            merged.append(TranscriptSegment(startMs: start, endMs: end, speaker: speaker, text: text))
            bucket.removeAll()
        }

        for seg in segments {
            if bucket.isEmpty {
                bucket.append(seg)
                continue
            }

            let prev = bucket.last!
            let sameSpeaker = prev.speaker == seg.speaker
            let gap = seg.startMs - prev.startMs
            let canMerge = sameSpeaker
                && gap >= 0
                && gap <= 800
                && (isTinyPhrase(prev) || isTinyPhrase(seg))
                && !endsWithStopPunctuation(prev.text)

            if canMerge {
                bucket.append(seg)
                let totalLength = bucket.reduce(0) { $0 + $1.text.count }
                if totalLength >= 32 || endsWithStopPunctuation(seg.text) {
                    flush()
                }
            } else {
                flush()
                bucket.append(seg)
            }
        }

        flush()
        return merged
    }

    private static func isLongPhrase(_ seg: TranscriptSegment) -> Bool {
        let t = seg.text
        if t.count >= 12 { return true }
        if t.contains(" ") { return true }
        return t.contains(where: { "，。！？；：,.!?".contains($0) })
    }

    private static func isTinyPhrase(_ seg: TranscriptSegment) -> Bool {
        let t = seg.text
        if t.count > 4 { return false }
        if t.contains(" ") { return false }
        return !t.contains(where: { "，。！？；：,.!?".contains($0) })
    }

    private static func endsWithStopPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？.!?".contains(last)
    }

    private static func parseSegment(dict: [String: Any]) -> TranscriptSegment? {
        let textKeys = [
            "text", "Text",
            "content", "Content",
            "sentence", "Sentence", "sentence_text", "SentenceText",
            "transcript", "Transcript",
            "utterance", "Utterance",
            "value", "Value"
        ]
        var text: String?
        for key in textKeys {
            if let value = dict[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    text = normalized
                    break
                }
            }
        }
        guard let text else { return nil }

        guard let startMs = detectTimeMs(
            from: dict,
            keys: [
                "start_ms", "StartMs", "startMs",
                "start_time_ms", "StartTimeMs",
                "start_time", "StartTime",
                "start", "Start",
                "begin_time", "beginTime", "BeginTime",
                "offset", "Offset",
                "timestamp", "Timestamp"
            ]
        ) else {
            return nil
        }

        let endMs = detectTimeMs(
            from: dict,
            keys: [
                "end_ms", "EndMs", "endMs",
                "end_time_ms", "EndTimeMs",
                "end_time", "EndTime",
                "end", "End",
                "stop", "Stop",
                "finish_time", "FinishTime"
            ]
        )
        let speaker = detectSpeaker(from: dict)

        return TranscriptSegment(startMs: startMs, endMs: endMs, speaker: speaker, text: text)
    }

    private static func detectSpeaker(from dict: [String: Any]) -> String? {
        if let speakerObj = dict["speaker"] as? [String: Any] ?? dict["Speaker"] as? [String: Any] {
            if let name = speakerObj["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
            if let idText = speakerObj["id"] as? String, !idText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "SPK_\(idText)"
            }
            if let idInt = speakerObj["id"] as? Int {
                return "SPK_\(idInt)"
            }
        }

        let keys = [
            "speaker", "Speaker",
            "speaker_id", "speakerId", "SpeakerId",
            "speaker_label", "speakerLabel", "SpeakerLabel"
        ]
        for key in keys {
            if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = dict[key] as? Int {
                return "SPK_\(value)"
            }
        }
        return nil
    }

    private static func detectTimeMs(from dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let ms = numberToMs(dict[key], key: key) {
                return ms
            }
        }
        return nil
    }

    private static func numberToMs(_ value: Any?, key: String) -> Int? {
        guard let value else { return nil }

        let numeric: Double?
        switch value {
        case let intValue as Int:
            numeric = Double(intValue)
        case let doubleValue as Double:
            numeric = doubleValue
        case let stringValue as String:
            numeric = Double(stringValue)
        default:
            numeric = nil
        }
        guard let n = numeric else { return nil }

        let lowerKey = key.lowercased()
        if lowerKey.contains("ms") {
            return Int(n.rounded())
        }
        if lowerKey == "start_time" || lowerKey == "end_time" || lowerKey == "starttime" || lowerKey == "endtime" {
            // 妙记句段字段通常是毫秒；若值很小(如 1.5)再按秒处理。
            if n >= 1000 {
                return Int(n.rounded())
            }
            return Int((n * 1000).rounded())
        }
        if n > 100_000 {
            return Int(n.rounded())
        }
        return Int((n * 1000).rounded())
    }

    private static func prettyPrinted(json: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}
