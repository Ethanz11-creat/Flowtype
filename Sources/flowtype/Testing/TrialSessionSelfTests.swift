import Foundation
import Combine
import AVFoundation
import os

/// Exercise the real controller with deterministic, cancellation-resistant stage drains.
enum TrialSessionSelfTests {
    private final class Observer: SessionObserver, @unchecked Sendable {
        let observe: @MainActor @Sendable (SessionContext) -> Void
        init(_ observe: @escaping @MainActor @Sendable (SessionContext) -> Void) { self.observe = observe }
        func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
            if newState == .idle { MainActor.assumeIsolated { observe(context) } }
        }
    }

    private struct Stage: PipelineStage {
        let name = "Trial controlled recording"
        let run: @MainActor @Sendable (SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await run(context) }
    }

    @MainActor private final class Barrier {
        var contexts: [SessionContext] = []
        var continuation: CheckedContinuation<Void, Never>?
        func run(_ context: SessionContext) async -> StageResult {
            contexts.append(context)
            context.markReady()
            await withCheckedContinuation { continuation = $0 }
            return .complete
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeTrial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ConfigurationStore(defaults: defaults)
        let resources = SessionResourceCoordinator()
        let first = Barrier(), second = Barrier()
        let quiet = SessionEffects(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in })
        let recovery = RecoveryEffects(openAccessibilitySettings: {}, openMicrophoneSettings: {},
            openSpeechRecognitionSettings: {}, openASRSettings: {}, openHistory: {}, copyText: { _ in })
        let a = SessionController(pipeline: [Stage(run: { await first.run($0) })], observers: [],
            effects: quiet, recoveryEffects: recovery, configurationStore: configuration,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: resources)
        let b = SessionController(pipeline: [Stage(run: { await second.run($0) })], observers: [],
            effects: quiet, recoveryEffects: recovery, configurationStore: configuration,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: resources)
        a.startRecording()
        await wait { first.contexts.count == 1 }
        b.startRecording()
        for _ in 0..<20 { await Task.yield() }
        r.eq(second.contexts.count, 0, "trialCancellationAndCompetingStart: ordinary entry rejects competing recording")
        a.cancel()
        b.startRecording()
        for _ in 0..<20 { await Task.yield() }
        r.eq(second.contexts.count, 0, "trialCancellationAndCompetingStart: cancellation holds resource until stage drains")
        r.check(b.preparationNotice?.contains("收尾") == true, "trial busy state explains resource drain")
        r.check({ if case .notice(let text) = b.sessionState { return text.contains("未开始录音") }; return false }(),
                "trial busy state is visible through ordinary capsule and menu notice")
        r.check(resources.owner != nil, "trial resource remains held despite idle UI")
        first.release()
        await wait { resources.owner == nil }
        b.startRecording()
        await wait { second.contexts.count == 1 }
        r.eq(second.contexts.count, 1, "trial competing controller starts after drain")
        r.eq(first.contexts.first?.sessionID, 1, "trial first controller keeps its own local session sequence")
        a.cancel()
        r.check(resources.owner != nil, "old controller cleanup cannot release newer owner")
        b.cancel(); second.release()
        await wait { resources.owner == nil }
        await trialHasNoLiveEffects(r, configuration)
        await presenterIsolation(r, configuration)
        await lifetime(r, configuration)
        await recordingDrain(r, configuration)
        await resourceReentrancy(r, configuration)
    }
}

extension TrialSessionSelfTests {
    @MainActor private static var quietRecovery: RecoveryEffects {
        .init(openAccessibilitySettings: {}, openMicrophoneSettings: {}, openSpeechRecognitionSettings: {},
              openASRSettings: {}, openHistory: {}, copyText: { _ in })
    }

