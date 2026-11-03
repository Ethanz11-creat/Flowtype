import Foundation
import AppKit
import AVFoundation
import os

/// Capture and preview boundaries keep the stage's cancellation/ownership logic
/// independent of microphone and Speech framework side effects.
protocol RecordingCapture: AnyObject, Sendable {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onPCMSamples: (@Sendable ([Float]) -> Void)? { get set }
    var onRecordingFrozen: (() -> Void)? { get set }
    func requestPermission() async -> Bool
    func authorizationStatus() -> Int
    func startRecording(deviceID: String?, ownerID: UInt64) async throws -> RecordingOutput
    func stopRecording(ownerID: UInt64)
    func owns(_ ownerID: UInt64) -> Bool
    func clearCallbacks(ownerID: UInt64)
    func takeAccumulatedSamples(ownerID: UInt64?) -> [Float]
}

protocol RecordingPreview: Sendable {
    func startStreamingRecognition() async -> AsyncStream<String>
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer)
    func stopStreamingRecognition() -> String
}

extension AudioRecorder: RecordingCapture {}
extension AppleSpeechProvider: RecordingPreview {}

// MARK: - RecordingStage

/// Pipeline stage that handles microphone capture and real-time AppleSpeech preview.
///
/// Input: `.empty`
/// Output: `.audio(samples: [Float], previewText: String)`
final class RecordingStage: PipelineStage, @unchecked Sendable {

    var name: String { "Recording" }

    private let makeRecorder: @Sendable () -> any RecordingCapture
    private let makePreview: @Sendable () -> any RecordingPreview
    private let captureRoute: @Sendable () async -> ASRRouteSnapshot
    private let contextProvider: any ContextProvider
    private let realtimeFactory: RealtimeSessionFactory
    private let microphoneDeviceID: @Sendable () -> String?

    init(makeRecorder: @escaping @Sendable () -> any RecordingCapture = { AudioRecorder() },
         makePreview: @escaping @Sendable () -> any RecordingPreview = { AppleSpeechProvider() },
         captureRoute: @escaping @Sendable () async -> ASRRouteSnapshot = { await ASRRouter.shared.captureStartRoute() },
         contextProvider: any ContextProvider = AXContextProvider(),
         realtimeFactory: @escaping RealtimeSessionFactory = liveRealtimeSessionFactory,
         microphoneDeviceID: @escaping @Sendable () -> String? = { ConfigurationStore.shared.current.microphoneDeviceID }) {
        self.makeRecorder = makeRecorder
        self.makePreview = makePreview
        self.captureRoute = captureRoute
        self.contextProvider = contextProvider
        self.realtimeFactory = realtimeFactory
        self.microphoneDeviceID = microphoneDeviceID
    }

