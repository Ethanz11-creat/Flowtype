import Foundation
import AppKit

/// One reserved terminal attempt, with the first effect claimed only at dispatch.
final class InjectionStage: PipelineStage, @unchecked Sendable {
    var name: String { "Injection" }
    private let settle: @Sendable () async throws -> Void
    private let currentTarget: @Sendable () async -> DeliveryTargetSnapshot
    private let focus: (@MainActor @Sendable () -> FocusSignals)?
    private let inject: @Sendable (String, SessionContext) async throws -> Void
    private let copy: @MainActor @Sendable (String) -> Void

    init(settle: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) },
         focus: (@MainActor @Sendable () -> FocusSignals)? = nil,
         currentTarget: @escaping @Sendable () async -> DeliveryTargetSnapshot = { await KeyboardInjector.currentDeliveryTarget() },
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
        self.currentTarget = currentTarget
        self.inject = inject
        self.copy = copy
    }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        guard case .polished(let text, _) = payload else {
            return .suspend(ErrorRecoveryContext(failedStage: name, error: InjectionStageError.invalidPayload, rawText: nil, retryable: false))
        }
        let start = Date()
        var ownsAttempt = false
        do {
            try checkActive(context)
            guard !text.isEmpty else { return .complete }
            let reserved = await MainActor.run { !Task.isCancelled && context.beginDeliveryAttempt() }
            guard reserved else { return .complete }
            ownsAttempt = true
            try checkActive(context)
            try await settle()
            let target = await context.resolvedDeliveryTarget()
            try checkActive(context)
            let current: DeliveryTargetSnapshot
            if let focus {
                current = await DeliveryTargetSnapshot(pid: target?.pid, signals: focus())
            } else { current = await currentTarget() }
            try checkActive(context)
            let outcome: DeliveryOutcome
            switch decideDelivery(target: target, current: current) {
            case .clipboard:
                try await copyToClipboard(text, context: context)
                outcome = .clipboard
                await MainActor.run {
                    guard !context.isCancelled else { return }
                    let changed = target?.pid != current.pid ||
                        (target?.focusIdentity != nil && current.focusIdentity != nil && target?.focusIdentity != current.focusIdentity)
                    context.completionNotice = changed ? "焦点已变化 · 已复制，按 ⌘V 粘贴" : "已复制，按 ⌘V 粘贴"
                }
            case .inject:
                do {
                    try checkActive(context)
                    try await inject(text, context)
                    try checkActive(context)
                    guard context.deliveryEffectStarted else { throw InjectionError.noEventsDispatched }
                    outcome = .typedDispatched
                } catch {
                    if context.deliveryEffectStarted {
                        await complete(.uncertain, context: context, start: start)
                        return .complete
                    }
                    try checkActive(context)
                    guard !(error is CancellationError) else { throw error }
                    try await copyToClipboard(text, context: context)
                    await MainActor.run {
                        if !context.isCancelled { context.completionNotice = "已复制，按 ⌘V 粘贴" }
                    }
                    outcome = .clipboard
                }
            }
            // An effect may complete just as cancellation arrives; keep the honest
            // terminal result on the old context, whose UI is already invalidated.
            await complete(outcome, context: context, start: start)
            return .complete
        } catch {
            // A cancelled duplicate invocation does not own the live attempt.
            if !ownsAttempt, await context.deliveryAttempted { return .complete }
            let outcome: DeliveryOutcome = context.deliveryEffectStarted ? .uncertain : .cancelled
            await complete(outcome, context: context, start: start)
            if outcome == .uncertain { return .complete }
            return .suspend(ErrorRecoveryContext(failedStage: name, error: error, rawText: text, retryable: false))
        }
    }

    private func complete(_ outcome: DeliveryOutcome, context: SessionContext, start: Date) async {
        await MainActor.run {
            let effective: DeliveryOutcome =
                (outcome == .typedDispatched || outcome == .pasteDispatched) && (context.isCancelled || Task.isCancelled)
                ? .uncertain : outcome
            context.finishDelivery(effective)
            guard !context.isCancelled else { return }
            context.injectMs = Int(Date().timeIntervalSince(start) * 1000)
            if effective == .uncertain { context.completionNotice = "已发送 · 可从历史复制" }
        }
    }

    private func checkActive(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard !context.isCancellationRequested else { throw CancellationError() }
    }

    private func copyToClipboard(_ text: String, context: SessionContext) async throws {
        try checkActive(context)
        let copied = await MainActor.run {
            guard !Task.isCancelled, !context.deliveryEffectStarted else { return false }
            return context.performDeliveryEffect { copy(text) }
        }
        guard copied else { throw CancellationError() }
    }
}

enum InjectionStageError: LocalizedError {
    case invalidPayload
    var errorDescription: String? { "注入失败：无效的文本" }
}
