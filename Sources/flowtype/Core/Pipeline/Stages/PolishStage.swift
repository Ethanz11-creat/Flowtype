import Foundation

/// Full-text fallback preserves PostProcess corrections; raw is only a last resort.
func polishFallbackText(processed: String, raw: String) -> String {
    processed.isEmpty ? raw : processed
}

/// Optional enhancement: only a completed stream may replace the processed text.
final class PolishStage: PipelineStage, @unchecked Sendable {
    static let stageName = "Polish"
    var name: String { Self.stageName }

    private let llmService = LLMService()
    private let streamFactory: (@Sendable (String, Configuration) async -> AsyncThrowingStream<String, Error>)?
    private let configuration: @MainActor @Sendable () -> Configuration
    private let deadlineSeconds: TimeInterval

    init(configuration: @escaping @MainActor @Sendable () -> Configuration = { ConfigurationStore.shared.current },
         deadlineSeconds: TimeInterval = 3,
         streamFactory: (@Sendable (String, Configuration) async -> AsyncThrowingStream<String, Error>)? = nil) {
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
                    await streamFactory(fallback, config)
                } else {
                    await llmService.polishText(fallback, systemPrompt: prompt, config: config, timeoutSeconds: timeout)
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
            let final = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : result
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

enum PolishStageError: Error { case invalidPayload }
