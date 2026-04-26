import Foundation
import AppKit

@MainActor
final class PipelineOrchestrator {
    static let shared: PipelineOrchestrator = {
        let instance = PipelineOrchestrator()
        return instance
    }()

    private let appState = AppState()
    private let audioRecorder = AudioRecorder()
    private let speechRouter = SpeechRouter()
    private let llmService = LLMService()
    private lazy var asyncRefiner = AsyncRefiner(speechRouter: speechRouter, llmService: llmService)

    private var recordingTask: Task<Void, Never>?

    /// Derived from appState — single source of truth.
    var isRecording: Bool { appState.state.isRecordingIndicator }

    var state: AppState { appState }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        print("[PipelineOrchestrator] startRecording called")
        appState.clearTranscription()

        // Show window immediately with correct state so UI never shows stale .idle
        appState.transition(to: .recording(elapsedSeconds: 0))
        WindowManager.shared.showWindow()

        recordingTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // 1. Check microphone permission (fast path if already granted)
                print("[PipelineOrchestrator] Requesting mic permission...")
                let granted = await self.audioRecorder.requestPermission()
                guard granted else {
                    print("[PipelineOrchestrator] Mic permission denied")
                    self.appState.showError("请在系统设置中允许麦克风访问")
                    return
                }
                print("[PipelineOrchestrator] Mic permission granted")
                try Task.checkCancellation()

                // 2. Start AudioRecorder
                print("[PipelineOrchestrator] Starting AudioRecorder...")
                let amplitudeStream = try await self.audioRecorder.startRecording()
                print("[PipelineOrchestrator] AudioRecorder started")

                // 3. Consume amplitude stream (blocks until stream finishes or task cancelled)
                print("[PipelineOrchestrator] Waiting for audio stream...")
                for await amplitude in amplitudeStream {
                    try Task.checkCancellation()
                    self.appState.updateAmplitude(amplitude)
                }
                print("[PipelineOrchestrator] Audio stream ended")

            } catch is CancellationError {
                print("[PipelineOrchestrator] Recording task cancelled")
            } catch {
                print("[PipelineOrchestrator] Recording failed: \(error)")
                self.appState.showError("录音启动失败: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        print("[PipelineOrchestrator] stopRecording called, currentState=\(appState.state)")

        // Defensive: if somehow we're not actually recording, just bail
        guard isRecording else {
            print("[PipelineOrchestrator] stopRecording: not in recording state, bailing")
            return
        }

        // 1. Stop AudioRecorder
        print("[PipelineOrchestrator] Stopping AudioRecorder...")
        let (audioData, _) = self.audioRecorder.stopRecording()
        recordingTask?.cancel()
        recordingTask = nil

        // 2. Validate audio data (only real blocker)
        guard let audioData = audioData, !audioData.isEmpty else {
            print("[PipelineOrchestrator] Audio data is empty")
            self.appState.showError("录音数据为空")
            return
        }

        // Audio diagnostics
        let wavHeaderSize = 44
        let audioPayloadSize = audioData.count - wavHeaderSize
        let estimatedDuration = Double(audioPayloadSize) / 32000.0 // 16kHz, mono, 16-bit = 32000 bytes/sec
        print("[PipelineOrchestrator] Audio: \(audioData.count) bytes total, ~\(String(format: "%.1f", estimatedDuration))s duration")
        if audioPayloadSize <= 0 {
            print("[PipelineOrchestrator] WARNING: Audio payload is empty (only WAV header)")
        }

        // 3. Cloud ASR — MAIN RECOGNITION PATH
        self.appState.transition(to: .processingASR(provider: "云端识别"))
        print("[PipelineOrchestrator] Starting cloud ASR...")

        Task { [weak self] in
            guard let self = self else { return }

            // Parallel TeleSpeech + SenseVoice with scoring
            let asrResult = await self.asyncRefiner.transcribeWithScoring(audioData: audioData)

            guard let result = asrResult, !result.text.isEmpty else {
                print("[PipelineOrchestrator] Cloud ASR returned empty")
                self.appState.showError("未能识别到语音")
                return
            }

            // 4. Post-process ASR text
            let processedText = ASRPostProcessor.process(result.text)
            let didChange = processedText != result.text
            if didChange {
                print("[PipelineOrchestrator] Post-processed: '\(result.text)' -> '\(processedText)'")
            }

            // 5. Display recognized text in capsule (local rendering)
            self.appState.recognizedText = processedText
            self.appState.previewText = processedText
            print("[PipelineOrchestrator] Recognized: '\(processedText)' from \(result.provider)")

            // 6. Hide window before injection so focus returns to previous app
            WindowManager.shared.hide()
            // Give OS time to switch focus back to the target app
            try? await Task.sleep(nanoseconds: 150_000_000)

            // 7. Inject final text
            self.appState.transition(to: .injecting)
            print("[PipelineOrchestrator] Injecting text...")
            do {
                try await KeyboardInjector.insertText(processedText)
                print("[PipelineOrchestrator] Text injected")
            } catch {
                print("[PipelineOrchestrator] Injection failed: \(error)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(processedText, forType: .string)
                self.appState.showError("已复制到剪贴板")
            }

            // 8. Optional background LLM polish (UI only, no re-injection)
            await self.asyncRefiner.polishIfNeeded(text: processedText, appState: self.appState)

            // Hide window after everything completes
            WindowManager.shared.hide()
            self.appState.transition(to: .idle)
        }
    }
}
