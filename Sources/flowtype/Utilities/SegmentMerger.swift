import Foundation

/// Merges ordered ASR text segments with boundary deduplication.
///
/// When audio is split into 60s chunks, the ASR provider may produce
/// overlapping or truncated sentences at chunk boundaries. This merger
/// detects and removes those overlaps before concatenation.
struct SegmentMerger {

    /// Minimum overlap length to trigger deduplication.
    /// 5 Chinese characters is roughly 1.5-2 words — safe threshold.
    private static let minOverlapLength = 5

    /// Maximum characters to scan from each boundary.
    /// 30 chars covers ~1 short sentence.
    private static let maxScanLength = 30

    // MARK: - Public API

    /// Merge ordered segments with overlap detection.
    ///
    /// - Segments are processed in strict index order.
    /// - For each adjacent pair, scans for overlapping text at the boundary.
    /// - If overlap >= `minOverlapLength`, the duplicate is removed from the
    ///   right segment before concatenation.
    /// - If no overlap is found, segments are joined with "\n".
    static func merge(_ segments: [String]) -> String {
        guard segments.count > 1 else {
            return segments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var result = segments[0]
        for i in 1..<segments.count {
            result = mergeTwo(left: result, right: segments[i])
        }

        // Final pass: compress consecutive duplicate short sentences
        return compressDuplicates(result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Boundary overlap detection

    /// Merge two adjacent segments, removing any overlapping boundary text.
    private static func mergeTwo(left: String, right: String) -> String {
        let leftTrimmed = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !leftTrimmed.isEmpty, !rightTrimmed.isEmpty else {
            return leftTrimmed + rightTrimmed
        }

        // Scan from longest possible overlap down to minOverlapLength
        let maxOverlap = min(leftTrimmed.count, rightTrimmed.count, maxScanLength)

        for overlapLen in stride(from: maxOverlap, through: minOverlapLength, by: -1) {
            let leftSuffix = String(leftTrimmed.suffix(overlapLen))
            let rightPrefix = String(rightTrimmed.prefix(overlapLen))

            if leftSuffix == rightPrefix {
                // Found exact match — remove the duplicate from the right side
                let rightRemainder = String(rightTrimmed.dropFirst(overlapLen))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if rightRemainder.isEmpty {
                    return leftTrimmed
                }

                // Smart join: if the boundary is mid-sentence, use "";
                // if it's a natural break, use "\n"
                let joiner = shouldJoinWithNewline(left: leftTrimmed, right: rightRemainder) ? "\n" : ""
                return leftTrimmed + joiner + rightRemainder
            }
        }

        // No significant overlap found — join with newline
        return leftTrimmed + "\n" + rightTrimmed
    }

    /// Decide whether to insert a newline between two non-overlapping segments.
    /// If the left ends with sentence-ending punctuation, or the right starts
    /// with a list marker / number, use newline.
    private static func shouldJoinWithNewline(left: String, right: String) -> Bool {
        let sentenceEnders = "。！？."
        let listStarters = "-•*123456789"

        if let lastChar = left.last, sentenceEnders.contains(lastChar) {
            return true
        }
        if let firstChar = right.first, listStarters.contains(firstChar) {
            return true
        }
        return false
    }

    // MARK: - Global duplicate compression

    /// Compresses consecutive duplicate short sentences across the entire text.
    /// E.g. "实现登录功能。实现登录功能。" → "实现登录功能。"
    private static func compressDuplicates(_ text: String) -> String {
        let sentences = text.components(separatedBy: "\n")
        guard sentences.count > 1 else { return text }

        var compressed: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let last = compressed.last {
                if areSemanticallyEqual(last, trimmed) {
                    // Skip exact or near-exact duplicate
                    continue
                }
            }
            compressed.append(trimmed)
        }

        return compressed.joined(separator: "\n")
    }

    /// Two strings are "semantically equal" if they are identical after
    /// normalizing whitespace and ignoring minor punctuation differences.
    private static func areSemanticallyEqual(_ a: String, _ b: String) -> Bool {
        let normalize: (String) -> String = { str in
            str.trimmingCharacters(in: .whitespaces)
               .replacingOccurrences(of: " ", with: "")
               .replacingOccurrences(of: "，", with: "")
               .replacingOccurrences(of: ",", with: "")
        }
        return normalize(a) == normalize(b)
    }
}
