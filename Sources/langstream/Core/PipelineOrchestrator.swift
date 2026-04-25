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
    private(set) var isRecording = false

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
        isRecording = true
        appState.clearTranscription()
        WindowManager.shared.showWindow()

        recordingTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // 1. Check microphone permission
                print("[PipelineOrchestrator] Requesting mic permission...")
                self.appState.transition(to: .requestingPermission)
                let granted = await self.audioRecorder.requestPermission()
                guard granted else {
                    print("[PipelineOrchestrator] Mic permission denied")
                    self.appState.showError("请在系统设置中允许麦克风访问")
                    self.isRecording = false
                    return
                }
                print("[PipelineOrchestrator] Mic permission granted")

                // 2. Start AudioRecorder
                self.appState.transition(to: .recording(elapsedSeconds: 0))
                print("[PipelineOrchestrator] Starting AudioRecorder...")
                let amplitudeStream = try await self.audioRecorder.startRecording()
                print("[PipelineOrchestrator] AudioRecorder started")

                // 3. Consume amplitude stream (blocks until cancelled)
                print("[PipelineOrchestrator] Waiting for audio stream...")
                for await amplitude in amplitudeStream {
                    if Task.isCancelled {
                        print("[PipelineOrchestrator] Recording task cancelled")
                        break
                    }
                    self.appState.updateAmplitude(amplitude)
                }
                print("[PipelineOrchestrator] Audio stream ended")

            } catch {
                print("[PipelineOrchestrator] Recording failed: \(error)")
                self.appState.showError("录音启动失败: \(error.localizedDescription)")
                self.isRecording = false
            }
        }
    }

    private func stopRecording() {
        print("[PipelineOrchestrator] stopRecording called")
        isRecording = false

        // 1. Stop AudioRecorder
        print("[PipelineOrchestrator] Stopping AudioRecorder...")
        let (audioData, _) = self.audioRecorder.stopRecording()
        recordingTask?.cancel()

        // 2. Validate audio data (only real blocker)
        guard let audioData = audioData, !audioData.isEmpty else {
            print("[PipelineOrchestrator] Audio data is empty")
            self.appState.showError("录音数据为空")
            return
        }

        // 3. Cloud ASR — MAIN RECOGNITION PATH
        self.appState.transition(to: .processingASR(provider: "云端识别"))
        print("[PipelineOrchestrator] Starting cloud ASR...")

        Task { [weak self] in
            guard let self = self else { return }

            // TeleSpeech primary, SenseVoice fallback
            let asrResult = await self.asyncRefiner.transcribeWithFallback(audioData: audioData)

            guard let result = asrResult, !result.text.isEmpty else {
                print("[PipelineOrchestrator] Cloud ASR returned empty")
                self.appState.showError("未能识别到语音")
                return
            }

            // 4. Display recognized text in capsule (local rendering)
            self.appState.recognizedText = result.text
            self.appState.previewText = result.text
            print("[PipelineOrchestrator] Recognized: '\(result.text)' from \(result.provider)")

            // 5. Hide window before injection so focus returns to previous app
            WindowManager.shared.hide()
            // Give OS time to switch focus back to the target app
            try? await Task.sleep(nanoseconds: 150_000_000)

            // 6. Inject final text
            self.appState.transition(to: .injecting)
            print("[PipelineOrchestrator] Injecting text...")
            do {
                try await KeyboardInjector.insertText(result.text)
                print("[PipelineOrchestrator] Text injected")
            } catch {
                print("[PipelineOrchestrator] Injection failed: \(error)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                self.appState.showError("已复制到剪贴板")
            }

            // 6. Optional background LLM polish (UI only, no re-injection)
            await self.asyncRefiner.polishIfNeeded(text: result.text, appState: self.appState)

            // Hide window after everything completes
            WindowManager.shared.hide()
            self.appState.transition(to: .idle)
        }
    }
}
