import Foundation
@preconcurrency import Speech
import AVFoundation
import os

final class AppleSpeechProvider: @unchecked Sendable {
    var name: String { "AppleSpeech" }
    let id = "apple-preview"
    let displayName = "Apple 语音预览"

    private var recognizer: SFSpeechRecognizer?
    private struct Preview {
        let request: SFSpeechAudioBufferRecognitionRequest
        let session: StreamingPreviewSession
    }
    private let previewLock = OSAllocatedUnfairLock<Preview?>(uncheckedState: nil)
    private let streamingTimeout: TimeInterval = 30.0

    private var recognizerLocaleID: String

    init() {
        let localeID = ConfigurationStore.shared.current.asrLanguage.appleLocaleIdentifier
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        // Only use on-device recognition; if not supported, the recognizer is nil-effectively
        if let r = recognizer {
            AppLogger.log("[AppleSpeechProvider] init: recognizer available, supportsOnDevice=\(r.supportsOnDeviceRecognition), isAvailable=\(r.isAvailable)")
            if !r.supportsOnDeviceRecognition {
                AppLogger.log("[AppleSpeechProvider] WARNING: On-device recognition not supported on this device. AppleSpeech will not be available.")
            }
        } else {
            AppLogger.log("[AppleSpeechProvider] init: recognizer is nil")
        }
        self.recognizer = recognizer
        self.recognizerLocaleID = localeID
    }

