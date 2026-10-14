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

    private let contextProvider: ContextProvider = AXContextProvider()

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        // Capture and preview resources belong to this execution alone.
        let audioRecorder = AudioRecorder()
        let appleSpeechProvider = AppleSpeechProvider()
        let frozen = OSAllocatedUnfairLock<Bool>(initialState: false)
        AppLogger.log("[RecordingStage#\(sessionID)] Recording phase started")
        let recordingStart = Date()

        defer {
            let elapsed = Date().timeIntervalSince(recordingStart)
            AppLogger.log("[RecordingStage#\(sessionID)] Recording phase ended (duration: \(String(format: "%.1f", elapsed))s)")
        }

        return await withTaskCancellationHandler {
            var previewTask: Task<Void, Never>?
            frozen.withLock { $0 = false }

            // Install callbacks before starting the recorder. AudioRecorder may
            // receive its first tap before startRecording() returns; the owner token
            // fences callbacks from any older session.
            audioRecorder.onAudioBuffer = { buffer in
                guard buffer.frameLength > 0 else { return }
                guard context.performIfActive({ appleSpeechProvider.appendAudioBuffer(buffer) }) else { return }
                Task { @MainActor in
                    guard !context.isCancelled else { return }
                    context.markReady()
                }
            }
            audioRecorder.onRecordingFrozen = {
                frozen.withLock { $0 = true }
            }

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
                let output = try await audioRecorder.startRecording(deviceID: deviceID, ownerID: sessionID)
                AppLogger.log("[RecordingStage#\(sessionID)] AudioRecorder started")

                if await MainActor.run(body: { context.isCancelled }) {
                    cleanup(recorder: audioRecorder, ownerID: sessionID)
                    return .complete
                }

                // 采集一次前台上下文（失败则静默跳过，不阻断录音）。
                // 本地优先与云端策略都采集：本地 Qwen 直接用（不上传），云端可能随请求发送。
                try Task.checkCancellation()
                if let fg = await contextProvider.collect(),
                   let text = buildContextText(fg) {
                    await MainActor.run {
                        guard !context.isCancelled else { return }
                        context.foregroundContextText = text
                    }
                    AppLogger.log("[RecordingStage#\(sessionID)] Foreground context: \(text.count) chars")
                }

                // Detect a mid-recording freeze (device gone) so we can surface an error.
                // 3. Start AppleSpeech real-time preview streaming
                try Task.checkCancellation()
                let previewStream = await appleSpeechProvider.startStreamingRecognition()
                try Task.checkCancellation()
                AppLogger.log("[RecordingStage#\(sessionID)] AppleSpeech preview started")

                // AppleSpeech 预览仅作内部兜底文本：不再上屏（产品判断：不做中间文本展示）。
                previewTask = Task { [weak self] in
                    guard self != nil else { return }
                    for await text in previewStream {
                        await MainActor.run {
                            guard !context.isCancelled else { return }
                            context.currentPreviewText = text
                        }
                    }
                }

                // 4. Consume spectrum stream and update spectrum in real time
                AppLogger.log("[RecordingStage#\(sessionID)] Recording in progress")
                for await spectrum in output.spectrum {
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard !context.isCancelled else { return }
                        context.currentSpectrum = spectrum
                        context.spectrumPublisher.send(spectrum)
                    }
                }
                AppLogger.log("[RecordingStage#\(sessionID)] Audio spectrum stream ended")

                // 5. Stop recording and collect results
                previewTask?.cancel()
                let ownsRecorder = audioRecorder.owns(sessionID)
                let rawSamples = audioRecorder.takeAccumulatedSamples(ownerID: sessionID)
                let finalPreviewText = ownsRecorder ? appleSpeechProvider.stopStreamingRecognition() : ""
                cleanup(recorder: audioRecorder, ownerID: sessionID)
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

                let audioDuration = Double(rawSamples.count) / 16000.0
                AppLogger.log("[RecordingStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")

                await MainActor.run {
                    guard !context.isCancelled else { return }
                    context.recordingMs = UInt64(audioDuration * 1000)
                }
                return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))

            } catch is CancellationError {
                AppLogger.log("[RecordingStage#\(sessionID)] Recording cancelled")
                previewTask?.cancel()
                let ownsRecorder = audioRecorder.owns(sessionID)
                let rawSamples = audioRecorder.takeAccumulatedSamples(ownerID: sessionID)
                let finalPreviewText = ownsRecorder ? appleSpeechProvider.stopStreamingRecognition() : ""
                cleanup(recorder: audioRecorder, ownerID: sessionID)
                let audioDuration = Double(rawSamples.count) / 16000.0
                AppLogger.log("[RecordingStage#\(sessionID)] Recording cancelled, samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")
                if await MainActor.run(body: { context.isCancelled }) {
                    return .complete
                }
                return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))
            } catch {
                AppLogger.log("[RecordingStage#\(sessionID)] Recording failed: \(error)")
                previewTask?.cancel()
                let ownsRecorder = audioRecorder.owns(sessionID)
                if ownsRecorder { _ = appleSpeechProvider.stopStreamingRecognition() }
                cleanup(recorder: audioRecorder, ownerID: sessionID)
                _ = audioRecorder.takeAccumulatedSamples(ownerID: sessionID)
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
        } onCancel: {
            // Stop capture even if context collection or Speech authorization
            // is still suspended. This execution owns this recorder exclusively.
            audioRecorder.stopRecording(ownerID: sessionID)
        }
    }

    // MARK: - Helpers

    private func cleanup(recorder: AudioRecorder, ownerID: UInt64) {
        recorder.stopRecording(ownerID: ownerID)
        recorder.clearCallbacks(ownerID: ownerID)
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
