import Foundation
import AVFoundation
import os

/// Runs the real RecordingStage and SessionContext. Only microphone, preview,
/// foreground lookup and ASR transport boundaries are synthetic.
enum RecordingStageTerminationSelfTests {
    private final class Capture: RecordingCapture, @unchecked Sendable {
        private struct State {
            var buffer: ((AVAudioPCMBuffer) -> Void)?
            var pcm: (@Sendable ([Float]) -> Void)?
            var frozen: (() -> Void)?
            var owner: UInt64?
            var samples = Array(repeating: Float(0.25), count: 160)
        }
        private let state = OSAllocatedUnfairLock(uncheckedState: State())
        private let spectrum = AsyncStream<[Float]>.makeStream()
        var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
            get { state.withLockUnchecked { $0.buffer } }
            set { state.withLockUnchecked { $0.buffer = newValue } }
        }
        var onPCMSamples: (@Sendable ([Float]) -> Void)? {
            get { state.withLock { $0.pcm } }
            set { state.withLock { $0.pcm = newValue } }
        }
        var onRecordingFrozen: (() -> Void)? {
            get { state.withLockUnchecked { $0.frozen } }
            set { state.withLockUnchecked { $0.frozen = newValue } }
        }
        func requestPermission() async -> Bool { true }
        func authorizationStatus() -> Int { 0 }
        func startRecording(deviceID: String?, ownerID: UInt64) async throws -> RecordingOutput {
            state.withLock { $0.owner = ownerID }
            onPCMSamples?(Array(repeating: 0.25, count: 160))
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            for index in 0..<160 { buffer.floatChannelData![0][index] = 0.25 }
            onAudioBuffer?(buffer)
            return RecordingOutput(spectrum: spectrum.stream)
        }
        func stopRecording(ownerID: UInt64) {
            if owns(ownerID) { spectrum.continuation.finish() }
        }
        func owns(_ ownerID: UInt64) -> Bool { state.withLock { $0.owner == ownerID } }
        func clearCallbacks(ownerID: UInt64) {
            state.withLock {
                guard $0.owner == ownerID else { return }
                $0.buffer = nil; $0.pcm = nil; $0.frozen = nil
            }
        }
        func takeAccumulatedSamples(ownerID: UInt64?) -> [Float] {
            state.withLock {
                guard $0.owner == ownerID else { return [] }
                let samples = $0.samples; $0.samples = []; return samples
            }
        }
        func freeze() {
            // Match AudioRecorder's device heartbeat: frozen callback first,
            // spectrum completion second. Stop can then race the stage unwind.
            onRecordingFrozen?()
            spectrum.continuation.finish()
        }
    }

    private final class Preview: RecordingPreview, @unchecked Sendable {
        private let entered = AsyncStream<Void>.makeStream()
        private let released = AsyncStream<Void>.makeStream()
        func startStreamingRecognition() async -> AsyncStream<String> {
            entered.continuation.yield(())
            entered.continuation.finish()
            var iterator = released.stream.makeAsyncIterator()
            _ = await iterator.next()
            return AsyncStream { $0.finish() }
        }
        func waitUntilEntered() async -> Bool {
            var iterator = entered.stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        func release() { released.continuation.yield(()); released.continuation.finish() }
        func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
        func stopStreamingRecognition() -> String { "synthetic partial preview" }
    }

    private struct Foreground: ContextProvider {
        func collect() async -> ForegroundContext? { nil }
    }
    private actor Realtime: RealtimeASRSession {
        private(set) var cancellations = 0
        func start() async throws {}
        func append(samples: [Float]) async throws {}
        func finish() async throws -> ASRResult { throw DashScopeRealtimeError.notStarted }
        func cancel() async { cancellations += 1 }
    }

    private enum Ending: CaseIterable {
        case healthyStop, fullCancel, frozenEnd, frozenStop
        var frozen: Bool { self != .healthyStop }
        var stopsTask: Bool { self != .frozenEnd }
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        for (index, ending) in Ending.allCases.enumerated() {
            let label = "IR02 \(ending)"
            let capture = Capture(), preview = Preview(), realtime = Realtime()
            let context = SessionContext(sessionID: UInt64(980 + index))
            let route = ASRRouteSnapshot(policy: .auto, selectedProviderID: ASRProviderID.cloud,
                localAvailable: false, cloudAvailable: true,
                cloudConfiguration: .init(provider: .defaultParaformer(isActive: true),
                                          apiKey: "synthetic", sendContext: false))
            let stage = RecordingStage(makeRecorder: { capture }, makePreview: { preview },
                captureRoute: { FixtureASRStage.capture(route) }, contextProvider: Foreground(), realtimeFactory: { _ in
                    .init(session: realtime, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
                }, microphoneDeviceID: { nil })
            let task = Task { await stage.execute(payload: .empty, context: context) }
            let entered = (try? await withAsyncDeadline(seconds: 2) { await preview.waitUntilEntered() }) ?? false
            r.check(entered, "\(label): recording started before termination")
            r.check(context.realtimeHandle != nil, "\(label): real context owns realtime handle")
            // Gate guarantees nonempty capture and an active recorder before Stop.
            // Cancelling here deterministically reaches the real cancellation catch
            // after preview initialization resumes, without sleeps or hardware.
            if ending.frozen { capture.freeze() }
            if ending == .fullCancel { context.cancel() }
            if ending.stopsTask { task.cancel() }
            preview.release()
            let result = await task.value
            switch ending {
            case .healthyStop:
                if case .continue(.audio(let samples, let text)) = result {
                    r.eq(samples.count, 160, "\(label): complete synthetic PCM continues")
                    r.check(samples.allSatisfy { $0 == 0.25 }, "\(label): PCM unchanged")
                    r.eq(text, "synthetic partial preview", "\(label): healthy preview retained")
                } else { r.check(false, "\(label): Stop returns audio") }
                r.eq(context.recordingMs, 10, "\(label): successful duration recorded")
                r.eq(await realtime.cancellations, 0, "\(label): realtime available for ASR")
            case .fullCancel:
                if case .complete = result { r.check(true, "\(label): cancellation wins over freeze") }
                else { r.check(false, "\(label): cancellation wins over freeze") }
                r.check(await realtime.cancellations > 0, "\(label): realtime cancelled")
                r.check(context.recordingMs == nil, "\(label): no successful audio duration")
            case .frozenEnd, .frozenStop:
                if case .suspend(let recovery) = result {
                    r.eq(recovery.failedStage, "Recording", "\(label): fails in recording")
                    r.eq(recovery.failureKind, .recording(.interrupted), "\(label): typed interruption")
                    r.check(recovery.rawText == nil && !recovery.retryable,
                            "\(label): no partial preview/audio recovery retry")
                } else { r.check(false, "\(label): interruption blocks audio and downstream ASR/delivery") }
                r.check(await realtime.cancellations > 0, "\(label): realtime cancelled")
                r.check(context.recordingMs == nil, "\(label): no successful audio duration")
            }
            r.eq(context.isCancelled, ending == .fullCancel, "\(label): normal Stop preserves session ownership")
            context.cancel()
        }
    }
}
