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
        #"(?<![A-Za-z0-9_:/])(?:~/|/|\.{1,2}/|[A-Za-z0-9_.-]+/)[A-Za-z0-9_./~+@%:=#?&-]+"#,
        #"(?<![A-Za-z0-9_-])--?[A-Za-z][A-Za-z0-9_-]*(?:=[A-Za-z0-9_./~:+@%=-]+)?"#,
        #"(?<![A-Za-z0-9_.])(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)+)(?:[-+][A-Za-z0-9.-]+)?(?![A-Za-z0-9_]|\.[A-Za-z0-9_])"#,
        #"(?<![A-Za-z0-9_.])[-+]?\d+(?:\.\d+)?(?![A-Za-z0-9_]|\.[A-Za-z0-9_])"#,
    ]
    var literals: [(String, Int)] = []
    var occupied: [NSRange] = []
    for (index, pattern) in patterns.enumerated() {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        for match in expression.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
            guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            occupied.append(match.range)
            let matchedRange = index == 0 ? match.range(at: 1) : match.range
            guard let range = Range(matchedRange, in: original) else { continue }
            let matched = String(original[range])
            let literal = index == 0 ? matched : matched.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            if !literal.isEmpty { literals.append((literal, index)) }
        }
    }
    for (literal, category) in literals {
        // ASCII boundaries allow adjacent CJK prose and sentence punctuation.
        let left: String
        let right: String
        switch category {
        case 0:
            left = #"[A-Za-z0-9_]"#; right = #"[A-Za-z0-9_]"#
        case 1, 2:
            left = #"[A-Za-z0-9_./~:]"#
            right = #"[A-Za-z0-9_/~:@%+?&#=-]|\.[A-Za-z0-9_]"#
        case 3:
            left = #"[A-Za-z0-9_-]"#; right = #"[A-Za-z0-9_=-]"#
        default:
            left = #"[A-Za-z0-9_.+-]"#; right = #"[A-Za-z0-9_]|\.[A-Za-z0-9_]"#
        }
        let pattern = "(?<!" + left + ")" + NSRegularExpression.escapedPattern(for: literal) + "(?!" + right + ")"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(in: polished, range: NSRange(polished.startIndex..., in: polished)) != nil else { return false }
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
