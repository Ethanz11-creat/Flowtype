import Foundation

struct ASRScoredResult {
    let text: String
    let provider: String
    let score: Double
}

/// Scores ASR transcription quality across multiple dimensions.
/// Higher score = better candidate.
struct ASRResultScorer {
    private let techTerms: [String] = [
        "SwiftUI", "LangGraph", "LangChain", "Notion", "RAG", "Agent",
        "DeepSeek", "TeleSpeech", "SenseVoice", "Prompt", "Docker",
        "Kubernetes", "GitHub", "GitLab", "OpenAI", "ChatGPT",
        "Claude", "Anthropic", "Streamlit", "Gradio", "FastAPI",
        "Node.js", "TypeScript", "JavaScript", "React", "Vue.js",
        "Next.js", "Tailwind CSS", "Spring Boot"
    ]

    private let fillers: [String] = [
        "嗯", "啊", "哦", "呃", "哼", "哈", "呀", "哪",
        "那个", "这个", "那么", "就是", "对吧", "然后"
    ]

    func score(_ text: String, provider: String) -> ASRScoredResult {
        let nonEmptyScore = text.isEmpty ? 0.0 : 1.0
        let lengthScore = text.count >= 2 ? 1.0 : 0.0
        let chineseRatioScore = chineseRatio(in: text)
        let fillerRatioScore = fillerRatio(in: text)
        let termHitScore = termHitCount(in: text)
        let repetitionPenalty = repetitionScore(in: text)
        let punctuationScore = punctuationRatio(in: text)

        let totalScore = 1.0 * nonEmptyScore
            + 0.8 * lengthScore
            + 1.0 * chineseRatioScore
            + 1.2 * (1.0 - fillerRatioScore)
            + 0.5 * termHitScore
            + 0.6 * (1.0 - repetitionPenalty)
            + 0.3 * punctuationScore

        return ASRScoredResult(text: text, provider: provider, score: totalScore)
    }

    // MARK: - Dimension scoring

    private func chineseRatio(in text: String) -> Double {
        let chineseCount = text.filter { $0 >= "\u{4E00}" && $0 <= "\u{9FFF}" }.count
        return text.isEmpty ? 0.0 : Double(chineseCount) / Double(text.count)
    }

    private func fillerRatio(in text: String) -> Double {
        var fillerCount = 0
        for filler in fillers {
            fillerCount += text.components(separatedBy: filler).count - 1
        }
        return text.isEmpty ? 0.0 : min(Double(fillerCount) / Double(text.count), 1.0)
    }

    private func termHitCount(in text: String) -> Double {
        let lower = text.lowercased()
        var hits = 0
        for term in techTerms {
            if lower.contains(term.lowercased()) {
                hits += 1
            }
        }
        return min(Double(hits) / 5.0, 1.0)
    }

    private func repetitionScore(in text: String) -> Double {
        let len = text.count
        guard len >= 4 else { return 0.0 }

        var maxRepeatCount = 0
        for n in 2...min(4, len / 2) {
            for i in 0...(len - n * 2) {
                let startIdx = text.index(text.startIndex, offsetBy: i)
                let endIdx = text.index(startIdx, offsetBy: n)
                let nextStart = text.index(text.startIndex, offsetBy: i + n)
                let nextEnd = text.index(nextStart, offsetBy: n)

                if text[startIdx..<endIdx] == text[nextStart..<nextEnd] {
                    maxRepeatCount += 1
                }
            }
        }
        return min(Double(maxRepeatCount) / 10.0, 1.0)
    }

    private func punctuationRatio(in text: String) -> Double {
        let punctuations = "。，！？、；："
        let count = text.filter { punctuations.contains($0) }.count
        if text.count < 5 { return 1.0 }
        return min(Double(count) / Double(text.count / 10 + 1), 1.0)
    }
}
