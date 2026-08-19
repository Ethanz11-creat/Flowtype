import Foundation
import AppKit
import AVFoundation
import os

// MARK: - RecordingStage

/// Pipeline stage that handles microphone capture and real-time AppleSpeech preview.
///
/// Input: `.empty`
/// Output: `.audio(samples: [Float], previewText: String)`
final class RecordingStage: PipelineStage, @unchecked Sendable {

    var name: String { "Recording" }

    private let audioRecorder = AudioRecorder()
    private let appleSpeechProvider = AppleSpeechProvider()

    /// Set from the audio heartbeat thread when the mic stops delivering buffers
    /// (device unplugged / Bluetooth disconnect) so the stage can fail explicitly
    /// instead of returning a silent partial transcript.
    private let frozen = OSAllocatedUnfairLock<Bool>(initialState: false)

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        AppLogger.log("[RecordingStage#\(sessionID)] Recording phase started")
        let recordingStart = Date()

        defer {
            let elapsed = Date().timeIntervalSince(recordingStart)
            AppLogger.log("[RecordingStage#\(sessionID)] Recording phase ended (duration: \(String(format: "%.1f", elapsed))s)")
        }

        var previewTask: Task<Void, Never>?
        frozen.withLock { $0 = false }

        do {
            // 1. Request microphone permission
            let granted = await audioRecorder.requestPermission()
            guard granted else {
                let status = audioRecorder.authorizationStatus()
                let message = micPermissionMessage(status: status)
                AppLogger.log("[RecordingStage#\(sessionID)] Mic permission denied (status=\(status)): \(message)")
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: AudioRecorderError.permissionDenied,
                    rawText: nil,
                    retryable: false
                ))
            }

            try Task.checkCancellation()

            // 2. Start audio recording
            let deviceID = ConfigurationStore.shared.current.microphoneDeviceID
            let output = try await audioRecorder.startRecording(deviceID: deviceID)
            AppLogger.log("[RecordingStage#\(sessionID)] AudioRecorder started")

            // Detect a mid-recording freeze (device gone) so we can surface an error.
            audioRecorder.onRecordingFrozen = { [weak self] in
                self?.frozen.withLock { $0 = true }
            }

            // 3. Start AppleSpeech real-time preview streaming
            audioRecorder.onAudioBuffer = { [weak self] buffer in
                self?.appleSpeechProvider.appendAudioBuffer(buffer)
            }
            let previewStream = await appleSpeechProvider.startStreamingRecognition()
            AppLogger.log("[RecordingStage#\(sessionID)] AppleSpeech preview started")

            // Consume preview stream and update preview text in real time
            previewTask = Task { [weak self] in
                guard self != nil else { return }
                for await text in previewStream {
                    await MainActor.run {
                        context.currentPreviewText = text
                        context.previewTextPublisher.send(text)
                    }
                }
            }

            // 4. Consume spectrum stream and update spectrum in real time
            AppLogger.log("[RecordingStage#\(sessionID)] Recording in progress")
            for await spectrum in output.spectrum {
                try Task.checkCancellation()
                await MainActor.run {
                    context.currentSpectrum = spectrum
                    context.spectrumPublisher.send(spectrum)
                }
            }
            AppLogger.log("[RecordingStage#\(sessionID)] Audio spectrum stream ended")

            // 5. Stop recording and collect results
            previewTask?.cancel()
            cleanup()

            let finalPreviewText = appleSpeechProvider.stopStreamingRecognition()
            AppLogger.log("[RecordingStage#\(sessionID)] AppleSpeech final preview: \(finalPreviewText.count) chars")

            // If the spectrum stream ended because the mic froze (not because the user
            // stopped — that path throws CancellationError), fail the session so it
            // recovers to .idle instead of pushing a silent partial transcript.
            if frozen.withLock({ $0 }) {
                AppLogger.log("[RecordingStage#\(sessionID)] Recording interrupted (device froze/disconnected)")
                return .suspend(ErrorRecoveryContext(
                    failedStage: name,
                    error: AudioRecorderError.engineStartFailed,
                    rawText: nil,
                    retryable: false
                ))
            }

            let rawSamples = audioRecorder.takeAccumulatedSamples()
            let audioDuration = Double(rawSamples.count) / 16000.0
            AppLogger.log("[RecordingStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

            await MainActor.run { context.recordingMs = UInt64(audioDuration * 1000) }
            return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))

        } catch is CancellationError {
            AppLogger.log("[RecordingStage#\(sessionID)] Recording cancelled")
            previewTask?.cancel()
            cleanup()
            let finalPreviewText = appleSpeechProvider.stopStreamingRecognition()
            let rawSamples = audioRecorder.takeAccumulatedSamples()
            let audioDuration = Double(rawSamples.count) / 16000.0
            AppLogger.log("[RecordingStage#\(sessionID)] Recording cancelled, samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")
            return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))
        } catch {
            AppLogger.log("[RecordingStage#\(sessionID)] Recording failed: \(error)")
            previewTask?.cancel()
            cleanup()
            _ = appleSpeechProvider.stopStreamingRecognition()
            _ = audioRecorder.takeAccumulatedSamples()
            return .suspend(ErrorRecoveryContext(
                failedStage: name,
                error: error,
                rawText: nil,
                retryable: false
            ))
        }
    }

    // MARK: - Helpers

    private func cleanup() {
        audioRecorder.stopRecording()
        audioRecorder.onAudioBuffer = nil
        audioRecorder.onRecordingFrozen = nil
    }

    private func micPermissionMessage(status: Int) -> String {
        if status == 0 {
            return "麦克风权限未响应。请先退出 Flowtype，重新打开后再试一次。"
        } else if status == 1 {
            return "麦克风权限已拒绝。请前往「系统设置 → 隐私与安全性 → 麦克风」，找到 Flowtype 并开启。"
        } else {
            return "请在系统设置中允许麦克风访问"
        }
    }
}
