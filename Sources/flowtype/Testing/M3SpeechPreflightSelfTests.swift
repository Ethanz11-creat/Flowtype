import Foundation

enum M3SpeechPreflightSelfTests {
    static func pure(_ r: SelfTest.Reporter) {
        do {
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 80000)),
                 .clearlySilent, "five-second digital silence")
            r.eq(try SpeechPreflight.analyze(samples: []), .emptyCapture, "no captured audio")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 800)),
                 .indeterminate(.tooShort), "50ms never proves silence")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600), sampleRate: 48000),
                 .indeterminate(.unsupportedSampleRate), "wrong rate is not silence")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1599)),
                 .indeterminate(.tooShort), "one sample below 100ms never proves silence")
            r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600)),
                 .clearlySilent, "100ms permits silence")
            r.eq(try SpeechPreflight.analyze(samples: [], sampleRate: 0),
                 .emptyCapture, "empty capture is independent of rate")
            for rate in [0, -16000, 8000, 44100] {
                r.eq(try SpeechPreflight.analyze(samples: Array(repeating: 0, count: 1600), sampleRate: rate),
                     .indeterminate(.unsupportedSampleRate), "unsupported rate \(rate) never proves silence")
            }
            // Constant frames isolate RMS; isolated impulses isolate peak.
            let rms: Float = 0.0003
            for (level, expected): (Float, SpeechPreflightDecision) in [
                (rms.nextDown, .clearlySilent), (rms, .clearlySilent), (rms.nextUp, .possiblySpeech)
            ] {
                r.eq(try SpeechPreflight.analyze(samples: Array(repeating: level, count: 1600)),
                     expected, "Float32 RMS boundary \(level)")
            }
            let peak: Float = 0.001
            for (level, expected): (Float, SpeechPreflightDecision) in [
                (peak.nextDown, .clearlySilent), (peak, .clearlySilent), (peak.nextUp, .possiblySpeech),
                (-peak, .clearlySilent), (-peak.nextUp, .possiblySpeech)
            ] {
                for index in [0, 1599] {
                    var samples = Array(repeating: Float(0), count: 1600)
                    samples[index] = level
                    r.eq(try SpeechPreflight.analyze(samples: samples), expected,
                         "Float32 peak boundary \(level) at \(index)")
                }
            }
            // Every partial-frame length must be scanned and use its own denominator.
            for tail in 1...319 {
                var samples = Array(repeating: Float(0), count: 1600 + tail)
                samples[samples.count - 1] = Float(0.001).nextUp
                r.eq(try SpeechPreflight.analyze(samples: samples), .possiblySpeech,
                     "tail length \(tail) retains final peak")
                samples = Array(repeating: Float(0), count: 1600) + Array(repeating: rms.nextUp, count: tail)
                r.eq(try SpeechPreflight.analyze(samples: samples), .possiblySpeech,
                     "tail length \(tail) retains tail RMS")
            }
            let sine = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 200 / 16000)) * 0.0002 }
            r.eq(try SpeechPreflight.analyze(samples: sine), .clearlySilent,
                 "low-amplitude synthetic sine lies below candidate energy thresholds")
            r.eq(try SpeechPreflight.analyze(samples: sine.map { $0 * 4 }), .possiblySpeech,
                 "synthetic sine above RMS but below peak is retained")
            var delayed = Array(repeating: Float(0), count: 7 * 16000 + 17)
            delayed[6 * 16000 + 1] = 0.01
            r.eq(try SpeechPreflight.analyze(samples: delayed), .possiblySpeech,
                 "signal after six seconds is retained")
            var mixed = Array(repeating: Float(0), count: 16000)
            for i in 320..<640 { mixed[i] = 0.0005 }
            r.eq(try SpeechPreflight.analyze(samples: mixed), .possiblySpeech,
                 "one energetic frame is not diluted by surrounding silence")
            for (level, expected): (Float, SpeechPreflightDecision) in [
                (0.0004, .clearlySilent), (0.0005, .possiblySpeech)
            ] {
                let mixedFrame = Array(repeating: Float(0), count: 160) + Array(repeating: level, count: 160)
                r.eq(try SpeechPreflight.analyze(samples: mixedFrame + Array(repeating: 0, count: 1280)),
                     expected, "mixed frame RMS retains both silent and signal samples at \(level)")
            }
            r.eq(try SpeechPreflight.analyze(samples: [0.5]), .indeterminate(.tooShort),
                 "valid short signal stays indeterminate")
            for invalid: Float in [.nan, .infinity, -.infinity, 1.0001, -1.0001] {
                for index in [0, 319, 1600] {
                    var samples = Array(repeating: Float(0), count: 1601)
                    samples[index] = invalid
                    r.eq(try SpeechPreflight.analyze(samples: samples), .indeterminate(.invalidSamples),
                         "invalid sample at \(index) never proves silence")
                    samples[index == 0 ? 1 : 0] = 0.5
                    r.eq(try SpeechPreflight.analyze(samples: samples), .indeterminate(.invalidSamples),
                         "sound cannot hide invalid sample at \(index)")
                }
                r.eq(try SpeechPreflight.analyze(samples: [invalid]), .indeterminate(.invalidSamples),
                     "short invalid capture is still invalid")
            }
            r.eq(try SpeechPreflight.analyze(samples: [1, -1] + Array(repeating: 0, count: 1598)),
                 .possiblySpeech, "normalized inclusive endpoints are valid")
        } catch {
            r.check(false, "M3 preflight pure: unexpected error \(error)")
        }
    }

    private enum ProbeError: Error { case synthetic }

    /// The analyzer deliberately blocks synchronously. A timeout makes an actor
    /// regression fail instead of hanging the entire self-test process.
    private final class Barrier: @unchecked Sendable {
        struct State {
            var entered = false
            var onMainThread = false
            var forwardedInput = false
            var timedOut = false
            var cancelled = false
            var exited = false
        }
        private let lock = NSLock()
        private var state = State()
        let release = DispatchSemaphore(value: 0)
        var snapshot: State { lock.withLock { state } }

        func analyze(_ samples: [Float], _ rate: Int, cooperative: Bool, throwsError: Bool) throws -> SpeechPreflightDecision {
            lock.withLock {
                state.entered = true
                state.onMainThread = Thread.isMainThread
                state.forwardedInput = samples == [0.25, -0.5] && rate == 12345
            }
            let timedOut = release.wait(timeout: .now() + 2) != .success
            defer {
                lock.withLock {
                    state.timedOut = timedOut
                    state.cancelled = Task.isCancelled
                    state.exited = true
                }
            }
            if cooperative { try Task.checkCancellation() }
            if throwsError { throw ProbeError.synthetic }
            return .possiblySpeech
        }
    }

    @MainActor static func background(_ r: SelfTest.Reporter) async {
        do {
            r.eq(try await SpeechPreflight.evaluate(samples: Array(repeating: 0, count: 1600)),
                 .clearlySilent, "production default analyzer recognizes silence")
            r.eq(try await SpeechPreflight.evaluate(samples: [0.5] + Array(repeating: 0, count: 1599)),
                 .possiblySpeech, "production default analyzer retains raw signal")
            r.eq(try await SpeechPreflight.evaluate(samples: [0.5] + Array(repeating: 0, count: 1600) + [.nan]),
                 .indeterminate(.invalidSamples), "production default analyzer validates tail after sound")
        } catch { r.check(false, "production default analyzer threw \(error)") }

        for mode in ["success", "cancel-return", "cancel-cooperative", "error"] {
            let barrier = Barrier()
            var completed = false
            let task = Task { @MainActor () -> Result<SpeechPreflightDecision, Error> in
                defer { completed = true }
                do {
                    return .success(try await SpeechPreflight.evaluate(samples: [0.25, -0.5], sampleRate: 12345,
                        using: { try barrier.analyze($0, $1, cooperative: mode == "cancel-cooperative", throwsError: mode == "error") }))
                } catch { return .failure(error) }
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while !barrier.snapshot.entered && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            r.check(barrier.snapshot.entered, "\(mode): synchronous analyzer entered")
            r.check(!barrier.snapshot.onMainThread, "\(mode): real evaluate runs analyzer off main thread")
            var heartbeat = false
            await Task { @MainActor in heartbeat = true }.value
            r.check(heartbeat && !barrier.snapshot.exited,
                    "\(mode): MainActor heartbeat runs while synchronous analyzer is blocked")
            let cancelling = mode.hasPrefix("cancel")
            if cancelling {
                task.cancel()
                for _ in 0..<10 { await Task.yield() }
                r.check(!completed, "\(mode): cancellation waits for synchronous worker exit")
            }
            barrier.release.signal()
            let result = await task.value
            let state = barrier.snapshot
            r.check(state.forwardedInput, "\(mode): synchronous seam receives unchanged samples and rate")
            r.check(state.exited && !state.timedOut, "\(mode): worker exits after MainActor releases barrier")
            r.eq(state.cancelled, cancelling, "\(mode): cancellation propagates to detached worker")
            switch result {
            case .success(let decision):
                r.check(!cancelling && mode == "success", "\(mode): cancelled or throwing analyzer cannot publish success")
                r.eq(decision, .possiblySpeech, "\(mode): evaluate preserves analyzer decision")
            case .failure(let error):
                if cancelling { r.check(error is CancellationError, "\(mode): wrapper returns CancellationError") }
                else { r.check(error is ProbeError && mode == "error", "\(mode): wrapper preserves analyzer error") }
            }
        }

        // Exercise production analyze itself, with no analyzer seam. The scan is
        // much longer than the cancellation delay in the debug self-test build.
        let longPCM = Array(repeating: Float(0), count: 180 * 16000)
        let realScan = Task { try await SpeechPreflight.evaluate(samples: longPCM) }
        try? await Task.sleep(for: .milliseconds(2))
        realScan.cancel()
        do {
            _ = try await realScan.value
            r.check(false, "production long-PCM scan must observe cancellation")
        } catch { r.check(error is CancellationError, "production long-PCM scan cooperatively cancels") }

        let cancelledBeforeStart = Task { try await SpeechPreflight.evaluate(samples: []) }
        cancelledBeforeStart.cancel()
        do {
            _ = try await cancelledBeforeStart.value
            r.check(false, "pre-cancelled evaluate cannot return emptyCapture")
        } catch { r.check(error is CancellationError, "pre-cancelled evaluate preserves cancellation") }
    }

    /// Opt-in measurement only: never allocate 30 minutes of PCM in routine suites.
    @MainActor static func benchmark(_ r: SelfTest.Reporter) async {
        let samples = Array(repeating: Float(0), count: 30 * 60 * 16000)
        print("M3 benchmark: synthetic zero PCM, \(samples.count) Float32 samples, 16000 Hz, 30 minutes")
        print("M3 benchmark: logical CPUs=\(ProcessInfo.processInfo.processorCount), physicalMemory=\(ProcessInfo.processInfo.physicalMemory) bytes")
        let clock = ContinuousClock()
        do {
            let analyzeStart = clock.now
            let analyzed = try SpeechPreflight.analyze(samples: samples)
            print("M3 benchmark: production analyze elapsed=\(analyzeStart.duration(to: clock.now)) decision=\(analyzed)")
            r.eq(analyzed, .clearlySilent, "30-minute production analyze result")
            let evaluateStart = clock.now
            let evaluated = try await SpeechPreflight.evaluate(samples: samples)
            print("M3 benchmark: production evaluate elapsed=\(evaluateStart.duration(to: clock.now)) decision=\(evaluated)")
            r.eq(evaluated, .clearlySilent, "30-minute production evaluate result")
        } catch { r.check(false, "30-minute production benchmark threw \(error)") }

        let scanStart = clock.now
        let task = Task { try await SpeechPreflight.evaluate(samples: samples) }
        try? await Task.sleep(for: .milliseconds(2))
        let cancelStart = clock.now
        task.cancel()
        do {
            _ = try await task.value
            r.check(false, "30-minute production scan must cancel")
        } catch {
            print("M3 benchmark: cancellation requested after=\(scanStart.duration(to: cancelStart)); request-to-worker-exit=\(cancelStart.duration(to: clock.now)); result=\(error)")
            r.check(error is CancellationError, "30-minute production cancellation result")
        }
    }
}

