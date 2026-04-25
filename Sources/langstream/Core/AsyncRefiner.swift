import Foundation

/// Manages asynchronous refinement:
/// 1. Concurrent cloud ASR (TeleSpeech + SenseVoice race)
/// 2. Non-blocking LLM polish (UI only)
@MainActor
final class AsyncRefiner {
    private let speechRouter: SpeechRouter
    private let llmService: LLMService

    init(speechRouter: SpeechRouter, llmService: LLMService) {
        self.speechRouter = speechRouter
        self.llmService = llmService
    }

    // MARK: - Public API

    /// Try TeleSpeech first, fallback to SenseVoice if it fails/timeouts
    func transcribeWithFallback(audioData: Data) async -> TranscriptionResult? {
        // TeleSpeech first — usually better quality for Chinese
        do {
            let text = try await self.speechRouter.primaryProvider.transcribe(
                audioData: audioData,
                timeout: 15
            )
            if !text.isEmpty {
                print("[AsyncRefiner] TeleSpeech succeeded")
                return TranscriptionResult(text: text, provider: "TeleSpeech", isFallback: false, duration: 0)
            }
        } catch {
            print("[AsyncRefiner] TeleSpeech failed: \(error)")
        }

        // Fallback to SenseVoice
        do {
            let text = try await self.speechRouter.fallbackProvider.transcribe(
                audioData: audioData,
                timeout: 10
            )
            if !text.isEmpty {
                print("[AsyncRefiner] SenseVoice fallback succeeded")
                return TranscriptionResult(text: text, provider: "SenseVoice", isFallback: true, duration: 0)
            }
        } catch {
            print("[AsyncRefiner] SenseVoice fallback failed: \(error)")
        }

        return nil
    }

    /// LLM polish — UI only, no delta injection
    func polishIfNeeded(text: String, appState: AppState) async {
        guard LLMService.shouldPolish(text) != nil else {
            print("[AsyncRefiner] Skipping LLM polish for low-value text")
            return
        }

        appState.transition(to: .polishing(preview: ""))
        var polishedText = ""

        do {
            let stream = await llmService.polishText(text)
            for try await chunk in stream {
                polishedText += chunk
                appState.updatePolishingPreview(polishedText)
            }

            if !polishedText.isEmpty && polishedText != text {
                print("[AsyncRefiner] LLM polished: '\(polishedText)'")
                // UI update only — do NOT re-inject
                appState.recognizedText = polishedText
                appState.previewText = polishedText
            }
        } catch LLMError.timeout {
            print("[AsyncRefiner] LLM polish timed out, keeping ASR text")
        } catch {
            print("[AsyncRefiner] LLM polish failed: \(error)")
        }
    }

    /// Text-only segment refinement during recording (Phase 2)
    func refineSegmentText(text: String, appState: AppState) async {
        guard LLMService.shouldPolish(text) != nil else {
            print("[AsyncRefiner] Skipping text-only refinement for: '\(text)'")
            return
        }

        appState.isRefining = true
        defer { appState.isRefining = false }

        do {
            let stream = await self.llmService.polishText(text)
            var polishedText = ""
            for try await chunk in stream {
                polishedText += chunk
            }
            if !polishedText.isEmpty && polishedText != text {
                print("[AsyncRefiner] Segment polished: '\(polishedText)'")
                appState.stableText = appState.stableText.replacingOccurrences(of: text, with: polishedText)
            }
        } catch LLMError.timeout {
            print("[AsyncRefiner] Segment LLM timed out")
        } catch {
            print("[AsyncRefiner] Segment LLM failed: \(error)")
        }
    }
}

private extension Character {
    var isChinese: Bool {
        return "\u{4E00}" <= self && self <= "\u{9FFF}"
    }
}
