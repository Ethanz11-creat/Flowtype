import Foundation
import AppKit

// MARK: - InjectionStage

/// Pipeline stage that injects text into the active application.
///
/// Input: `.polished(String, raw: String)`
/// Output: `.complete`
final class InjectionStage: PipelineStage, @unchecked Sendable {

    var name: String { "Injection" }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[InjectionStage#\(sessionID)] Started")
        let startTime = Date()

        let text: String
        switch payload {
        case .polished(let polishedText, _):
            text = polishedText
        default:
            AppLogger.log("[InjectionStage#\(sessionID)] Unexpected payload: \(payload), expected .polished")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: InjectionStageError.invalidPayload,
                rawText: nil,
                retryable: false
            ))
        }

        guard !text.isEmpty else {
            AppLogger.log("[InjectionStage#\(sessionID)] Empty text, nothing to inject")
            return .complete
        }

        // Guard against double injection
        let hasInjected = await MainActor.run { context.hasInjected }
        guard !hasInjected else {
            AppLogger.log("[InjectionStage#\(sessionID)] Duplicate injection blocked")
            return .complete
        }
        await MainActor.run { context.hasInjected = true }

        // Capture the app we were dictating into.
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        AppLogger.log("[InjectionStage#\(sessionID)] Target app: \(targetBundleID)")

        // (.injecting is set by the orchestrator's pre-stage transition; the
        // statePublisher subscriber filters .injecting, so we don't re-send it.)
        try? await Task.sleep(nanoseconds: 100_000_000) // let UI settle

        let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let appChanged = currentBundleID != targetBundleID
        let focusState = await MainActor.run { KeyboardInjector.currentFocusState() }

        // Never inject into — or leave a transcript on the clipboard near — a password field.
        if focusState == .secureField {
            AppLogger.log("[InjectionStage#\(sessionID)] Secure field focused — aborting (no inject, no clipboard)")
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: InjectionStageError.secureFieldTarget,
                rawText: nil,
                retryable: false
            ))
        }

        // You switched to a different app since recording started → you walked away, so put the
        // text on the clipboard instead of typing into the wrong place. This is the ONLY
        // condition that diverts to the clipboard. We deliberately do NOT use AX focus
        // detection to decide — it is unreliable in many apps (WeChat / Electron / terminals
        // report "no focused field" even when the cursor IS in a text box), and staying in the
        // same app means the cursor is almost certainly still where you were dictating.
        if appChanged {
            AppLogger.log("[InjectionStage#\(sessionID)] App changed \(targetBundleID)→\(currentBundleID); copied to clipboard")
            await copyToClipboard(text)
            return .complete
        }

        // Same app → inject directly. On failure, fall back to clipboard so text is never lost.
        do {
            try await KeyboardInjector.insertText(text)
            AppLogger.log("[InjectionStage#\(sessionID)] Injected in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            return .complete
        } catch {
            AppLogger.log("[InjectionStage#\(sessionID)] Injection failed (\(error)); falling back to clipboard")
            await copyToClipboard(text)
            return .complete
        }
    }

    private func copyToClipboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            SoundFeedback.playCopiedToClipboard()
        }
    }
}

// MARK: - InjectionStage Errors

enum InjectionStageError: LocalizedError {
    case invalidPayload
    case secureFieldTarget

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "注入失败：无效的文本"
        case .secureFieldTarget:
            return "检测到密码框，已跳过注入以保护隐私"
        }
    }
}