extension M3SpeechPreflightSelfTests {
    private final class Ledger: @unchecked Sendable {
        struct State {
            var requests: [ASRRequest] = []
            var routes = 0
            var health = 0
            var factories = 0
            var stages: [String] = []
            var deliveries = 0
            var history = 0
            var preflights = 0
            var preflightOwnedResources = false
            var completedASRAttempts = 0
            var failProvider = false
        }
        private let lock = NSLock()
        private var state = State()
        var snapshot: State { lock.withLock { state } }
        func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    }

    private final class Provider: ASRProvider, @unchecked Sendable {
        let ledger: Ledger
        let id = ASRProviderID.local
        var displayName: String { "synthetic" }
        var isAvailable: Bool { true }
        var capabilities: ASRCapabilities {
            ASRCapabilities(supportsLanguageHint: true, supportsContextHint: true,
                            requiresNetwork: false, location: .onDevice)
        }
        init(_ ledger: Ledger) { self.ledger = ledger }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            ledger.update { $0.requests.append(request) }
            if ledger.snapshot.failProvider { throw ProbeError.synthetic }
            return ASRResult(text: "synthetic hallucination", providerID: id, latencyMs: 1)
        }
    }

    private struct Capture: PipelineStage {
        let name = "Recording"
        let run: @MainActor @Sendable (SessionContext) -> StagePayload
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
            .continue(await run(context))
        }
    }

    private struct ObservedStage: PipelineStage {
        let stage: any PipelineStage
        let ledger: Ledger
        var name: String { stage.name }
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
            ledger.update { $0.stages.append(name) }
            return await stage.execute(payload: payload, context: context)
        }
    }

    private struct ObservedASR: PipelineStage {
        let stage: ASRStage
        let ledger: Ledger
        var name: String { stage.name }
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult {
            let result = await stage.execute(payload: payload, context: context)
            ledger.update { $0.completedASRAttempts += 1 }
            return result
        }
    }

    private static func route(_ policy: ASRRoutingPolicy) -> ASRRouteSnapshot {
        ASRRouteSnapshot(policy: policy, selectedProviderID: policy == .localOnly ? ASRProviderID.local : ASRProviderID.cloud,
                        localAvailable: true, cloudAvailable: true, cloudConfiguration: nil)
    }

    @MainActor private static func waitFor(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private static func tail(_ ledger: Ledger) -> [any PipelineStage] {
        [ObservedStage(stage: PostProcessStage(), ledger: ledger),
         ObservedStage(stage: PolishStage(configuration: { Configuration() }), ledger: ledger),
         ObservedStage(stage: InjectionStage(settle: {}, accessibilityTrusted: { false },
            currentTarget: { DeliveryTargetSnapshot(pid: nil) },
            inject: { _, _ in ledger.update { $0.deliveries += 1 } }, mode: { .automatic },
            bundleID: { _ in nil }, paste: { _, _, _ in ledger.update { $0.deliveries += 1 }; return .dispatched },
            copy: { _ in ledger.update { $0.deliveries += 1 } }), ledger: ledger)]
    }

    @MainActor static func integration(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeM3Silence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ConfigurationStore(defaults: defaults)
        await decisionsAndBudget(r)
        await liveCleanup(r)
        await controllerRacesAndRetry(r, configuration: configuration)
        for policy: ASRRoutingPolicy in [.localOnly, .cloudOnly, .auto] {
            for samples: [Float] in [Array(repeating: 0, count: 80000), []] {
                let label = "M3 ASR \(policy)/\(samples.count)"
                let ledger = Ledger(), providerLedger = Ledger()
                let provider = Provider(providerLedger)
                let saved = route(policy)
                let stage = ASRStage(healthRecorder: { _, _, _ in ledger.update { $0.health += 1 } },
                    providerForID: { _ in provider }, routeFactory: { ledger.update { $0.routes += 1 }; return saved })
                let context = SessionContext(sessionID: 900)
                context.captureRoute = saved
                let result = await stage.execute(payload: .audio(samples: samples, previewText: "Apple preview hallucination"), context: context)
                let expected = samples.isEmpty ? "未录到音频，请重试" : "未检测到声音，请重试"
                if case .notice(let text) = result { r.eq(text, expected, "\(label): precise notice") }
                else { r.check(false, "\(label): real ASR must stop with notice") }
                r.eq(providerLedger.snapshot.requests.count, 0, "\(label): no batch recognition")
                r.eq(ledger.snapshot.health, 0, "\(label): no health writes")
                r.eq(context.rawTranscript, "", "\(label): no accepted transcript or preview")

                let capture = Capture { ctx in ctx.captureRoute = saved; return .audio(samples: samples, previewText: "Apple preview hallucination") }
                let controller = SessionController(pipeline: [capture, stage] + tail(ledger), observers: [],
                    effects: SessionEffects(prepare: {}, showWindow: {}, hideWindow: {},
                        saveHistory: { _ in ledger.update { $0.history += 1 } }),
                    configurationStore: configuration, refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: SessionResourceCoordinator())
                controller.startRecording()
                await waitFor { if case .notice = controller.sessionState { return true }; return controller.sessionState == .idle }
                r.eq(controller.sessionState, .notice(expected), "\(label): controller notice")
                r.eq(ledger.snapshot.stages, [], "\(label): no PostProcess/Polish/Injection")
                r.eq(ledger.snapshot.deliveries, 0, "\(label): no keyboard or clipboard mutation")
                r.eq(ledger.snapshot.history, 0, "\(label): no transcription history")
                r.eq(controller.lastDeliverySummary, nil, "\(label): no new delivery summary")
                controller.cancel()
                r.eq(controller.sessionState, .idle, "\(label): notice can cleanly cancel to idle")

                let direct = SessionContext(sessionID: 901)
                _ = await stage.execute(payload: .audio(samples: samples, previewText: "preview"), context: direct)
                r.eq(ledger.snapshot.routes, 0, "\(label): silence without saved route cannot construct route")
            }
        }
    }
}