    /// The provider instance lives as long as the app, but the user can change the ASR
    /// language at runtime — rebuild the recognizer when the configured locale moved on.
    /// Called only at recognition entry points (start/stop serial convention, no lock).
    private func refreshRecognizerIfNeeded() {
        let configured = ConfigurationStore.shared.current.asrLanguage.appleLocaleIdentifier
        guard configured != recognizerLocaleID else { return }
        AppLogger.log("[AppleSpeechProvider] Locale changed \(recognizerLocaleID) → \(configured), rebuilding recognizer")
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: configured))
        recognizerLocaleID = configured
    }

    /// Check if on-device speech recognition is available on this Mac.
    static func isAvailable() -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: ConfigurationStore.shared.current.asrLanguage.appleLocaleIdentifier)) else {
            return false
        }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    // MARK: - SpeechProvider Protocol

    /// One-shot offline recognition from raw Float32 PCM samples (the `SpeechProvider` contract).
    /// Encodes them to a WAV container, writes to a temp file, then uses
    /// `SFSpeechURLRecognitionRequest` with on-device recognition.
    func transcribe(audioData: Data, timeout: TimeInterval = 20) async throws -> String {
        guard ValidationEffects.live.allow(.modelLoad) else { throw SpeechProviderError.notAvailable }
        refreshRecognizerIfNeeded()
        guard let recognizer = recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            AppLogger.log("[AppleSpeechProvider] transcribe: not available")
            throw SpeechProviderError.notAvailable
        }

        AppLogger.log("[AppleSpeechProvider] transcribe: starting with \(audioData.count) bytes")

        // audioData is raw Float32 PCM per the SpeechProvider contract — encode a WAV
        // container so SFSpeechURLRecognitionRequest can decode it.
        guard let wavData = WAVEncoder.encode(samples: audioData, sampleRate: 16000) else {
            throw SpeechProviderError.transcriptionFailed("空音频数据")
        }

        let tmpDir = RuntimeEnvironment.current.paths.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("flowtype_apple_speech_\(UUID().uuidString).wav")
        try wavData.write(to: tmpFile)
        // §10 audio-never-persists: this is the ONLY audio FlowType ever writes to disk. The defer fires on
        // EVERY exit of transcribe(...) — normal return (isFinal), thrown error / no-result, and the timeout
        // guard below (which cancels the task → resumes the continuation → returns here). Never persist it.
        defer {
            try? FileManager.default.removeItem(at: tmpFile)
        }

        let request = SFSpeechURLRecognitionRequest(url: tmpFile)
        request.requiresOnDeviceRecognition = true

        // Exactly-once resume box: SFSpeech may call back error-then-final or never call
        // back after a cancel — a bare continuation would double-resume (crash) or hang.
        let box = CancellableContinuationBox<String>()
        return try await withCheckedThrowingContinuation { continuation in
            box.setContinuation(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    AppLogger.log("[AppleSpeechProvider] transcribe error: \(error.localizedDescription)")
                    box.resume(throwing: SpeechProviderError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result = result else {
                    AppLogger.log("[AppleSpeechProvider] transcribe: no result")
                    box.resume(throwing: SpeechProviderError.transcriptionFailed("No result"))
                    return
                }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    AppLogger.log("[AppleSpeechProvider] transcribe final: \(text.count) chars")
                    box.resume(returning: text)
                }
            }

            // Timeout guard: resume FIRST (no-op when already finished), then cancel —
            // never depend on the framework delivering an error callback after cancel().
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(throwing: SpeechProviderError.transcriptionFailed("timeout after \(Int(timeout))s"))
                task.cancel()
            }
        }
    }

    // MARK: - Real-time Streaming Recognition (for preview during recording)

    func startStreamingRecognition() async -> AsyncStream<String> {
        let previous = previewLock.withLock { current in
            let previous = current
            current = nil
            return previous
        }
        _ = previous?.session.finish()
        guard ValidationEffects.live.allow(.permissionRequest) else { return AsyncStream { $0.finish() } }
        refreshRecognizerIfNeeded()

        // Check authorization and request if needed
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        AppLogger.log("[AppleSpeechProvider] startStreaming: authStatus=\(authStatus.rawValue) (0=notDetermined,1=denied,2=restricted,3=authorized)")
        if authStatus == .notDetermined {
            AppLogger.log("[AppleSpeechProvider] Requesting speech recognition authorization...")
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    AppLogger.log("[AppleSpeechProvider] Authorization callback: status=\(status.rawValue)")
                    continuation.resume()
                }
            }
            // Re-check after the request completes
            let newStatus = SFSpeechRecognizer.authorizationStatus()
            guard newStatus == .authorized else {
                AppLogger.log("[AppleSpeechProvider] Speech recognition NOT authorized after request (status: \(newStatus.rawValue))")
                return AsyncStream { $0.finish() }
            }
            AppLogger.log("[AppleSpeechProvider] Authorization granted, continuing...")
        } else if authStatus != .authorized {
            AppLogger.log("[AppleSpeechProvider] Speech recognition NOT authorized (status: \(authStatus.rawValue)), skipping preview")
            return AsyncStream { $0.finish() }
        }

        guard let recognizer = recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            let reason = recognizer == nil ? "recognizer=nil" : (recognizer!.isAvailable ? "supportsOnDevice=false" : "isAvailable=false")
            AppLogger.log("[AppleSpeechProvider] On-device speech recognizer not available: \(reason)")
            return AsyncStream { $0.finish() }
        }

        // A stop/deadline may have returned while the authorization prompt was
        // pending. Never resurrect preview recognition for that old recording.
        guard !Task.isCancelled else { return AsyncStream { $0.finish() } }
        AppLogger.log("[AppleSpeechProvider] Starting real-time streaming recognition...")
        let pair = AsyncStream<String>.makeStream()
        let session = StreamingPreviewSession(continuation: pair.continuation, timeout: streamingTimeout)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        session.addCleanup { request.endAudio() }
        let replaced = previewLock.withLock { current in
            let previous = current
            current = Preview(request: request, session: session)
            return previous
        }
        _ = replaced?.session.finish()

        // Capture this attempt's owner, not mutable provider state. Error/final
        // callbacks from an old attempt cannot finish or overwrite a new stream.
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                AppLogger.log("[AppleSpeechProvider] Recognition error: \(error.localizedDescription)")
                session.finish()
                return
            }
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            AppLogger.log("[AppleSpeechProvider] Partial result: \(transcript.count) chars isFinal=\(result.isFinal)")
            session.receive(transcript, isFinal: result.isFinal)
        }
        // Task creation is allowed to callback synchronously. If it already
        // completed/stopped, installation immediately cleans the returned task.
        session.addCleanup { task.cancel() }
        if Task.isCancelled { session.finish() }
        return pair.stream
    }

    // Called by AudioRecorder's tap callback with raw audio buffers
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let preview = previewLock.withLock({ $0 }), !preview.session.isFinished else { return }
        preview.request.append(buffer)
    }

    func stopStreamingRecognition() -> String {
        // finish/endAudio/cancel may synchronously invoke termination callbacks.
        // Both this provider's lock and the session's state lock are released.
        let session = previewLock.withLock { $0?.session }
        return session?.finish() ?? ""
    }
}