    @MainActor private static func trialHasNoLiveEffects(_ r: SelfTest.Reporter, _ config: ConfigurationStore) async {
        // nil saveHistory exercises the actual history+learning branch guard, not
        // only a no-op override. The terminal observer probes the unclaimed save gate.
        for ending in ["normal", "uncertain", "cancel-uncertain"] {
            for overrideHistory in [false, true] {
                let resources = SessionResourceCoordinator()
                var prepares = 0, histories = 0
                var context: SessionContext?
                var historyUnclaimed = false
                weak var owner: SessionController?
                let history: (@MainActor @Sendable (SessionContext) -> Void)?
                if overrideHistory { history = { _ in histories += 1 } } else { history = nil }
                let controller = SessionController(pipeline: [Stage(run: { ctx in
                    context = ctx
                    ctx.rawTranscript = "original"; ctx.finalText = "corrected technicalTerm"
                    _ = ctx.beginDeliveryAttempt()
                    _ = ctx.performDeliveryEvent({})
                    if ending == "cancel-uncertain" { owner?.cancel() }
                    else { ctx.finishDelivery(ending == "normal" ? .typedDispatched : .uncertain) }
                    return .complete
                })], observers: [Observer { ctx in historyUnclaimed = ctx.claimHistorySave() }], effects: .init(prepare: { prepares += 1 }, showWindow: {}, hideWindow: {},
                    saveHistory: history),
                recoveryEffects: quietRecovery, configurationStore: config,
                refreshReadiness: { .ready }, readinessLevel: { .ready }, purpose: .trial, resources: resources)
                owner = controller
                controller.startRecording()
                await wait { context != nil && resources.owner == nil }
                let label = "trialHasNoLiveEffects \(ending) override=\(overrideHistory)"
                r.eq(prepares, 0, "\(label): no construction prepare")
                r.eq(histories, 0, "\(label): no formal save callback")
                r.eq(controller.lastDeliverySummary, nil, "\(label): no recent formal delivery")
                r.check(historyUnclaimed || context?.claimHistorySave() == true, "\(label): skips history claim and internal stats/dictionary learning")
                r.check(!controller.errorActions.contains(.viewHistory), "\(label): no invented formal history recovery")
                controller.cancel()
            }
        }
    }

    @MainActor private static func presenterIsolation(_ r: SelfTest.Reporter, _ config: ConfigurationStore) async {
        let resources = SessionResourceCoordinator()
        var callbacks: [@MainActor @Sendable (UInt64, String) -> Void] = []
        var copies: [String] = []
        var contexts: [SessionContext] = []
        let effectsBefore = ValidationEffects.live.snapshot
        let constructedOnly = TrialSessionPresenter(configuration: config, resources: SessionResourceCoordinator(),
            refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { _ in })
        r.eq(constructedOnly.controller.sessionState, .idle, "trial real stage construction stays idle without prepare")
        let presenter = TrialSessionPresenter(configuration: config, resources: resources,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { copies.append($0) },
            makeStages: { callback in
                callbacks.append(callback)
                return [Stage(run: { ctx in contexts.append(ctx); return .continue(.polished("trial result", raw: "raw")) }),
                        DemoInjectionStage(onResult: callback)]
            })
        r.eq(contexts.count, 0, "trial presenter construction never starts capture")
        presenter.copyResult()
        r.eq(copies, [], "trial empty result cannot copy")
        presenter.start()
        await wait { presenter.result != nil && resources.owner == nil }
        r.eq(presenter.result, "trial result", "trial scoped demo delivers result")
        r.eq(copies, [], "trial successful demo never automatically copies")
        r.eq(presenter.controller.lastDeliverySummary, nil, "trial presenter does not publish formal delivery")
        presenter.copyResult()
        r.eq(copies, ["trial result"], "trial explicit copy invokes injected copy once")
        let oldID = contexts.first!.sessionID
        presenter.cancel()
        callbacks[0](oldID, "late after close")
        r.eq(presenter.result, nil, "trial closed presenter ignores late callback")
        presenter.start()
        await wait { contexts.count == 2 && resources.owner == nil }
        callbacks[0](oldID, "late after reopen")
        r.eq(presenter.result, "trial result", "trial reopened generation rejects old session result")
        let other = TrialSessionPresenter(configuration: config, resources: resources,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { copies.append($0) },
            makeStages: { callback in
                [Stage(run: { _ in .continue(.polished("other presenter", raw: "raw")) }), DemoInjectionStage(onResult: callback)]
            })
        other.start()
        await wait { other.result != nil && resources.owner == nil }
        r.eq(other.result, "other presenter", "trial other presenter receives only its scoped callback")
        r.eq(presenter.result, "trial result", "trial same local session ID cannot broadcast into other presenter")
        presenter.cancel(); other.cancel()
        r.eq(ValidationEffects.live.snapshot.blocked, effectsBefore.blocked,
             "trial presenter performs no live window/audio/permission/network/clipboard/observer attempts")
        r.eq(ValidationEffects.live.snapshot.permitted, effectsBefore.permitted,
             "trial presenter permits no live effects")
    }

