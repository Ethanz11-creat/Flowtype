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
    private let contextProvider: ContextProvider = AXContextProvider()

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

            if await MainActor.run(body: { context.isCancelled }) {
                audioRecorder.stopRecording()
                return .complete
            }

            // Install the readiness callback immediately after capture starts so
            // the first valid PCM buffer, including one that arrives while
            // foreground context is being collected, gates the UI transition.
            audioRecorder.onAudioBuffer = { [weak self] buffer in
                self?.appleSpeechProvider.appendAudioBuffer(buffer)
                guard buffer.frameLength > 0 else { return }
                Task { @MainActor in
                    context.markReady()
                }
            }

            // 采集一次前台上下文（失败则静默跳过，不阻断录音）。
            // 本地优先与云端策略都采集：本地 Qwen 直接用（不上传），云端可能随请求发送。
            if let fg = await contextProvider.collect(),
               let text = buildContextText(fg) {
                await MainActor.run { context.foregroundContextText = text }
                AppLogger.log("[RecordingStage#\(sessionID)] Foreground context: \(text.count) chars")
            }

            // Detect a mid-recording freeze (device gone) so we can surface an error.
            audioRecorder.onRecordingFrozen = { [weak self] in
                self?.frozen.withLock { $0 = true }
            }

            // 3. Start AppleSpeech real-time preview streaming
            let previewStream = await appleSpeechProvider.startStreamingRecognition()
            AppLogger.log("[RecordingStage#\(sessionID)] AppleSpeech preview started")

            // AppleSpeech 预览仅作内部兜底文本：不再上屏（产品判断：不做中间文本展示）。
            previewTask = Task { [weak self] in
                guard self != nil else { return }
                for await text in previewStream {
                    await MainActor.run { context.currentPreviewText = text }
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
            if await MainActor.run(body: { context.isCancelled }) {
                return .complete
            }
            return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))
        } catch {
            AppLogger.log("[RecordingStage#\(sessionID)] Recording failed: \(error)")
            previewTask?.cancel()
            cleanup()
            _ = appleSpeechProvider.stopStreamingRecognition()
            _ = audioRecorder.takeAccumulatedSamples()
            if await MainActor.run(body: { context.isCancelled }) {
                return .complete
            }
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
