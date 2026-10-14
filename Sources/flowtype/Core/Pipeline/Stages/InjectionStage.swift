import Foundation
import AppKit

/// One terminal delivery. Every external effect owns a cancellation gate.
final class InjectionStage: PipelineStage, @unchecked Sendable {
    var name: String { "Injection" }
    private let settle: @Sendable () async throws -> Void
    private let focus: @MainActor @Sendable () -> FocusSignals
    private let inject: @Sendable (String, SessionContext) async throws -> Void
    private let copy: @MainActor @Sendable (String) -> Void

    init(settle: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) },
         focus: @escaping @MainActor @Sendable () -> FocusSignals = { KeyboardInjector.currentFocusSignals() },
         inject: @escaping @Sendable (String, SessionContext) async throws -> Void = { text, context in
             try await KeyboardInjector.insertText(text, context: context)
         },
         copy: @escaping @MainActor @Sendable (String) -> Void = { text in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
             SoundFeedback.playCopiedToClipboard()
         }) {
        self.settle = settle
        self.focus = focus
        self.inject = inject
        self.copy = copy
    }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .polished(let text, _) = payload else {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: InjectionStageError.invalidPayload, rawText: nil, retryable: false))
        }
        let start = Date()
        do {
            try checkActive(context)
            guard !text.isEmpty else { return .complete }
            guard await MainActor.run(body: { !context.hasInjected }) else { return .complete }
            try checkActive(context)
            try await settle()
            try checkActive(context)
            let signals = await focus()
            try checkActive(context)
            let reserved = await MainActor.run {
                guard !Task.isCancelled, !context.isCancelled, !context.hasInjected else { return false }
                context.hasInjected = true
                return true
            }
            try checkActive(context)
            guard reserved else { return .complete }
            switch decideInjection(signals) {
            case .clipboard:
                try await copyToClipboard(text, context: context)
            case .inject:
                do {
                    try checkActive(context)
                    try await inject(text, context)
                    try checkActive(context)
                } catch {
                    try checkActive(context)
                    guard !(error is CancellationError) else { throw error }
                    AppLogger.log("[InjectionStage] Injection failed; falling back to clipboard: \(error)")
                    try await copyToClipboard(text, context: context)
                }
            }
            try checkActive(context)
            await MainActor.run { if !context.isCancelled { context.injectMs = Int(Date().timeIntervalSince(start) * 1000) } }
            return .complete
        } catch {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: error, rawText: text, retryable: false))
        }
    }

    private func checkActive(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard !context.isCancellationRequested else { throw CancellationError() }
    }

    private func copyToClipboard(_ text: String, context: SessionContext) async throws {
        try checkActive(context)
        let copied = await MainActor.run {
            guard !Task.isCancelled else { return false }
            return context.performIfActive { copy(text) }
        }
        guard copied else { throw CancellationError() }
    }
}

enum InjectionStageError: LocalizedError {
    case invalidPayload
    var errorDescription: String? { "注入失败：无效的文本" }
}
