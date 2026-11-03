import Foundation
import AppKit

/// One reserved terminal attempt, with the first effect claimed only at dispatch.
final class InjectionStage: PipelineStage, @unchecked Sendable {
    var name: String { "Injection" }
    private let settle: @Sendable () async throws -> Void
    private let accessibilityTrusted: @MainActor @Sendable () -> Bool
    private let currentTarget: @Sendable () async -> DeliveryTargetSnapshot
    private let focus: (@MainActor @Sendable () -> FocusSignals)?
    private let inject: (@Sendable (String, SessionContext) async throws -> Void)?
    private let typingEvents: KeyboardInjector.TypingEvents?
    private let mode: @MainActor @Sendable () -> DeliveryMode
    private let bundleID: @MainActor @Sendable (Int32?) -> String?
    private let paste: @MainActor @Sendable (String, SessionContext, DeliveryTargetSnapshot?) async -> PasteTransactionResult
    private let copy: @MainActor @Sendable (String) -> Void

    init(settle: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) },
         accessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = { PermissionHelper.checkAccessibility() },
         focus: (@MainActor @Sendable () -> FocusSignals)? = nil,
         currentTarget: @escaping @Sendable () async -> DeliveryTargetSnapshot = { await KeyboardInjector.currentDeliveryTarget() },
         inject: (@Sendable (String, SessionContext) async throws -> Void)? = nil,
         typingEvents: KeyboardInjector.TypingEvents? = nil,
         mode: @escaping @MainActor @Sendable () -> DeliveryMode = { ConfigurationStore.shared.current.deliveryMode },
         bundleID: @escaping @MainActor @Sendable (Int32?) -> String? = { pid in
             pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
         },
         paste: @escaping @MainActor @Sendable (String, SessionContext, DeliveryTargetSnapshot?) async -> PasteTransactionResult = { text, context, target in
             await KeyboardInjector.pasteText(text, context: context) {
                 decideDelivery(target: target, current: await KeyboardInjector.currentDeliveryTarget()) == .inject
             }
         },
         copy: @escaping @MainActor @Sendable (String) -> Void = { text in
             KeyboardInjector.copyText(text)
             SoundFeedback.playCopiedToClipboard()
         }) {
        self.settle = settle
        self.accessibilityTrusted = accessibilityTrusted
        self.focus = focus
        self.currentTarget = currentTarget
        self.inject = inject
        self.typingEvents = typingEvents
        self.copy = copy
        self.mode = mode
        self.bundleID = bundleID
        self.paste = paste
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
            let selectedMode = await MainActor.run { mode() }
            try checkActive(context)
            try await settle()
            let target = await context.resolvedDeliveryTarget()
            try checkActive(context)
            let current: DeliveryTargetSnapshot
            if let focus {
                current = await DeliveryTargetSnapshot(pid: target?.pid, signals: focus())
            } else { current = await currentTarget() }
            try checkActive(context)
            let trusted = await MainActor.run { accessibilityTrusted() }
            try checkActive(context)
            let decision = applyAccessibilityGate(decideDelivery(target: target, current: current),
                                                  accessibilityTrusted: trusted)
            let method = await MainActor.run {
                decision == .clipboard ? DeliveryMethod.clipboard :
                    resolveDeliveryMethod(mode: selectedMode, signals: current.signals,
                        accessibilityTrusted: trusted, bundleID: bundleID(current.pid))
            }
            try checkActive(context)
            switch method {
            case .clipboard:
                try await copyToClipboard(text, context: context)
                await MainActor.run {
                    guard !context.isCancelled else { return }
                    let changed = target?.pid != current.pid ||
                        (target?.focusIdentity != nil && current.focusIdentity != nil && target?.focusIdentity != current.focusIdentity)
                    context.capsuleNotice = .clipboard
                    context.completionNotice = DeliveryCopy.forOutcome(.clipboard, focusChanged: changed)?.message
                }
                await complete(.clipboard, context: context, start: start)
            case .type:
                return await typeText(text, context: context, preserveClipboardOnFailure: false, start: start,
                    validate: typingValidator(target: target, context: context, requiresEditable: false))
            case .paste:
                let result = await paste(text, context, target)
                switch result {
                case .dispatched: await complete(.pasteDispatched, context: context, start: start)
                case .uncertain: await complete(.uncertain, context: context, start: start)
                case .cancelled: await complete(.cancelled, context: context, start: start)
                case .clipboardChanged:
                    await complete(.uncertain, context: context, start: start)
                    await MainActor.run {
                        if !context.isCancelled { context.completionNotice = DeliveryCopy.clipboardOwnershipChanged.message }
                    }
                case .unsafeSnapshot, .notDispatched:
                    try checkActive(context)
                    if selectedMode == .automatic {
                        let refreshed = await currentTarget()
                        try checkActive(context)
                        let trusted = await MainActor.run { accessibilityTrusted() }
                        try checkActive(context)
                        if canFallbackToTyping(mode: selectedMode, pasteResult: result,
                            eventDispatched: context.deliveryEventStarted, target: target,
                            current: refreshed, accessibilityTrusted: trusted) {
                            return await typeText(text, context: context,
                                preserveClipboardOnFailure: true, start: start,
                                validate: typingValidator(target: target, context: context, requiresEditable: true))
                        }
                    }
                    return .suspend(ErrorRecoveryContext(failedStage: name,
                        error: result == .unsafeSnapshot ? InjectionStageError.clipboardSnapshotIncomplete : .pasteNotDispatched,
                        rawText: text, retryable: false, failureKind: .deliveryBlocked, textKind: .result))
                }
            }
            return .complete
        } catch {
            // A cancelled duplicate invocation does not own the live attempt.
            if !ownsAttempt, await context.deliveryAttempted { return .complete }
            let outcome: DeliveryOutcome = context.deliveryEventStarted ? .uncertain : .cancelled
            await complete(outcome, context: context, start: start)
            if outcome == .uncertain { return .complete }
            return .suspend(ErrorRecoveryContext(failedStage: name, error: error, rawText: text, retryable: false,
                failureKind: FailureClassifier.classify(error) == .cancelled ? .cancelled : .deliveryBlocked, textKind: .result))
        }
    }

    private func typeText(_ text: String, context: SessionContext,
                          preserveClipboardOnFailure: Bool, start: Date,
                          validate: @escaping @Sendable () async throws -> Void) async -> StageResult {
        do {
            try checkActive(context)
            if let inject { try await inject(text, context) }
            else { try await KeyboardInjector.insertText(text, context: context, validate: validate, events: typingEvents) }
            try checkActive(context)
            guard context.deliveryEventStarted else { throw InjectionError.noEventsDispatched }
            await complete(.typedDispatched, context: context, start: start)
            return .complete
        } catch {
            if context.deliveryEventStarted {
                await complete(.uncertain, context: context, start: start)
                return .complete
            }
            do {
                try checkActive(context)
                if FailureClassifier.classify(error) == .cancelled { throw error }
                // The paste transaction protected this board. Failure before the
                // fallback's first pair must not replace it with recovery text.
                if preserveClipboardOnFailure {
                    return .suspend(ErrorRecoveryContext(failedStage: name,
                        error: error, rawText: text, retryable: false,
                        failureKind: FailureClassifier.classify(error) == .cancelled ? .cancelled : .deliveryBlocked, textKind: .result))
                }
                try await copyToClipboard(text, context: context)
                await MainActor.run {
                    if !context.isCancelled {
                        context.capsuleNotice = .clipboard
                        context.completionNotice = DeliveryCopy.forOutcome(.clipboard)?.message
                    }
                }
                await complete(.clipboard, context: context, start: start)
                return .complete
            } catch {
                await complete(.cancelled, context: context, start: start)
                return .suspend(ErrorRecoveryContext(failedStage: name,
                    error: error, rawText: text, retryable: false,
                    failureKind: FailureClassifier.classify(error) == .cancelled ? .cancelled : .deliveryBlocked, textKind: .result))
            }
        }
    }

    private func typingValidator(target: DeliveryTargetSnapshot?, context: SessionContext,
                                 requiresEditable: Bool) -> @Sendable () async throws -> Void {
        { [self] in
            try checkActive(context)
            let fresh = await currentTarget()
            try checkActive(context)
            let permitted = await MainActor.run { accessibilityTrusted() }
            try checkActive(context)
            guard permitted, (!requiresEditable || fresh.signals.focus == .editableText),
                  decideDelivery(target: target, current: fresh) == .inject else {
                throw InjectionError.targetNoLongerSafe
            }
        }
    }

    private func complete(_ outcome: DeliveryOutcome, context: SessionContext, start: Date) async {
        await MainActor.run {
            let effective: DeliveryOutcome =
                (outcome == .typedDispatched || outcome == .pasteDispatched) && (context.isCancelled || Task.isCancelled)
                ? .uncertain : outcome
            context.finishDelivery(effective)
            context.stopToDeliveryMs = context.stopRecordingAt.map { Int((context.deliveryEventDispatchedAt ?? Date()).timeIntervalSince($0) * 1000) }
            guard !context.isCancelled else { return }
            context.injectMs = Int(Date().timeIntervalSince(start) * 1000)
            if effective == .uncertain { context.completionNotice = DeliveryCopy.forOutcome(.uncertain)?.message }
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
    case clipboardSnapshotIncomplete
    case pasteNotDispatched
    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "注入失败：无效的文本"
        case .clipboardSnapshotIncomplete: return "剪贴板内容无法完整读取，未发送粘贴"
        case .pasteNotDispatched: return "粘贴未发送，文本可从错误卡片复制"
        }
    }
}