    @MainActor private static func lifetime(_ r: SelfTest.Reporter, _ config: ConfigurationStore) async {
        let barrier = Barrier(), resources = SessionResourceCoordinator()
        var controller: SessionController? = SessionController(pipeline: [Stage(run: { await barrier.run($0) })],
            observers: [], effects: .init(prepare: {}, showWindow: {}, hideWindow: {}), recoveryEffects: quietRecovery,
            configurationStore: config, refreshReadiness: { .ready }, readinessLevel: { .ready }, purpose: .trial,
            resources: resources)
        weak var weakController = controller
        controller?.startRecording()
        await wait { barrier.contexts.count == 1 }
        controller = nil
        await wait { weakController == nil && barrier.contexts.first?.isCancelled == true }
        r.check(weakController == nil, "trial controller can deinitialize during suspended stage")
        r.check(barrier.contexts.first?.isCancelled == true, "trial deinit invalidates context callbacks")
        r.check(resources.owner != nil, "trial deinit retains lease until stage cleanup exits")
        barrier.release()
        await wait { resources.owner == nil }
        r.eq(resources.owner, nil, "trial deinit stage drain releases lease")
    }

    @MainActor private static func resourceReentrancy(_ r: SelfTest.Reporter, _ config: ConfigurationStore) async {
        let resources = SessionResourceCoordinator(), first = UUID(), second = UUID()
        let old = resources.acquire(owner: first)!
        var next: UUID?
        var armed = false
        let subscription = resources.$owner.sink { owner in
            guard armed, owner == nil, next == nil else { return }
            next = resources.acquire(owner: second)
        }
        armed = true
        resources.release(token: old)
        r.eq(resources.owner, second, "trial coordinator commits nested acquire after release publication")
        resources.release(token: old)
        r.eq(resources.owner, second, "trial old token cannot release newer reservation")
        subscription.cancel()
        if let next { resources.release(token: next) }
        var calls = 0
        let controller = SessionController(pipeline: [Stage(run: { _ in calls += 1; return .complete })],
            observers: [], effects: .init(prepare: {}, showWindow: {}, hideWindow: {}), recoveryEffects: quietRecovery,
            configurationStore: config, refreshReadiness: { .ready }, readinessLevel: { .ready }, purpose: .trial,
            resources: resources)
        var cancelled = false
        let cancelOnAcquire = resources.$owner.sink { owner in
            guard owner != nil, !cancelled else { return }
            cancelled = true
            controller.cancel()
        }
        controller.startRecording()
        for _ in 0..<20 { await Task.yield() }
        r.eq(calls, 0, "trial acquire publication cancellation cannot launch obsolete stage")
        r.eq(resources.owner, nil, "trial cancelled acquire releases exact newly reserved token")
        cancelOnAcquire.cancel()
        controller.startRecording()
        await wait { calls == 1 && resources.owner == nil }
        r.eq(calls, 1, "trial acquisition can restart after reentrant cancellation")
    }
}