    func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
        let sessionID = context.sessionID
        // Capture and preview resources belong to this execution alone.
        let audioRecorder = makeRecorder()
        let appleSpeechProvider = makePreview()
        let frozen = OSAllocatedUnfairLock<Bool>(initialState: false)
        let realtimeBox = OSAllocatedUnfairLock<RealtimeASRSessionHandle?>(initialState: nil)
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
                    AppLogger.log("[RecordingStage#\(sessionID)] Mic permission denied (status=\(status))")
                    return .suspend(ErrorRecoveryContext(
                        failedStage: name,
                        error: PermissionError.microphoneDenied,
                        rawText: nil,
                        retryable: false
                    ))
                }

                try Task.checkCancellation()

                let route = await captureRoute()
                let handle = await MainActor.run {
                    context.startForegroundCollection(provider: contextProvider)
                    context.prepareRealtime(route: route, factory: realtimeFactory)
                    return context.realtimeHandle
                }
                realtimeBox.withLock { $0 = handle }
                audioRecorder.onPCMSamples = { samples in
                    context.performIfActive {
                        do { try handle?.ingress.enqueue(samples: samples) }
                        catch { context.markRealtimeFailure(String(describing: error)) }
                    }
                }
                try Task.checkCancellation()

                // 2. Start audio recording
                let deviceID = microphoneDeviceID()
                let output = try await audioRecorder.startRecording(deviceID: deviceID, ownerID: sessionID)
                AppLogger.log("[RecordingStage#\(sessionID)] AudioRecorder started")

                if await MainActor.run(body: { context.isCancelled }) {
                    cleanup(recorder: audioRecorder, ownerID: sessionID)
                    return .complete
                }

                // Detect a mid-recording freeze (device gone) so we can surface an error.
                // 3. Start AppleSpeech real-time preview streaming
                try Task.checkCancellation()
                let previewStream = (try? await withAsyncDeadline(seconds: 3) {
                    let stream = await appleSpeechProvider.startStreamingRecognition()
                    if Task.isCancelled { _ = appleSpeechProvider.stopStreamingRecognition() }
                    return stream
                }) ?? AsyncStream { $0.finish() }
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
                return await finishRecording(recorder: audioRecorder, preview: appleSpeechProvider,
                    context: context, frozen: frozen, realtimeBox: realtimeBox)

            } catch is CancellationError {
                AppLogger.log("[RecordingStage#\(sessionID)] Recording cancelled")
                previewTask?.cancel()
                return await finishRecording(recorder: audioRecorder, preview: appleSpeechProvider,
                    context: context, frozen: frozen, realtimeBox: realtimeBox)
            } catch {
                AppLogger.log("[RecordingStage#\(sessionID)] Recording failed: \(error)")
                previewTask?.cancel()
                let ownsRecorder = audioRecorder.owns(sessionID)
                if ownsRecorder { _ = appleSpeechProvider.stopStreamingRecognition() }
                cleanup(recorder: audioRecorder, ownerID: sessionID)
                _ = audioRecorder.takeAccumulatedSamples(ownerID: sessionID)
                if let handle = realtimeBox.withLock({ $0 }) { await handle.session.cancel() }
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
            realtimeBox.withLock { $0 }?.ingress.seal()
        }
    }

    // MARK: - Helpers

    /// Normal Stop cancels the recording task without cancelling its context.
    /// A freeze already observed by either unwind path must never become audio.
    private func finishRecording(recorder: any RecordingCapture, preview: any RecordingPreview,
        context: SessionContext, frozen: OSAllocatedUnfairLock<Bool>,
        realtimeBox: OSAllocatedUnfairLock<RealtimeASRSessionHandle?>) async -> StageResult {
        let sessionID = context.sessionID
        let ownsRecorder = recorder.owns(sessionID)
        cleanup(recorder: recorder, ownerID: sessionID)
        let rawSamples = recorder.takeAccumulatedSamples(ownerID: sessionID)
        let finalPreviewText = ownsRecorder ? preview.stopStreamingRecognition() : ""
        let realtime = realtimeBox.withLock { $0 }

        if await MainActor.run(body: { context.isCancelled }) {
            await realtime?.session.cancel()
            return .complete
        }
        realtime?.ingress.seal()
        if frozen.withLock({ $0 }) {
            await realtime?.session.cancel()
            AppLogger.log("[RecordingStage#\(sessionID)] Recording interrupted (device froze/disconnected)")
            return .suspend(ErrorRecoveryContext(failedStage: name,
                error: AudioRecorderError.engineStartFailed, rawText: nil, retryable: false))
        }

        let audioDuration = Double(rawSamples.count) / 16000.0
        AppLogger.log("[RecordingStage#\(sessionID)] Raw samples: \(rawSamples.count) (\(String(format: "%.1f", audioDuration))s)")
        return await MainActor.run {
            guard !context.isCancelled else { return .complete }
            context.recordingMs = UInt64(audioDuration * 1000)
            return .continue(.audio(samples: rawSamples, previewText: finalPreviewText))
        }
    }

    private func cleanup(recorder: any RecordingCapture, ownerID: UInt64) {
        recorder.stopRecording(ownerID: ownerID)
        recorder.clearCallbacks(ownerID: ownerID)
    }

}
