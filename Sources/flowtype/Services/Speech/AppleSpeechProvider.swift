import Foundation
import Speech
import AVFoundation

final class AppleSpeechProvider: SpeechProvider, @unchecked Sendable {
    var name: String { "AppleSpeech" }

    private var recognizer: SFSpeechRecognizer?
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private nonisolated(unsafe) var recognitionTask: SFSpeechRecognitionTask?

    private nonisolated(unsafe) var previewContinuation: AsyncStream<String>.Continuation?
    private nonisolated(unsafe) var finalResult: String = ""

    init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    // MARK: - SpeechProvider Protocol

    func transcribe(audioData: Data, timeout: TimeInterval = 20) async throws -> String {
        throw SpeechProviderError.notAvailable
    }

    // MARK: - Real-time Streaming Recognition

    func startStreamingRecognition() -> AsyncStream<String> {
        finalResult = ""

        // Check authorization and request if needed
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            print("[AppleSpeechProvider] Requesting speech recognition authorization...")
            SFSpeechRecognizer.requestAuthorization { _ in }
            // Return empty stream this time; next toggle will have auth status
            return AsyncStream { $0.finish() }
        }
        guard authStatus == .authorized else {
            print("[AppleSpeechProvider] Speech recognition not authorized (status: \(authStatus.rawValue)), skipping preview")
            return AsyncStream { $0.finish() }
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("[AppleSpeechProvider] Speech recognizer not available")
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            self.previewContinuation = continuation

            // Create recognition request
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false
            self.recognitionRequest = request

            // Create recognition task
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }

                if error != nil {
                    self.previewContinuation?.finish()
                    return
                }

                guard let result = result else { return }

                let transcript = result.bestTranscription.formattedString
                self.finalResult = transcript
                self.previewContinuation?.yield(transcript)

                if result.isFinal {
                    self.previewContinuation?.finish()
                }
            }

            continuation.onTermination = { [weak self] _ in
                _ = self?.stopStreamingRecognition()
            }
        }
    }

    // Called by AudioRecorder's tap callback with raw audio buffers
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopStreamingRecognition() -> String {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        return finalResult
    }
}