extension TrialSessionSelfTests {
    private actor CaptureBarrier {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private final class Capture: RecordingCapture, @unchecked Sendable {
        private struct State {
            var audio: ((AVAudioPCMBuffer) -> Void)?
            var pcm: (@Sendable ([Float]) -> Void)?
            var frozen: (() -> Void)?
            var owner: UInt64?
            var stops = 0
            var clears = 0
        }
        private let state = OSAllocatedUnfairLock(uncheckedState: State())
        let barrier = CaptureBarrier()
        var started: Bool { state.withLock { $0.owner != nil } }
        var stops: Int { state.withLock { $0.stops } }
        var clears: Int { state.withLock { $0.clears } }
        var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
            get { state.withLockUnchecked { $0.audio } }
            set { state.withLockUnchecked { $0.audio = newValue } }
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
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            buffer.frameLength = 1
            onAudioBuffer?(buffer)
            await barrier.wait()
            return RecordingOutput(spectrum: AsyncStream { $0.finish() })
        }
        func stopRecording(ownerID: UInt64) {
            state.withLock { if $0.owner == ownerID { $0.stops += 1 } }
        }
        func owns(_ ownerID: UInt64) -> Bool { state.withLock { $0.owner == ownerID } }
        func clearCallbacks(ownerID: UInt64) {
            state.withLockUnchecked {
                guard $0.owner == ownerID else { return }
                $0.clears += 1; $0.audio = nil; $0.pcm = nil; $0.frozen = nil
            }
        }
        func takeAccumulatedSamples(ownerID: UInt64?) -> [Float] { [] }
    }
    private struct Preview: RecordingPreview {
        func startStreamingRecognition() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
        func stopStreamingRecognition() -> String { "" }
    }
    private struct Foreground: ContextProvider { func collect() async -> ForegroundContext? { nil } }

    @MainActor private static func recordingDrain(_ r: SelfTest.Reporter, _ config: ConfigurationStore) async {
        for stopNormally in [false, true] {
            let resources = SessionResourceCoordinator(), capture = Capture()
            let route = ASRRouteSnapshot(policy: .auto, selectedProviderID: "apple",
                localAvailable: false, cloudAvailable: false, cloudConfiguration: nil)
            let recording = RecordingStage(makeRecorder: { capture }, makePreview: { Preview() },
                captureRoute: { route }, contextProvider: Foreground(), realtimeFactory: { _ in fatalError("Non-realtime fixture cannot create a transport") }, microphoneDeviceID: { nil })
            var ordinaryStarts = 0
            let presenter = TrialSessionPresenter(configuration: config, resources: resources,
                refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { _ in }, makeStages: { callback in
                    [recording, DemoInjectionStage(onResult: callback)]
                })
            let ordinary = SessionController(pipeline: [Stage(run: { _ in ordinaryStarts += 1; return .complete })],
                observers: [], effects: .init(prepare: {}, showWindow: {}, hideWindow: {}), recoveryEffects: quietRecovery,
                configurationStore: config, refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: resources)
            presenter.start()
            await wait { capture.started && presenter.controller.isRecording }
            r.check(capture.started, "trial actual RecordingStage acquired fake recorder")
            if stopNormally { presenter.stop() } else { presenter.cancel() }
            await wait { capture.stops > 0 }
            if !stopNormally { r.check(presenter.isResourceBusy, "trial button reflects pending recorder drain") }
            ordinary.startRecording()
            for _ in 0..<20 { await Task.yield() }
            r.eq(capture.clears, 0, "trial RecordingStage still awaiting actual capture cleanup")
            r.eq(ordinaryStarts, 0, "trial actual RecordingStage drain excludes ordinary entry")
            await capture.barrier.release()
            await wait { capture.clears > 0 && resources.owner == nil }
            r.eq(capture.clears, 1, "trial real RecordingStage clears recorder callbacks before releasing resource")
            ordinary.startRecording()
            await wait { ordinaryStarts == 1 && resources.owner == nil }
            r.eq(ordinaryStarts, 1, "ordinary entry succeeds after real trial recorder cleanup")
            r.eq(presenter.result, nil, "cancelled real recording cannot deliver trial result")
            ordinary.cancel()
            presenter.cancel()
        }
    }
}
