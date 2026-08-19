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

        // (.injecting is set by the orchestrator's pre-stage transition; the
        // statePublisher subscriber filters .injecting, so we don't re-send it.)
        try? await Task.sleep(nanoseconds: 100_000_000) // let focus settle after the end-tap

        // Decide from the focus at THIS moment (not from whether the app changed):
        // editable text → inject (even across an app switch); a non-text control or secure
        // input → clipboard + sound; AX-blind apps (terminals/Electron) fail open to inject.
        let signals = await MainActor.run { KeyboardInjector.currentFocusSignals() }
        let decision = decideInjection(signals)
        AppLogger.log("[InjectionStage#\(sessionID)] signals=\(signals) → \(decision)")

        switch decision {
        case .clipboard:
            await copyToClipboard(text)
            return .complete
        case .inject:
            do {
                try await KeyboardInjector.insertText(text)
                AppLogger.log("[InjectionStage#\(sessionID)] Injected in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
                return .complete
            } catch is CancellationError {
                AppLogger.log("[InjectionStage#\(sessionID)] Injection cancelled")
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: CancellationError(),
                    rawText: text,
                    retryable: false
                ))
            } catch {
                AppLogger.log("[InjectionStage#\(sessionID)] Injection failed (\(error)); falling back to clipboard")
                await copyToClipboard(text)
                return .complete
            }
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

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "注入失败：无效的文本"
        }
    }
}