extension M3SpeechPreflightSelfTests {
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    private actor Live: RealtimeASRSession {
        var starts = 0, finishes = 0, cancels = 0
        var chunks: [[Float]] = []
        let fail: Bool
        init(fail: Bool = false) { self.fail = fail }
        func start() async throws { starts += 1 }
        func append(samples: [Float]) async throws { chunks.append(samples) }
        func finish() async throws -> ASRResult {
            finishes += 1
            // The retry fixture models a typed transient service failure. Unknown
            // probe errors intentionally cannot authorize original-audio retry.
            if fail { throw CloudASRError.timeout }
            return ASRResult(text: "live temporary text", providerID: ASRProviderID.cloud, latencyMs: 1)
        }
        func cancel() async { cancels += 1 }
    }

    private static func liveRoute() -> ASRRouteSnapshot {
        ASRRouteSnapshot(policy: .cloudOnly, selectedProviderID: ASRProviderID.cloud,
            localAvailable: false, cloudAvailable: true,
            cloudConfiguration: CloudASRRequestConfiguration(provider: .defaultParaformer(isActive: true),
                                                           apiKey: "synthetic", sendContext: false))
    }

    @MainActor private static func decisionsAndBudget(_ r: SelfTest.Reporter) async {
        let original: [Float] = [0.2, -0.1] + Array(repeating: 0, count: 80000) + [0.3]
        for mode in ["short", "unavailable", "error", "speech", "invalid", "rate", "cancel-error", "cancel-return"] {
            let ledger = Ledger(), provider = Provider(Ledger())
            let context = SessionContext(sessionID: 910)
            context.captureRoute = route(.localOnly)
            let stage = ASRStage(healthRecorder: { _, _, _ in ledger.update { $0.health += 1 } },
                providerForID: { _ in provider }, routeFactory: { ledger.update { $0.routes += 1 }; return route(.auto) },
                speechPreflight: { samples, rate in
                    ledger.update { $0.preflights += 1 }
                    ledger.update { $0.preflightOwnedResources = samples == original && rate == 16000 }
                    if mode == "error" { throw ProbeError.synthetic }
                    if mode == "cancel-error" { throw CancellationError() }
                    if mode == "cancel-return" { await context.cancel(); return .possiblySpeech }
                    return mode == "short" ? .indeterminate(.tooShort) : mode == "unavailable" ? .indeterminate(.detectorUnavailable) :
                        mode == "invalid" ? .indeterminate(.invalidSamples) : mode == "rate" ? .indeterminate(.unsupportedSampleRate) : .possiblySpeech
                })
            let result = await stage.execute(payload: .audio(samples: original, previewText: "untrusted preview"), context: context)
            r.eq(ledger.snapshot.preflights, 1, "M3 \(mode): direct stage always runs preflight")
            r.check(ledger.snapshot.preflightOwnedResources, "M3 \(mode): preflight receives original PCM at 16kHz")
            r.eq(ledger.snapshot.routes, 0, "M3 \(mode): saved route retained")
            if ["short", "unavailable", "error", "speech"].contains(mode) {
                r.eq(provider.ledger.snapshot.requests.first?.samples, original, "M3 \(mode): original sample order/count retained")
                if case .continue(.transcript(let text)) = result { r.eq(text, "synthetic hallucination", "M3 \(mode): provider remains authoritative") }
                else { r.check(false, "M3 \(mode): continues original candidate") }
            } else {
                r.eq(provider.ledger.snapshot.requests.count, 0, "M3 \(mode): no provider")
                r.eq(ledger.snapshot.health, 0, "M3 \(mode): no provider-health penalty")
                r.eq(context.rawTranscript, "", "M3 \(mode): no preview promotion")
                if case .suspend(let recovery) = result {
                    r.check(!recovery.retryable, "M3 \(mode): non-retryable")
                    if mode.hasPrefix("cancel") { r.check(recovery.error is CancellationError, "M3 \(mode): cancellation wins") }
                    else {
                        if case ASRStageError.invalidAudio = recovery.error { r.check(true, "M3 \(mode): invalid audio type") }
                        else { r.check(false, "M3 \(mode): invalid audio type") }
                        r.eq(recovery.error.localizedDescription, "录音数据异常，请重新录音", "M3 \(mode): data error copy")
                    }
                } else { r.check(false, "M3 \(mode): suspends, never preview") }
            }
        }
        // Production analyzer, not a forced decision: every edge signal reaches the original chain.
        for samples in [[Float(0.5)], [0.5] + Array(repeating: Float(0), count: 80000),
                        Array(repeating: Float(0), count: 80000) + [0.5],
                        Array(repeating: Float(0), count: 7 * 16000) + [0.5, -0.25]] {
            let cloudLedger = Ledger(), localLedger = Ledger()
            cloudLedger.update { $0.failProvider = true }
            let cloud = Provider(cloudLedger), local = Provider(localLedger)
            let context = SessionContext(sessionID: 911); context.captureRoute = route(.auto)
            let stage = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { $0 == ASRProviderID.cloud ? cloud : local })
            _ = await stage.execute(payload: .audio(samples: samples, previewText: "partial"), context: context)
            r.eq(cloudLedger.snapshot.requests.first?.samples, samples, "M3 signal \(samples.count): first candidate receives full recording")
            r.eq(localLedger.snapshot.requests.first?.samples, samples, "M3 signal \(samples.count): fallback receives full recording")
            r.check(context.usedFallback, "M3 signal \(samples.count): original fallback chain works")
        }
        for bad: Float in [.nan, .infinity, -.infinity, 1.01, -1.01] {
            let ledger = Ledger(), provider = Provider(Ledger())
            let context = SessionContext(sessionID: 912)
            let stage = ASRStage(healthRecorder: { _, _, _ in ledger.update { $0.health += 1 } },
                providerForID: { _ in provider }, routeFactory: { ledger.update { $0.routes += 1 }; return route(.localOnly) })
            let result = await stage.execute(payload: .audio(samples: [0.5, bad], previewText: "preview"), context: context)
            if case .suspend(let recovery) = result {
                r.eq(recovery.error.localizedDescription, "录音数据异常，请重新录音", "M3 real malformed PCM is data error")
                r.check(!recovery.retryable, "M3 real malformed PCM cannot retry unchanged")
            } else { r.check(false, "M3 real malformed PCM stops") }
            r.eq(provider.ledger.snapshot.requests.count + ledger.snapshot.routes + ledger.snapshot.health, 0,
                 "M3 real malformed PCM has no routing/provider/health effects")
        }
        for mode in ["existing", "new", "expired"] {
            let context = SessionContext(sessionID: 913)
            if mode != "new" { context.completionBudget = CompletionBudget(seconds: mode == "expired" ? 0.01 : 1) }
            let before = context.completionBudget
            let observed = BudgetBox()
            let ledger = Ledger(), provider = Provider(Ledger())
            let stage = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in provider },
                routeFactory: { ledger.update { $0.routes += 1 }; return route(.localOnly) },
                speechPreflight: { _, _ in
                    await MainActor.run { observed.value = context.completionBudget; observed.remaining = context.completionBudget?.remainingSeconds }
                    try await Task.sleep(for: .milliseconds(30))
                    return .possiblySpeech
                })
            let result = await stage.execute(payload: .audio(samples: original, previewText: "preview"), context: context)
            r.check(observed.value != nil, "M3 budget \(mode): budget exists before preflight await")
            r.eq(context.completionBudget, observed.value, "M3 budget \(mode): same monotonic budget identity after preflight")
            if let before { r.eq(context.completionBudget, before, "M3 budget \(mode): existing deadline unchanged") }
            r.check((context.completionBudget?.remainingSeconds ?? 0) < (observed.remaining ?? 0), "M3 budget \(mode): preflight time consumed")
            if mode == "expired" {
                r.eq(ledger.snapshot.routes + provider.ledger.snapshot.requests.count, 0, "M3 expired: no route or provider after preflight")
                if case .suspend(let recovery) = result { r.check(recovery.retryable, "M3 expired: explicit retry allowed") }
                else { r.check(false, "M3 expired: preview cannot escape deadline") }
            } else {
                let timeout = provider.ledger.snapshot.requests.first?.timeout ?? 0
                r.check(timeout > 0 && timeout < (mode == "new" ? 20 : 1), "M3 budget \(mode): provider inherits reduced timeout")
            }
        }
    }

    @MainActor private final class BudgetBox {
        var value: CompletionBudget?
        var remaining: Double?
    }

    @MainActor private static func liveCleanup(_ r: SelfTest.Reporter) async {
        for empty in [false, true] {
            let context = SessionContext(sessionID: 920)
            let live = Live(), ledger = Ledger()
            let handle = RealtimeASRSessionHandle(session: live, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
            context.prepareRealtime(route: liveRoute(), factory: { _ in handle })
            let start = context.realtimeStartTask!
            try? await start.value
            // Prior start/upload/temporary text are allowed; stop must never finalize them.
            try? handle.ingress.enqueue(samples: [0])
            context.currentPreviewText = "existing live/Apple text"
            let stage = ASRStage(healthRecorder: { _, _, _ in ledger.update { $0.health += 1 } }, providerForID: { _ in nil },
                realtimeFactory: { _ in ledger.update { $0.factories += 1 }; return handle },
                routeFactory: { ledger.update { $0.routes += 1 }; return liveRoute() })
            _ = await stage.execute(payload: .audio(samples: empty ? [] : Array(repeating: 0, count: 80000), previewText: context.currentPreviewText), context: context)
            for _ in 0..<100 { if await live.cancels > 0 { break }; await Task.yield() }
            r.eq(await live.cancels, 1, "M3 live: session cancelled once")
            r.eq(await live.finishes, 0, "M3 live: existing text cannot trigger finish")
            r.check(start.isCancelled, "M3 live: start task cancelled")
            r.check(context.realtimeHandle == nil && context.realtimeStartTask == nil, "M3 live: handle consumed before terminal notice")
            do { try handle.ingress.enqueue(samples: [0]); r.check(false, "M3 live: ingress cancelled") }
            catch { r.eq(error as? RealtimeAudioIngressError, .cancelled, "M3 live: ingress specifically cancelled, not just sealed") }
            r.eq(handle.ingress.pendingSampleCount, 0, "M3 live: cancellation releases queued audio")
            context.cancel()
            for _ in 0..<10 { await Task.yield() }
            r.eq(await live.cancels, 1, "M3 live: controller cleanup cannot cancel consumed handle twice")
            r.eq(ledger.snapshot.factories + ledger.snapshot.routes + ledger.snapshot.health, 0, "M3 live: no new factory/route/health")
            r.eq(context.rawTranscript, "", "M3 live: no transcript")
        }
        // Returning or throwing from a suspended detector must find cleanup already installed.
        for throwsCancellation in [false, true] {
            let context = SessionContext(sessionID: 921), live = Live(), ledger = Ledger()
            let handle = RealtimeASRSessionHandle(session: live, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
            context.prepareRealtime(route: liveRoute(), factory: { _ in handle })
            let start = context.realtimeStartTask!
            let stage = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in nil },
                speechPreflight: { _, _ in
                    let owned = await MainActor.run {
                        context.realtimeHandle == nil && context.realtimeStartTask == nil && context.completionBudget != nil
                    }
                    ledger.update { $0.preflightOwnedResources = owned }
                    if throwsCancellation { throw CancellationError() }
                    return .clearlySilent
                })
            let result = await stage.execute(payload: .audio(samples: [0], previewText: "preview"), context: context)
            r.check(ledger.snapshot.preflightOwnedResources, "M3 live: handle taken and budget established before detector")
            for _ in 0..<100 { if await live.cancels > 0 { break }; await Task.yield() }
            r.eq(await live.cancels, 1, "M3 live: early detector exit invokes installed cleanup once")
            r.eq(await live.finishes, 0, "M3 live: early detector exit cannot finalize")
            r.check(start.isCancelled, "M3 live: early detector exit cancels start task")
            if throwsCancellation {
                if case .suspend(let recovery) = result { r.check(recovery.error is CancellationError, "M3 live: detector cancellation stays cancellation") }
                else { r.check(false, "M3 live: detector cancellation stays cancellation") }
            }
        }
    }
}

