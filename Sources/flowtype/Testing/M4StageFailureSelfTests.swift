import Foundation
import os

/// Real stages with synthetic PCM and in-process provider/system boundaries only.
enum M4StageFailureSelfTests {
    private final class Provider: ASRProvider, @unchecked Sendable {
        let id: String
        let failure: Error?
        let delay: Duration
        let requests = OSAllocatedUnfairLock<[ASRRequest]>(initialState: [])
        var displayName: String { "synthetic" }
        var isAvailable: Bool { true }
        var capabilities: ASRCapabilities {
            .init(supportsLanguageHint: true, supportsContextHint: true, requiresNetwork: false, location: .onDevice)
        }
        init(_ id: String, _ failure: Error? = nil, delay: Duration = .zero) {
            self.id = id; self.failure = failure; self.delay = delay
        }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            requests.withLock { $0.append(request) }
            if delay > .zero { try await Task.sleep(for: delay) }
            if let failure { throw failure }
            return .init(text: "synthetic complete", providerID: id, latencyMs: 1)
        }
        var count: Int { requests.withLock { $0.count } }
    }

    private actor Realtime: RealtimeASRSession {
        let failure: Error
        init(_ failure: Error) { self.failure = failure }
        func start() async throws {}
        func append(samples: [Float]) async throws {}
        func finish() async throws -> ASRResult { throw failure }
        func cancel() async {}
    }

    private static func makeASR(
        healthRecorder: @escaping @MainActor @Sendable (String, Int?, ASRRouteSnapshot) -> Void,
        providerForID: @escaping @Sendable (String) -> (any ASRProvider)?,
        realtimeFactory: @escaping RealtimeSessionFactory = { _ in fatalError("unexpected realtime factory") }
    ) -> FixtureASRStage {
        FixtureASRStage(healthRecorder: healthRecorder, providerForID: providerForID,
                 realtimeFactory: realtimeFactory, phrases: { [] })
    }

    private static let samples: [Float] = [0.5, -0.25]
    private static let credentials = CloudASRError.apiError(statusCode: 401, message: "synthetic private body")

    private static func route(first: String? = ASRProviderID.cloud, local: Bool = false,
                              cloud: Bool = true, realtime: Bool = false) -> ASRRouteSnapshot {
        let configuration = realtime ? CloudASRRequestConfiguration(
            provider: .defaultParaformer(isActive: true), apiKey: "synthetic", sendContext: false) : nil
        return .init(policy: .auto, selectedProviderID: first, localAvailable: local,
                     cloudAvailable: cloud, cloudConfiguration: configuration)
    }

    @MainActor private static func assertFailure(_ result: StageResult, _ expected: FailureKind,
                                                 _ r: SelfTest.Reporter, _ label: String) {
        guard case .suspend(let recovery) = result else {
            r.check(false, "M4 stage \(label): terminal suspension"); return
        }
        r.eq(recovery.failureKind, expected, "M4 stage \(label): original typed cause")
        let presentation = RecoveryPolicy.presentation(kind: recovery.failureKind, resources: .init(
            stage: recovery.failedStage, hasAudio: true, textKind: recovery.textKind,
            deliveryEventStarted: false, routingPolicy: .auto, hasHistory: false))
        r.eq(presentation.actions.contains(.retry(stage: "ASR")), expected == .transientASR,
             "M4 stage \(label): retry only transient original audio")
        r.check(!presentation.message.contains("private body"), "M4 stage \(label): safe presentation")
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        for realtime in [false, true] {
            for (error, kind): (Error, FailureKind) in [(credentials, .configuration(.credentials)),
                (URLError(.timedOut), .transientASR), (NSError(domain: "synthetic", code: 1), .internalFailure)] {
                let provider = Provider(ASRProviderID.cloud, error)
                let live = Realtime(error)
                let context = SessionContext(sessionID: 940)
                context.captureRoute = route(realtime: realtime)
                let health = OSAllocatedUnfairLock<Int>(initialState: 0)
                let stage = makeASR(healthRecorder: { _, _, _ in health.withLock { $0 += 1 } },
                    providerForID: { _ in provider }, realtimeFactory: { _ in .init(session: live,
                        ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities) })
                assertFailure(await stage.execute(payload: .audio(samples: samples, previewText: ""), context: context),
                              kind, r, "\(realtime ? "realtime" : "batch") \(kind)")
                r.eq(health.withLock { $0 }, 1, "M4 terminal failure records health exactly once")
            }
        }
        for credentialsFirst in [true, false] {
            let cloud = Provider(ASRProviderID.cloud, credentialsFirst ? credentials : URLError(.timedOut))
            let local = Provider(ASRProviderID.local, credentialsFirst ? URLError(.timedOut) : credentials)
            let context = SessionContext(sessionID: 941); context.captureRoute = route(local: true)
            let stage = makeASR(healthRecorder: { _, _, _ in }, providerForID: { $0 == ASRProviderID.cloud ? cloud : local })
            assertFailure(await stage.execute(payload: .audio(samples: samples, previewText: ""), context: context),
                          credentialsFirst ? .configuration(.credentials) : .transientASR, r, "mixed first cause")
            r.eq(cloud.count + local.count, 2, "M4 mixed attempts each candidate once")
        }
        // A known first cause survives expiry before the next candidate begins.
        let cloud = Provider(ASRProviderID.cloud, credentials), local = Provider(ASRProviderID.local)
        let expired = SessionContext(sessionID: 942); expired.captureRoute = route(local: true)
        expired.completionBudget = CompletionBudget(seconds: 1)
        let budgetStage = makeASR(healthRecorder: { _, _, _ in
            Thread.sleep(forTimeInterval: 1.02)
        }, providerForID: { $0 == ASRProviderID.cloud ? cloud : local })
        assertFailure(await budgetStage.execute(payload: .audio(samples: samples, previewText: "preview"), context: expired),
                      .configuration(.credentials), r, "known credentials before budget expiry")
        r.eq(local.count, 0, "M4 expired budget prevents later provider")

        let fallbackContext = SessionContext(sessionID: 943); fallbackContext.captureRoute = route(local: true)
        let fallbackStage = makeASR(healthRecorder: { _, _, _ in }, providerForID: { $0 == ASRProviderID.cloud ? cloud : local })
        if case .continue(.transcript(let text)) = await fallbackStage.execute(payload: .audio(samples: samples, previewText: ""), context: fallbackContext) {
            r.eq(text, "synthetic complete", "M4 successful fallback stays successful")
            r.check(fallbackContext.usedFallback, "M4 successful fallback records route health context")
        } else { r.check(false, "M4 successful fallback stays successful") }

        for routeValue in [route(first: nil, cloud: false), route()] {
            let context = SessionContext(sessionID: 944); context.captureRoute = routeValue
            if !FixtureASRStage.capture(routeValue).candidateIDs.isEmpty { context.completionBudget = CompletionBudget(seconds: 0) }
            let stage = makeASR(healthRecorder: { _, _, _ in r.check(false, "M4 empty/budget must not record health") },
                                 providerForID: { _ in nil })
            assertFailure(await stage.execute(payload: .audio(samples: samples, previewText: ""), context: context),
                FixtureASRStage.capture(routeValue).candidateIDs.isEmpty ? .readiness(.noEngine) : .transientASR, r, "no candidates or initial budget")
        }
        startup(r)
        await RecordingStageTerminationSelfTests.run(r)
        await deadline(r)
        await cancellations(r)
        await localAndPreview(r)
        await boundaries(r)
        await typingCancellation(r)
    }

    @MainActor private static func startup(_ r: SelfTest.Reporter) {
        for domain in ["com.apple.coreaudio.avfaudio", "synthetic.other.domain"] {
            var events: [String] = []
            var interrupted = false
            var completedAsEmpty = false
            RecordingEngineStartup.run(prepare: { events.append("prepare") }, start: {
                events.append("start")
                throw NSError(domain: domain, code: 1)
            }, onFailure: {
                interrupted = true
                events.append("failure")
            }, finish: {
                // This is the narrow observable guarantee used by RecordingStage:
                // spectrum completion sees frozen=true, including non-CoreAudio errors.
                completedAsEmpty = !interrupted
                events.append("finish")
            })
            r.eq(events, ["prepare", "start", "failure", "finish"], "M4 startup failure exact order/count")
            r.check(!completedAsEmpty, "M4 startup failure cannot present a normal empty completion")
            r.eq(FailureClassifier.classify(AudioRecorderError.engineStartFailed), .recording(.interrupted),
                 "M4 existing frozen error retains interruption")
        }
        var events: [String] = []
        RecordingEngineStartup.run(prepare: { events.append("prepare") }, start: { events.append("start") },
            onFailure: { events.append("failure") }, finish: { events.append("finish") })
        r.eq(events, ["prepare", "start"], "M4 successful startup leaves spectrum open")
    }

    @MainActor private static func deadline(_ r: SelfTest.Reporter) async {
        let provider = Provider(ASRProviderID.cloud, delay: .seconds(2))
        let context = SessionContext(sessionID: 951); context.captureRoute = route()
        context.completionBudget = CompletionBudget(seconds: 0.2)
        let stage = makeASR(healthRecorder: { _, _, _ in }, providerForID: { _ in provider })
        assertFailure(await stage.execute(payload: .audio(samples: samples, previewText: "preview"), context: context),
                      .transientASR, r, "actual ASR deadline timeout")
        r.eq(provider.count, 1, "M4 real deadline calls provider only once")
    }

    @MainActor private static func cancellations(_ r: SelfTest.Reporter) async {
        let preflightProvider = Provider(ASRProviderID.cloud)
        let preflightHealth = OSAllocatedUnfairLock<Int>(initialState: 0)
        let preflightStage = FixtureASRStage(healthRecorder: { _, _, _ in preflightHealth.withLock { $0 += 1 } },
            providerForID: { _ in preflightProvider }, speechPreflight: { _, _ in
                throw CloudASRError.networkError(SpeechProviderError.networkError(URLError(.cancelled)))
            }, phrases: { [] })
        let preflightContext = SessionContext(sessionID: 952); preflightContext.captureRoute = route(local: true)
        assertFailure(await preflightStage.execute(payload: .audio(samples: samples, previewText: "preview"), context: preflightContext),
                      .cancelled, r, "wrapped preflight cancellation")
        r.eq(preflightProvider.count + preflightHealth.withLock { $0 }, 0, "M4 cancelled preflight no provider/health")
        let errors: [Error] = [CancellationError(), CloudASRError.cancelled, URLError(.cancelled),
            RealtimeAudioIngressError.cancelled, CloudASRError.networkError(SpeechProviderError.networkError(URLError(.cancelled)))]
        for realtime in [false, true] {
            for error in errors {
                let cloud = Provider(ASRProviderID.cloud, error), local = Provider(ASRProviderID.local)
                let health = OSAllocatedUnfairLock<Int>(initialState: 0), live = Realtime(error)
                let context = SessionContext(sessionID: 945); context.captureRoute = route(local: true, realtime: realtime)
                let stage = makeASR(healthRecorder: { _, _, _ in health.withLock { $0 += 1 } },
                                     providerForID: { $0 == ASRProviderID.cloud ? cloud : local },
                                     realtimeFactory: { _ in .init(session: live, ingress: RealtimeAudioIngress(),
                                                                   capabilities: DashScopeRealtimeASR.capabilities) })
                assertFailure(await stage.execute(payload: .audio(samples: samples, previewText: "preview"), context: context),
                              .cancelled, r, "typed cancellation")
                r.eq(cloud.count, realtime ? 0 : 1, "M4 cancelled first provider invoked once")
                r.eq(local.count + health.withLock { $0 }, 0, "M4 cancellation has no fallback or health failure")
            }
        }
    }

    @MainActor private static func localAndPreview(_ r: SelfTest.Reporter) async {
        for (id, error, kind): (String, Error, FailureKind) in [
            (ASRProviderID.local, OfflineWhisperError.invalidLocalDirectory, .configuration(.endpointOrModel)),
            (ASRProviderID.local, OfflineWhisperError.incompatibleRuntime, .configuration(.endpointOrModel)),
            ("apple-preview", SpeechProviderError.permissionDenied, .permission(.speechRecognition)),
            ("apple-preview", SpeechProviderError.notAvailable, .readiness(.noEngine))] {
            let provider = Provider(id, error), context = SessionContext(sessionID: 946)
            context.captureRoute = route(first: id, cloud: false)
            let stage = makeASR(healthRecorder: { _, _, _ in }, providerForID: { _ in provider })
            assertFailure(await stage.execute(payload: .audio(samples: samples, previewText: ""), context: context), kind, r, id)
        }
        let context = SessionContext(sessionID: 947); context.captureRoute = route()
        let failed = Provider(ASRProviderID.cloud, credentials)
        let stage = makeASR(healthRecorder: { _, _, _ in }, providerForID: { _ in failed })
        if case .continue(.transcript(let preview)) = await stage.execute(payload: .audio(samples: samples, previewText: "optional preview"), context: context) {
            r.eq(preview, "optional preview", "M4 optional preview promotion remains unchanged")
        } else { r.check(false, "M4 optional preview promotion remains unchanged") }
    }

    @MainActor private static func boundaries(_ r: SelfTest.Reporter) async {
        let health = OSAllocatedUnfairLock<Int>(initialState: 0), provider = Provider(ASRProviderID.cloud)
        let stage = makeASR(healthRecorder: { _, _, _ in health.withLock { $0 += 1 } }, providerForID: { _ in provider })
        assertFailure(await stage.execute(payload: .audio(samples: [0.5, .nan], previewText: "preview"), context: SessionContext(sessionID: 948)),
                      .recording(.invalidAudio), r, "invalid PCM")
        r.eq(provider.count + health.withLock { $0 }, 0, "M4 invalid PCM no provider/health/preview")
        for invalidStage: any PipelineStage in [stage, InjectionStage(), PostProcessStage(), PolishStage()] {
            if case .suspend(let recovery) = await invalidStage.execute(payload: .empty, context: SessionContext(sessionID: 949)) {
                r.eq(recovery.failureKind, .internalFailure, "M4 invalid payload is internal")
            } else { r.check(false, "M4 invalid payload suspends") }
        }
        let injection = InjectionStage(settle: { throw NSError(domain: "synthetic", code: 2) },
            accessibilityTrusted: { true }, currentTarget: { .init(pid: nil, signals: .init(secureInputActive: false, focus: .blindOrUnknown)) }, copy: { _ in })
        if case .suspend(let recovery) = await injection.execute(payload: .polished("complete result", raw: "raw"), context: SessionContext(sessionID: 950)) {
            r.eq(recovery.failureKind, .deliveryBlocked, "M4 unknown pre-event delivery failure blocked")
            r.eq(recovery.textKind, .result, "M4 delivery copy owns complete result")
        } else { r.check(false, "M4 pre-event delivery failure suspends") }
    }

    @MainActor private static func typingCancellation(_ r: SelfTest.Reporter) async {
        let errors: [Error] = [CancellationError(), URLError(.cancelled),
            CloudASRError.networkError(SpeechProviderError.networkError(URLError(.cancelled)))]
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "synthetic-safe-field"),
            signals: .init(secureInputActive: false, focus: .editableText))
        for (index, error) in errors.enumerated() {
            let context = SessionContext(sessionID: UInt64(960 + index))
            context.deliveryTarget = target
            let injections = OSAllocatedUnfairLock<Int>(initialState: 0)
            var copies = 0
            let stage = InjectionStage(settle: {}, accessibilityTrusted: { true },
                currentTarget: { target }, inject: { _, _ in
                    injections.withLock { $0 += 1 }
                    throw error
                }, mode: { .unicode }, bundleID: { _ in nil }, copy: { _ in copies += 1 })
            let result = await stage.execute(payload: .polished("synthetic complete result", raw: "synthetic raw"), context: context)
            r.eq(injections.withLock { $0 }, 1, "M4 typed cancel \(index): actual typing boundary called once")
            r.eq(copies, 0, "M4 typed cancel \(index): no clipboard fallback")
            r.check(!context.deliveryEventStarted && !context.deliveryEffectStarted,
                    "M4 typed cancel \(index): no event or delivery effect")
            r.eq(context.deliveryOutcome, .cancelled, "M4 typed cancel \(index): cancelled terminal outcome")
            r.check(context.completionNotice == nil && !context.hasInjected,
                    "M4 typed cancel \(index): no clipboard success completion")
            if case .suspend(let recovery) = result {
                r.eq(recovery.failureKind, .cancelled, "M4 typed cancel \(index): cancelled recovery kind")
                r.eq(recovery.textKind, .result, "M4 typed cancel \(index): complete result ownership retained")
            } else { r.check(false, "M4 typed cancel \(index): suspension instead of successful completion") }
        }
    }
}
