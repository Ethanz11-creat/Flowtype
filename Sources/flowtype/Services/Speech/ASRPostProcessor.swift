import Foundation

/// Post-processes raw ASR text: whitespace normalization, filler stripping,
/// tech term correction, and common ASR error fixes.
struct ASRPostProcessor {
    private let techTerms: [(pattern: String, replacement: String)]
    private let fillers: [String]

    init() {
        self.techTerms = Self.loadTechTerms()
        self.fillers = Self.loadFillers()
    }

    /// Main entry point. Applies the full pipeline.
    static func process(_ text: String) -> String {
        let processor = ASRPostProcessor()
        var result = text
        result = processor.normalizeWhitespace(result)
        result = processor.stripFillers(result)
        result = processor.correctTechTerms(result)
        result = processor.fixCommonASRErrors(result)
        result = processor.normalizeWhitespace(result)
        return result
    }

    // MARK: - Pipeline steps

    func normalizeWhitespace(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Conservative filler removal. Only removes fillers that appear as
    /// standalone tokens (surrounded by spaces or at boundaries).
    func stripFillers(_ text: String) -> String {
        var result = text
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            let patterns = [
                " \(filler) ",
                "^\(filler) ",
                " \(filler)$",
                "^\(filler)$"
            ]
            for pattern in patterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: " ",
                    options: .regularExpression
                )
            }
        }
        return normalizeWhitespace(result)
    }

    /// Corrects tech terms using case-insensitive regex with word boundaries.
    func correctTechTerms(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in techTerms {
            // Escape regex special chars in pattern, replace spaces with \s+
            let escaped = pattern
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "+", with: "\\+")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?")
                .replacingOccurrences(of: "^", with: "\\^")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
                .replacingOccurrences(of: " ", with: "\\s+")

            let regexPattern = "(?i)\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else { continue }
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    /// Fixes common ASR artifacts: consecutive duplicate chars, etc.
    func fixCommonASRErrors(_ text: String) -> String {
        var result = text
        // Remove consecutive duplicate chars (3+ in a row -> 1)
        let chars = Array(result)
        guard chars.count >= 3 else { return result }

        var cleaned: [Character] = []
        var i = 0
        while i < chars.count {
            let current = chars[i]
            var runLength = 1
            while i + runLength < chars.count && chars[i + runLength] == current {
                runLength += 1
            }
            if runLength >= 3 {
                cleaned.append(current)
            } else {
                for j in 0..<runLength {
                    cleaned.append(chars[i + j])
                }
            }
            i += runLength
        }
        result = String(cleaned)
        return result
    }

    // MARK: - Resource loading

    private static func loadTechTerms() -> [(String, String)] {
        guard let url = Bundle.module.url(forResource: "tech_terms", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return []
        }
        // Sort by pattern length descending to avoid partial matches
        return dict.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
    }

    private static func loadFillers() -> [String] {
        guard let url = Bundle.module.url(forResource: "filler_words", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return ["嗯", "啊", "哦", "呃", "哼", "哈", "呀", "哪",
                    "那个", "这个", "那么", "就是", "对吧", "然后"]
        }
        return array
    }
}