extension M3SpeechPreflightSelfTests {
    @MainActor private final class CapturePlan {
        var samples: [Float] = [0.4]
        var preview = ""
        var contexts: [SessionContext] = []
        var budgets: [CompletionBudget] = []
    }

    @MainActor private static func controllerRacesAndRetry(_ r: SelfTest.Reporter, configuration: ConfigurationStore) async {
        for late: SpeechPreflightDecision in [.clearlySilent, .possiblySpeech] {
            let ledger = Ledger(), provider = Provider(Ledger()), plan = CapturePlan(), gate = Gate()
            let stage = ASRStage(healthRecorder: { _, _, _ in ledger.update { $0.health += 1 } }, providerForID: { _ in provider },
                speechPreflight: { samples, rate in
                    if samples.first == 0.123 {
                        ledger.update { $0.preflights += 1 }
                        await gate.wait() // Deliberately uncooperative old compute completion.
                        return late
                    }
                    return try await SpeechPreflight.evaluate(samples: samples, sampleRate: rate)
                })
            let capture = Capture { ctx in
                plan.contexts.append(ctx)
                ctx.captureRoute = route(.localOnly)
                return .audio(samples: plan.samples, previewText: plan.preview)
            }
            let controller = SessionController(pipeline: [capture, ObservedASR(stage: stage, ledger: ledger)] + tail(ledger), observers: [],
                effects: SessionEffects(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in ledger.update { $0.history += 1 } }),
                configurationStore: configuration, refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: SessionResourceCoordinator())
            defer { controller.cancel() }
            controller.startRecording()
            await waitFor { ledger.snapshot.history == 1 }
            let previous = controller.lastDeliverySummary
            r.check(previous != nil, "M3 controller: actual successful pipeline establishes prior summary")
            controller.cancel()
            plan.samples = Array(repeating: 0, count: 80000); plan.preview = "Apple hallucination"
            controller.startRecording()
            await waitFor { controller.sessionState == .notice("未检测到声音，请重试") }
            r.eq(controller.sessionState, .notice("未检测到声音，请重试"), "M3 controller: actual silence notice")
            r.eq(controller.lastDeliverySummary, previous, "M3 controller: silence preserves previous delivery summary")
            r.eq(ledger.snapshot.history, 1, "M3 controller: silence adds no history")
            r.eq(ledger.snapshot.stages.count, 3, "M3 controller: silence reaches no downstream stages")
            r.eq(ledger.snapshot.deliveries, 1, "M3 controller: silence adds no delivery")
            controller.cancel()
            let beforeInvalid = provider.ledger.snapshot.requests.count
            let healthBeforeInvalid = ledger.snapshot.health
            plan.samples = [0.5, .nan]
            controller.startRecording()
            await waitFor {
                controller.sessionState == .notice("录音数据异常，请重新录音") ||
                    controller.sessionState == .error("录音数据异常，请重新录音")
            }
            r.eq(controller.sessionState, .error("录音数据异常，请重新录音"), "M3 invalid controller: malformed audio remains actionable for rerecord")
            r.eq(controller.errorActions, [.rerecord, .dismiss], "M3 invalid controller: rerecord only, no Retry or copy-preview action")
            r.eq(provider.ledger.snapshot.requests.count, beforeInvalid, "M3 invalid controller: no provider")
            r.eq(ledger.snapshot.health, healthBeforeInvalid, "M3 invalid controller: no health penalty")
            r.eq(ledger.snapshot.history, 1, "M3 invalid controller: no history")
            r.eq(ledger.snapshot.deliveries, 1, "M3 invalid controller: no delivery")
            r.eq(ledger.snapshot.stages.count, 3, "M3 invalid controller: no downstream processing")
            r.eq(controller.lastDeliverySummary, previous, "M3 invalid controller: previous summary retained")
            controller.retryFailedStage()
            r.eq(provider.ledger.snapshot.requests.count, beforeInvalid, "M3 invalid controller: explicit Retry cannot send malformed PCM")
            controller.cancel()
            plan.samples = [0.123]
            controller.startRecording()
            await waitFor { ledger.snapshot.preflights == 1 }
            let obsolete = plan.contexts.last!
            controller.cancel()
            r.check(obsolete.isCancelled, "M3 late: old context invalidated")
            plan.samples = [0.6]; plan.preview = ""
            controller.startRecording()
            await waitFor { ledger.snapshot.history == 2 }
            let newer = controller.lastDeliverySummary
            let state = controller.sessionState
            let health = ledger.snapshot.health
            let calls = provider.ledger.snapshot.requests.count
            let completed = ledger.snapshot.completedASRAttempts
            await gate.release()
            await waitFor { ledger.snapshot.completedASRAttempts == completed + 1 }
            r.eq(ledger.snapshot.completedASRAttempts, completed + 1, "M3 late \(late): obsolete ASR actually returned before assertions")
            r.eq(controller.lastDeliverySummary, newer, "M3 late \(late): cannot overwrite new summary")
            r.eq(controller.sessionState, state, "M3 late \(late): cannot overwrite new UI")
            r.eq(ledger.snapshot.history, 2, "M3 late \(late): no old history")
            r.eq(ledger.snapshot.deliveries, 2, "M3 late \(late): no old delivery")
            r.eq(ledger.snapshot.health, health, "M3 late \(late): no old health")
            r.eq(provider.ledger.snapshot.requests.count, calls, "M3 late \(late): no old provider")
            r.eq(obsolete.rawTranscript, "", "M3 late \(late): no old transcript")
        }

