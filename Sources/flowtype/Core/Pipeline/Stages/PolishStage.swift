import Foundation

/// Full-text fallback preserves PostProcess corrections; raw is only a last resort.
func polishFallbackText(processed: String, raw: String) -> String {
    processed.isEmpty ? raw : processed
}

/// Protect only explicit literals; ordinary prose and CJK punctuation can change.
/// Match whole tokens so 42→142, --force→--forceful and /a→/abc are damage.
func preservesCodingLiterals(original: String, polished: String) -> Bool {
    let patterns = [
        #"`+([^`]+)`+"#,
        #"(?<![A-Za-z0-9_])https?://[^\s<>\"'`\p{Han}，。；！？、]+"#,
        #"(?<![\p{L}\p{M}\p{N}_:/])(?:~/|/|\.{1,2}/|[\p{L}\p{M}\p{N}_.-]+/)(?:(?!`)[\p{L}\p{M}\p{N}\p{S}_./~+@%:=#?&-])+"#,
        #"(?<![A-Za-z0-9_-])--?[A-Za-z][A-Za-z0-9_-]*(?:=[A-Za-z0-9_./~:+@%=-]+)?"#,
        #"(?<![A-Za-z0-9_.])(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)+)(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?(?![A-Za-z0-9_]|\.[A-Za-z0-9_])"#,
        #"(?<![A-Za-z0-9_.])[-+]?\d+(?:\.\d+)?(?![A-Za-z0-9_]|\.[A-Za-z0-9_])"#,
    ]

    func trimSentenceDelimiters(_ matched: String, category: Int) -> String {
        guard category != 0 else { return matched }
        var result = matched
        while let last = result.last {
            if ".,;:!?".contains(last), !(category == 1 && (result.contains("?") || result.contains("#"))) {
                // Query/fragment punctuation is URL data. Ambiguous English
                // punctuation there is conservatively protected, not discarded.
                result.removeLast()
            } else if let opening = [")": "(", "]": "[", "}": "{"][String(last)],
                      result.filter({ String($0) == String(last) }).count > result.filter({ String($0) == opening }).count {
                // Keep balanced URL content such as ?q=(x); only an unmatched
                // closing delimiter belongs to the surrounding sentence.
                result.removeLast()
            } else { break }
        }
        return result
    }

    func extract(_ text: String, includeBacktickContents: Bool = false) -> [[String]] {
        var categories = Array(repeating: [String](), count: patterns.count)
        var occupied: [NSRange] = []
        for (category, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                // On the polished side, a newly added backtick may enclose an
                // unchanged path/version/etc.; retain those inner categories.
                if category != 0 || !includeBacktickContents { occupied.append(match.range) }
                let matchedRange = category == 0 ? match.range(at: 1) : match.range
                guard let range = Range(matchedRange, in: text) else { continue }
                let literal = trimSentenceDelimiters(String(text[range]), category: category)
                if !literal.isEmpty { categories[category].append(literal) }
            }
        }
        return categories
    }

    let source = extract(original)
    let result = extract(polished, includeBacktickContents: true)
    for category in source.indices {
        for literal in source[category] {
            if category == 0 {
                // Backtick content may retain its text while prose formatting
                // removes delimiters; it must still occur as a complete token.
                let pattern = #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: literal) + #"(?![A-Za-z0-9_])"#
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      expression.firstMatch(in: polished, range: NSRange(polished.startIndex..., in: polished)) != nil else { return false }
            } else if !result[category].contains(literal) {
                // Compare complete tokens in the same category: added version
                // suffixes and Unicode filename changes cannot match a prefix.
                return false
            }
        }
    }
    return true
}

/// Optional enhancement: only a completed stream may replace the processed text.
final class PolishStage: PipelineStage, @unchecked Sendable {
    static let stageName = "Polish"
    var name: String { Self.stageName }

    private let llmService = LLMService()
    private let streamFactory: (@Sendable (String, Configuration, ForegroundContext?) async -> AsyncThrowingStream<String, Error>)?
    private let configuration: @MainActor @Sendable () -> Configuration
    private let deadlineSeconds: TimeInterval

    init(configuration: @escaping @MainActor @Sendable () -> Configuration = { ConfigurationStore.shared.current },
         deadlineSeconds: TimeInterval = 3,
         streamFactory: (@Sendable (String, Configuration, ForegroundContext?) async -> AsyncThrowingStream<String, Error>)? = nil) {
        self.configuration = configuration
        self.deadlineSeconds = deadlineSeconds
        self.streamFactory = streamFactory
    }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .processed(let processed, let raw) = payload else {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: PolishStageError.invalidPayload,
                                                rawText: nil, retryable: false))
        }
        let fallback = polishFallbackText(processed: processed, raw: raw)
        func cancelled() -> StageResult {
            .suspend(ErrorRecoveryContext(failedStage: name, error: CancellationError(), rawText: raw, retryable: false))
        }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        let usePolish = await MainActor.run { context.usePolish }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        guard usePolish else { return .continue(.polished(fallback, raw: raw)) }

        let config = await configuration()
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        guard LLMService.hasAvailableProvider(config: config) else {
            await MainActor.run { if !context.isCancelled { context.polishFailed = true } }
            return .continue(.polished(fallback, raw: raw))
        }
        let foreground = await MainActor.run { LLMService.allowedForegroundContext(context.foregroundContext, config: config) }
        let prompt = await MainActor.run { LLMService.composeSystemPrompt(fallback: config.systemPrompt) }
        guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
        await MainActor.run { if !context.isCancelled { context.statePublisher.send(.polishing(preview: "")) } }
        let start = Date()
        let timeout = await MainActor.run { min(deadlineSeconds, context.completionBudget?.remainingSeconds ?? deadlineSeconds) }
        do {
            guard timeout > 0 else { throw AsyncDeadlineError.timedOut }
            let result = try await withAsyncDeadline(seconds: timeout) { [self] in
                try Task.checkCancellation()
                let stream = if let streamFactory {
                    await streamFactory(fallback, config, foreground)
                } else {
                    await llmService.polishText(fallback, systemPrompt: prompt, config: config, foregroundContext: foreground, timeoutSeconds: timeout)
                }
                try Task.checkCancellation()
                var completeText = ""
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard !context.isCancellationRequested else { throw CancellationError() }
                    completeText += chunk
                }
                try Task.checkCancellation()
                return completeText
            }
            guard !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
            await MainActor.run { if !context.isCancelled { context.polishMs = Int(Date().timeIntervalSince(start) * 1000) } }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preservesCodingLiterals(original: fallback, polished: result) else {
                throw PolishStageError.damagedLiterals
            }
            let final = result
            return .continue(.polished(final, raw: raw))
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, !context.isCancellationRequested else { return cancelled() }
            await MainActor.run {
                guard !context.isCancelled else { return }
                context.polishFailed = true
                context.completionNotice = error is AsyncDeadlineError ? "整理超时 · 已保留识别结果" : "整理失败 · 已保留识别结果"
                context.polishMs = Int(Date().timeIntervalSince(start) * 1000)
            }
            AppLogger.log("[PolishStage#\(context.sessionID)] Degraded to complete processed text: \(error)")
            return .continue(.polished(fallback, raw: raw))
        }
    }
}

enum PolishStageError: Error { case invalidPayload, damagedLiterals }