        let ledger = Ledger(), plan = CapturePlan(), failedLive = Live(fail: true), freshLive = Live()
        let oldHandle = RealtimeASRSessionHandle(session: failedLive, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
        let newHandle = RealtimeASRSessionHandle(session: freshLive, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
        let stage = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in nil },
            realtimeFactory: { _ in ledger.update { $0.factories += 1 }; return newHandle },
            speechPreflight: { samples, rate in
                ledger.update { $0.preflights += 1 }
                await MainActor.run { if let budget = plan.contexts.last?.completionBudget { plan.budgets.append(budget) } }
                return try await SpeechPreflight.evaluate(samples: samples, sampleRate: rate)
            }, phrases: { [] })
        let capture = Capture { ctx in
            plan.contexts.append(ctx)
            ctx.completionBudget = CompletionBudget(seconds: 1)
            ctx.prepareRealtime(route: liveRoute(), factory: { _ in oldHandle })
            return .audio(samples: [0.5, -0.5], previewText: "")
        }
        let controller = SessionController(pipeline: [capture, stage] + tail(ledger), observers: [],
            effects: SessionEffects(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in ledger.update { $0.history += 1 } }),
            configurationStore: configuration, refreshReadiness: { .ready }, readinessLevel: { .ready }, resources: SessionResourceCoordinator())
        defer { controller.cancel() }
        controller.startRecording()
        await waitFor { if case .error = controller.sessionState { return true }; return false }
        r.eq(ledger.snapshot.preflights, 1, "M3 retry: first real ASR attempt preflight")
        r.check(plan.contexts.first?.realtimeHandle == nil, "M3 retry: failed live handle consumed")
        r.eq(controller.recoveryCard?.presentation.kind, .transientASR, "M3 retry: typed transient failure authorizes retained audio")
        controller.retryFailedStage()
        await waitFor { ledger.snapshot.history == 1 }
        r.eq(ledger.snapshot.preflights, 2, "M3 retry: explicit Retry reruns real preflight")
        r.eq(plan.contexts.count, 1, "M3 retry: Retry skips capture and reuses saved complete payload")
        r.eq(ledger.snapshot.factories, 1, "M3 retry: fresh saved realtime handle")
        r.eq(await failedLive.finishes, 1, "M3 retry: terminated live is never reused")
        r.eq(await freshLive.finishes, 1, "M3 retry: new handle finalizes once")
        r.eq(await freshLive.chunks.flatMap { $0 }, [0.5, -0.5], "M3 retry: saved payload preserved sample-for-sample")
        r.eq(ledger.snapshot.history, 1, "M3 retry: only successful retry writes history")
        r.check(plan.budgets.count == 2 && plan.budgets[0] != plan.budgets[1], "M3 retry: explicit retry retains fresh-budget rule")
        r.check((plan.budgets.last?.remainingSeconds ?? 0) > 18, "M3 retry: explicit retry receives new twenty-second budget")
    }
}
