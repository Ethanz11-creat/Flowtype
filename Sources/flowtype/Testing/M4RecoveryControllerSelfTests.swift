import Foundation
import Combine
import os

/// Real controller ownership with synthetic stage inputs and isolated system seams.
enum M4RecoveryControllerSelfTests {
    private struct Stage: PipelineStage {
        let name: String
        let run: @MainActor @Sendable (StagePayload, SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await run(payload, context) }
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeM4Controller.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = ConfigurationStore(defaults: defaults)
        for kind: FailureKind in [.recording(.interrupted), .recording(.invalidAudio), .transientASR] {
            var calls = 0
            let controller = SessionController(pipeline: [Stage(name: "ASR", run: { _, _ in
                calls += 1
                return .suspend(.init(failedStage: "ASR", error: CloudASRError.timeout,
                    rawText: nil, retryable: kind == .transientASR, failureKind: kind))
            })], observers: [], effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
            recoveryEffects: Fixture(configuration).recovery,
            configurationStore: configuration, refreshReadiness: { .ready }, readinessLevel: { .ready })
            controller.startRecording()
            await wait { calls == 1 }
            r.check({ if case .error = controller.sessionState { return true }; return false }(), "M4 controller: \(kind) remains actionable error")
            r.check(!controller.errorActions.contains(.retry(stage: "ASR")), "M4 controller: name and legacy Boolean cannot authorize retry without real ASR/audio")
            controller.retryFailedStage()
            for _ in 0..<10 { await Task.yield() }
            r.eq(calls, 1, "M4 controller: invalid retry cannot rerun synthetic stage")
            controller.cancel()
        }
        await ownership(r, configuration)
        await readiness(r, configuration)
        await retries(r, configuration)
        await terminal(r, configuration)
        await capturedResources(r, configuration)
        await historyReentrancy(r, configuration)
        await publicationReentrancy(r, configuration)
        statePublicationReentrancy(r, configuration)
        await callerContinuationReentrancy(r, configuration)
        r.eq(SessionState.error("safe").capsuleSize.width, 380, "M4 controller: recovery width")
        r.eq(SessionState.error("safe").capsuleSize.height, 156, "M4 controller: recovery height")
    }

    @MainActor private static func wait(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension M4RecoveryControllerSelfTests {
    @MainActor private final class Fixture {
        let configuration: ConfigurationStore
        var contexts: [SessionContext] = []
        var events: [String] = []
        var copied: [String] = []
        var histories: [UInt64] = []
        var onHistory: (() -> Void)?
        var windows: [String] = []
        var level: ReadinessLevel = .ready
        var refreshes = 0
        var onRefresh: (() -> Void)?
        var captures = 0
        weak var ownedController: SessionController?
        var armed = false
        init(_ configuration: ConfigurationStore) { self.configuration = configuration }
        var recovery: RecoveryEffects { .init(
            openAccessibilitySettings: { self.events.append("AX") },
            openMicrophoneSettings: { self.events.append("mic") },
            openSpeechRecognitionSettings: { self.events.append("speech") },
            openASRSettings: { self.events.append("ASR") },
            openHistory: { self.events.append("history") },
            copyText: { self.copied.append($0) }) }
        func controller(_ stages: [any PipelineStage]) -> SessionController {
            SessionController(pipeline: stages, observers: [], effects: .init(prepare: {},
                showWindow: { self.windows.append("show") }, hideWindow: { self.windows.append("hide") },
                saveHistory: { self.histories.append($0.sessionID); self.onHistory?() }), recoveryEffects: recovery,
                configurationStore: configuration, refreshReadiness: { self.refreshes += 1; self.onRefresh?(); return self.level },
                readinessLevel: { self.level })
        }
        func capture(_ result: StageResult) -> Stage {
            Stage(name: "Recording", run: { _, context in
                self.captures += 1; self.contexts.append(context)
                return result
            })
        }
    }

    @MainActor private static func ownership(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        var allActions = Set<RecoveryAction>()
        for kind: FailureKind in [.permission(.accessibility), .permission(.microphone), .permission(.speechRecognition),
                                 .configuration(.credentials), .processing, .deliveryBlocked, .transientASR] {
            let f = Fixture(configuration)
            let recovery = ErrorRecoveryContext(failedStage: "ASR", error: CloudASRError.apiError(statusCode: 401,
                message: "SECRET https://private.invalid/?token=SECRET"), rawText: "complete private text",
                retryable: true, failureKind: kind, textKind: kind == .deliveryBlocked ? .result : .raw)
            let c = f.controller([f.capture(.suspend(recovery))])
            c.startRecording(); await wait { c.recoveryCard != nil }
            guard let old = c.recoveryCard else { r.check(false, "M4 ownership card exists"); continue }
            r.check(!String(describing: old).contains("SECRET") && !String(describing: old).contains("complete private text"), "M4 card contains no provider body/URL/transcript")
            r.check(old.presentation.actions.count <= 4, "M4 card fits maximum four actions")
            c.performRecoveryAction(.viewHistory, cardID: old.id)
            r.eq(f.events.count, 0, "M4 disallowed current action has no effect")
            c.startRecording(); await wait { f.captures == 2 }
            let current = c.recoveryCard, state = c.sessionState
            let cfg = configuration.current.asrRoutingPolicy
            for action in old.presentation.actions {
                allActions.insert(action)
                c.performRecoveryAction(action, cardID: old.id)
            }
            r.eq(c.recoveryCard, current, "M4 old card actions cannot replace new card")
            r.eq(c.sessionState, state, "M4 old card actions cannot change new session state")
            r.eq(configuration.current.asrRoutingPolicy, cfg, "M4 old card actions cannot change config")
            r.eq(f.events.count + f.copied.count + f.refreshes + f.histories.count, 0, "M4 old card actions have zero external effects")
            r.eq(f.captures, 2, "M4 old rerecord never starts another capture")
            r.eq(c.lastDeliverySummary, nil, "M4 old actions never publish summary")
            c.cancel()
            for action in old.presentation.actions { c.performRecoveryAction(action, cardID: old.id) }
            r.eq(c.sessionState, .idle, "M4 cleared card invalidates all buttons")
        }
        r.check(allActions.isSuperset(of: [.copyRaw, .copyResult, .rerecord, .dismiss, .openAccessibilitySettings,
            .openMicrophoneSettings, .openSpeechRecognitionSettings, .openASRSettings, .recheckReadiness]), "M4 stale ownership matrix covers action families")
    }

    @MainActor private static func readiness(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        let f = Fixture(configuration)
        var config = configuration.current; config.asrRoutingPolicy = .cloudOnly; configuration.save(config)
        f.level = .blocked(.noEngine)
        let c = f.controller([f.capture(.complete)])
        c.startRecording()
        let noEngine = c.recoveryCard!
        f.level = .blocked(.microphoneDenied)
        c.performRecoveryAction(.useAutomaticRouting, cardID: noEngine.id)
        let mic = c.recoveryCard!
        r.eq(configuration.current.asrRoutingPolicy, .auto, "M4 route action changes only policy")
        r.check(mic.id != noEngine.id && mic.presentation.kind == .permission(.microphone), "M4 route still blocked refreshes card with current reason")
        let afterRefresh = f.refreshes
        for action in noEngine.presentation.actions { c.performRecoveryAction(action, cardID: noEngine.id) }
        r.eq(c.recoveryCard, mic, "M4 all stale noEngine actions ignored after refresh")
        r.eq(f.refreshes, afterRefresh, "M4 stale route/recheck cannot refresh")
        c.performRecoveryAction(.openMicrophoneSettings, cardID: mic.id)
        r.eq(f.events, ["mic"], "M4 microphone card opens only microphone settings")
        r.eq(f.captures, 0, "M4 settings/recheck does not start capture")
        c.performRecoveryAction(.recheckReadiness, cardID: mic.id)
        let refreshed = c.recoveryCard!
        for action in mic.presentation.actions { c.performRecoveryAction(action, cardID: mic.id) }
        r.eq(c.recoveryCard, refreshed, "M4 all old permission actions ignored after blocked refresh")
        r.eq(f.events, ["mic"], "M4 stale permission settings does not open")
        for level: ReadinessLevel in [.ready, .degraded(.accessibilityMissing), .degraded(.basicOnly)] {
            f.level = level
            c.performRecoveryAction(.recheckReadiness, cardID: c.recoveryCard!.id)
            r.eq(c.sessionState, .idle, "M4 ready/degraded recheck remains idle")
            r.eq(c.recoveryCard, nil, "M4 ready/degraded clears card")
            c.startRecording(); await wait { c.sessionState == .idle }
            r.check(f.captures > 0, "M4 degraded menu capture remains eligible")
            f.level = .blocked(.noEngine); c.startRecording()
        }
        c.cancel()
        f.level = .blocked(.noEngine)
        c.startRecording()
        let staleRefresh = c.recoveryCard!
        var reentrantCard: RecoveryCard?
        f.onRefresh = {
            f.level = .blocked(.microphoneDenied)
            c.startRecording()
            reentrantCard = c.recoveryCard
        }
        c.performRecoveryAction(.recheckReadiness, cardID: staleRefresh.id)
        let newest = c.recoveryCard!
        r.eq(newest.presentation.kind, .permission(.microphone), "M4 refresh reentrancy preserves newer session reason")
        r.check(newest.sessionID != staleRefresh.sessionID, "M4 refresh reentrancy preserves newer session identity")
        r.eq(newest, reentrantCard, "M4 stale refresh completion cannot replace newer card")
        f.onRefresh = nil
        c.cancel()
        for permission: PermissionKind in [.accessibility, .microphone, .speechRecognition] {
            let g = Fixture(configuration)
            let c = g.controller([g.capture(.suspend(.init(failedStage: "Recording", error: CloudASRError.timeout,
                rawText: nil, retryable: false, failureKind: .permission(permission))))])
            c.startRecording(); await wait { c.recoveryCard != nil }
            let card = c.recoveryCard!
            c.performRecoveryAction(card.presentation.actions[0], cardID: card.id)
            r.eq(g.events, [permission == .accessibility ? "AX" : permission == .microphone ? "mic" : "speech"], "M4 permission opens matching settings seam")
            r.eq(g.captures, 1, "M4 permission settings never implicitly records")
            c.performRecoveryAction(.recheckReadiness, cardID: card.id)
            r.eq(c.sessionState, .idle, "M4 permission recheck ready idle")
            c.cancel()
        }
    }

    private final class Provider: ASRProvider, @unchecked Sendable {
        let id = ASRProviderID.cloud
        var displayName: String { "synthetic" }
        var isAvailable: Bool { true }
        var capabilities: ASRCapabilities { .init(supportsLanguageHint: true, supportsContextHint: true,
                                                   requiresNetwork: false, location: .onDevice) }
        let error: Error
        let requests = OSAllocatedUnfairLock<[ASRRequest]>(initialState: [])
        init(_ error: Error) { self.error = error }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            requests.withLock { $0.append(request) }
            throw error
        }
    }

    @MainActor private static func retries(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        for credentials in [false, true] {
            let f = Fixture(configuration)
            let p = Provider(credentials ? CloudASRError.apiError(statusCode: 401, message: "SECRET") : CloudASRError.timeout)
            let route = ASRRouteSnapshot(policy: .cloudOnly, selectedProviderID: ASRProviderID.cloud,
                localAvailable: false, cloudAvailable: true, cloudConfiguration: nil, language: "en")
            let capture = Stage(name: "Recording", run: { _, ctx in
                f.captures += 1; f.contexts.append(ctx); ctx.captureRoute = route
                return .continue(.audio(samples: [0.5, -0.25], previewText: ""))
            })
            let stage = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in p }, phrases: { [] })
            let c = f.controller([capture, stage])
            c.startRecording(); await wait { c.recoveryCard != nil }
            let old = c.recoveryCard!
            r.eq(old.presentation.actions.contains(.retry(stage: "ASR")), !credentials, "M4 real ASR typed policy controls retry")
            if credentials {
                c.performRecoveryAction(.openASRSettings, cardID: old.id)
                var cfg = configuration.current; cfg.asrRoutingPolicy = .auto; configuration.save(cfg)
                c.performRecoveryAction(.retry(stage: "ASR"), cardID: old.id)
                r.eq(p.requests.withLock { $0.count }, 1, "M4 config repair cannot replay captured request")
                r.eq(f.events, ["ASR"], "M4 config settings effect only")
            } else {
                c.performRecoveryAction(.retry(stage: "ASR"), cardID: old.id)
                await wait { c.recoveryCard != nil }
                r.eq(p.requests.withLock { $0.count }, 2, "M4 explicit retry runs actual ASR once")
                r.eq(p.requests.withLock { $0.last?.samples }, [0.5, -0.25], "M4 retry retains exact original PCM")
                r.eq(p.requests.withLock { $0.last?.language }, "en", "M4 retry retains captured language")
                r.eq(f.contexts.count, 1, "M4 retry retains original session")
                r.eq(f.contexts[0].captureRoute, route, "M4 retry retains captured route")
                r.check((f.contexts[0].completionBudget?.remainingSeconds ?? 0) > 19, "M4 retry renews twenty second budget")
                r.check(!f.contexts[0].usePolish, "M4 retry never opts into polish")
            }
            let current = c.recoveryCard!
            c.performRecoveryAction(.rerecord, cardID: current.id)
            await wait { f.contexts.count == 2 && c.recoveryCard != nil }
            r.check(f.contexts[0].sessionID != f.contexts[1].sessionID, "M4 rerecord creates fresh identity and capture")
            let calls = p.requests.withLock { $0.count }
            for action in old.presentation.actions { c.performRecoveryAction(action, cardID: old.id) }
            r.eq(p.requests.withLock { $0.count }, calls, "M4 obsolete retry card has no provider calls")
            r.eq(f.captures, 2, "M4 obsolete retry/rerecord card cannot record again")
            c.cancel()
        }
    }

    @MainActor private final class Board: DeliveryPasteboard {
        var value: PasteboardContents = [["public.text": Data("original".utf8)]]
        var changeCount = 0
        var afterWriteRead: (() -> Void)?
        var writes = 0
        func contents() -> PasteboardContents? {
            if writes > 0, let hook = afterWriteRead { afterWriteRead = nil; hook() }
            return value
        }
        func write(_ contents: PasteboardContents) -> PasteboardWriteReceipt? {
            writes += 1; changeCount += 1; value = contents
            return .init(changeCount: changeCount, succeeded: true)
        }
    }

    @MainActor private static func terminal(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "synthetic"),
            signals: .init(secureInputActive: false, focus: .editableText))
        let text = String(repeating: "full private result\n", count: 30)
        for mode in ["typing", "paste", "boardBeforeEvent", "cancel"] {
            let f = Fixture(configuration), board = Board(), transaction = ClipboardTransaction()
            var config = configuration.current; config.storeTranscriptText = false; configuration.save(config)
            var events = 0, pasteCalls = 0, implicitCopies = 0
            let capture = Stage(name: "Text", run: { _, ctx in
                f.contexts.append(ctx); ctx.deliveryTarget = target
                return .continue(.polished(text, raw: "raw"))
            })
            var controller: SessionController?
            let stage = InjectionStage(settle: {}, accessibilityTrusted: { true }, currentTarget: { target },
                typingEvents: .init(prepare: { pair in
                    // The actual chunk loop fails after the first balanced event.
                    if pair != .unicode("full private result") { throw InjectionError.eventCreationFailed }
                    return {}
                }, wait: {}), mode: { mode == "typing" ? .unicode : .pasteInSupportedApps },
                bundleID: { _ in "com.apple.TextEdit" }, paste: { result, ctx, _ in
                    pasteCalls += 1
                    if mode == "paste" {
                        try? KeyboardInjector.postIfActive(context: ctx) { events += 1 }
                        return .uncertain
                    }
                    if mode == "boardBeforeEvent" {
                        board.afterWriteRead = { board.changeCount += 1; board.value = [["public.text": Data("user copy".utf8)]] }
                    }
                    return await transaction.paste(result, context: ctx, board: board, validate: { true },
                        prepareDispatch: { { events += 1 } }, settle: {
                            if mode == "cancel" { controller?.cancel() }
                        })
                }, copy: { _ in implicitCopies += 1 })
            let c = f.controller([capture, stage]); controller = c
            c.startRecording()
            await wait { c.recoveryCard != nil || (f.histories.count == 1 && c.sessionState == .idle) }
            guard let ctx = f.contexts.first else { r.check(false, "M4 terminal owns context"); continue }
            r.eq(f.histories.count, 1, "M4 terminal \(mode): exactly one save path with no-op storage")
            r.eq(c.lastDeliverySummary?.outcome, .uncertain, "M4 terminal \(mode): uncertain summary")
            r.check(ctx.isCancelled, "M4 terminal \(mode): event gate closed")
            r.eq(implicitCopies + f.copied.count, 0, "M4 terminal \(mode): no implicit full-text copy")
            if mode == "cancel" {
                r.eq(c.sessionState, .idle, "M4 explicit cancel stays idle")
                r.eq(c.recoveryCard, nil, "M4 explicit cancel does not present terminal card")
            } else if let card = c.recoveryCard {
                let sent = mode != "boardBeforeEvent"
                r.eq(card.presentation.kind, sent ? .deliveryUncertain : .deliveryBlocked, "M4 terminal \(mode): copy matches actual event evidence")
                r.eq(card.presentation.actions, sent ? [.copyResult, .viewHistory, .dismiss] : [.copyResult, .dismiss], "M4 terminal \(mode): no resend action")
                r.check(!card.presentation.message.contains("历史") && !String(describing: card).contains("private"), "M4 privacy/no-op storage: safe copy never promises persisted transcript")
                c.performRecoveryAction(.copyResult, cardID: card.id)
                r.eq(f.copied, [text], "M4 terminal explicit copy returns complete final text")
                c.performRecoveryAction(.viewHistory, cardID: card.id)
                r.eq(f.events, sent ? ["history"] : [], "M4 terminal history only navigates when allowed")
                c.performRecoveryAction(.retry(stage: "Injection"), cardID: card.id)
                r.eq(pasteCalls, mode == "typing" ? 0 : 1, "M4 terminal no duplicate delivery attempt")
                ctx.statePublisher.send(.processing(provider: "late"))
                ctx.markReady()
                r.eq(c.recoveryCard, card, "M4 terminal late publisher cannot replace card")
                let summary = c.lastDeliverySummary
                c.startRecording(); await wait { f.contexts.count == 2 }
                let newCard = c.recoveryCard
                for action in card.presentation.actions { c.performRecoveryAction(action, cardID: card.id) }
                r.eq(f.copied, [text], "M4 stale terminal copy cannot overwrite clipboard")
                r.eq(f.events, sent ? ["history"] : [], "M4 stale terminal history cannot navigate")
                r.eq(c.recoveryCard, newCard, "M4 stale terminal dismiss cannot clear newer state")
                r.check(summary != nil, "M4 terminal summary established")
            } else { r.check(false, "M4 normal uncertain finish presents persistent card") }
            let count = f.histories.count
            c.cancel(); c.cancel(); c.dismissError()
            r.eq(f.histories.count, count, "M4 repeated cancel/dismiss does not save again")
        }
    }
}

extension M4RecoveryControllerSelfTests {
    private actor Live: RealtimeASRSession {
        var finishes = 0
        var chunks: [[Float]] = []
        func start() async throws {}
        func append(samples: [Float]) async throws { chunks.append(samples) }
        func finish() async throws -> ASRResult { finishes += 1; throw CloudASRError.timeout }
        func cancel() async {}
    }

    @MainActor private static func capturedResources(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        let f = Fixture(configuration), oldLive = Live(), newLive = Live()
        let oldHandle = RealtimeASRSessionHandle(session: oldLive, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
        let newHandle = RealtimeASRSessionHandle(session: newLive, ingress: RealtimeAudioIngress(), capabilities: DashScopeRealtimeASR.capabilities)
        let route = ASRRouteSnapshot(policy: .cloudOnly, selectedProviderID: ASRProviderID.cloud, localAvailable: false,
            cloudAvailable: true, cloudConfiguration: .init(provider: .defaultParaformer(isActive: true), apiKey: "synthetic", sendContext: false), language: "en")
        let factories = OSAllocatedUnfairLock<Int>(initialState: 0)
        let capture = Stage(name: "Recording", run: { _, ctx in
            f.contexts.append(ctx)
            ctx.prepareRealtime(route: route, factory: { _ in oldHandle })
            return .continue(.audio(samples: [0.5, -0.25], previewText: ""))
        })
        let asr = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in nil },
            realtimeFactory: { _ in factories.withLock { $0 += 1 }; return newHandle }, phrases: { [] })
        let c = f.controller([capture, asr])
        c.startRecording(); await wait { c.recoveryCard != nil }
        c.retryFailedStage(); await wait { c.recoveryCard != nil }
        r.eq(factories.withLock { $0 }, 1, "M4 realtime retry creates fresh handle")
        r.eq(await oldLive.finishes, 1, "M4 realtime retry never reuses consumed handle")
        r.eq(await newLive.finishes, 1, "M4 realtime retry finishes new handle once")
        r.eq(await newLive.chunks.flatMap { $0 }, [0.5, -0.25], "M4 realtime retry sends complete original PCM")
        r.eq(f.contexts.first?.captureRoute, route, "M4 realtime retry retains original route/language/credentials")
        c.cancel()

        let local = Provider(CloudASRError.timeout), forbiddenReplacement = Provider(CloudASRError.timeout)
        let lease = LocalASRLease(id: UUID(), identity: .init(id: "synthetic", displayName: "synthetic", engine: "synthetic",
            repoID: nil, directory: URL(fileURLWithPath: "/synthetic/nonexistent")), provider: local)
        var localRoute = ASRRouteSnapshot(policy: .localOnly, selectedProviderID: ASRProviderID.local,
            localAvailable: true, cloudAvailable: false, cloudConfiguration: nil, language: "zh")
        localRoute.localLease = lease
        let savedRoute = localRoute
        let g = Fixture(configuration)
        let localCapture = Stage(name: "Recording", run: { _, ctx in
            g.contexts.append(ctx); ctx.captureRoute = savedRoute
            return .continue(.audio(samples: [0.5], previewText: ""))
        })
        let localASR = ASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in forbiddenReplacement }, phrases: { [] })
        let localController = g.controller([localCapture, localASR])
        localController.startRecording(); await wait { localController.recoveryCard != nil }
        localController.retryFailedStage(); await wait { localController.recoveryCard != nil }
        r.eq(local.requests.withLock { $0.count }, 2, "M4 retry uses retained local lease provider")
        r.eq(forbiddenReplacement.requests.withLock { $0.count }, 0, "M4 retry never resolves replacement local provider")
        r.eq(g.contexts.first?.captureRoute?.localLease?.id, lease.id, "M4 retry preserves lease identity")
        localController.cancel()
    }
}

extension M4RecoveryControllerSelfTests {
    @MainActor private static func historyReentrancy(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "synthetic"),
            signals: .init(secureInputActive: false, focus: .editableText))
        for cancelDuringPaste in [false, true] {
            let f = Fixture(configuration)
            var c: SessionController!
            let capture = Stage(name: "Text", run: { _, ctx in
                f.contexts.append(ctx)
                if f.contexts.count > 1 {
                    return .suspend(.init(failedStage: "Recording", error: PermissionError.microphoneDenied,
                        rawText: nil, retryable: false))
                }
                ctx.deliveryTarget = target
                return .continue(.polished("complete result", raw: "raw"))
            })
            let injection = InjectionStage(settle: {}, accessibilityTrusted: { true }, currentTarget: { target },
                mode: { .pasteInSupportedApps }, bundleID: { _ in "com.apple.TextEdit" }, paste: { _, ctx, _ in
                    try? KeyboardInjector.postIfActive(context: ctx) {}
                    if cancelDuringPaste { c.cancel() }
                    return .uncertain
                }, copy: { _ in r.check(false, "M4 history callback never implicitly copies") })
            c = f.controller([capture, injection])
            f.onHistory = {
                f.onHistory = nil
                c.cancel()
                c.startRecording()
            }
            c.startRecording()
            await wait { f.contexts.count == 2 && c.recoveryCard?.presentation.kind == .permission(.microphone) }
            r.eq(f.contexts.count, 2, "M4 history reentrancy \(cancelDuringPaste): fresh capture survives old completion")
            r.eq(c.recoveryCard?.presentation.kind, .permission(.microphone), "M4 history reentrancy \(cancelDuringPaste): newer card survives")
            r.check(c.recoveryCard?.sessionID != f.contexts.first?.sessionID, "M4 history reentrancy \(cancelDuringPaste): old terminal cannot own new card")
            r.eq(f.histories.count, 1, "M4 history reentrancy \(cancelDuringPaste): history claim remains once-only")
            r.eq(f.windows.last, "show", "M4 history reentrancy \(cancelDuringPaste): newer window remains visible")
            r.check(f.contexts.last?.isCancelled == false, "M4 history reentrancy \(cancelDuringPaste): newer event gate stays open")
            f.level = .blocked(.noEngine)
            if let card = c.recoveryCard { c.performRecoveryAction(.recheckReadiness, cardID: card.id) }
            r.eq(c.recoveryCard?.presentation.kind, .readiness(.noEngine), "M4 history reentrancy \(cancelDuringPaste): newer context retains action authority")
            c.cancel()
        }
    }
}

extension M4RecoveryControllerSelfTests {
    @MainActor private static func publicationReentrancy(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "publication"),
            signals: .init(secureInputActive: false, focus: .editableText))
        for explicitCancel in [false, true] {
            let f = Fixture(configuration)
            let capture = Stage(name: "Text", run: { _, context in
                f.contexts.append(context); context.deliveryTarget = target
                return .continue(.polished("complete result", raw: "raw"))
            })
            let injection = InjectionStage(settle: {}, accessibilityTrusted: { true }, currentTarget: { target },
                mode: { .pasteInSupportedApps }, bundleID: { _ in "com.apple.TextEdit" }, paste: { _, context, _ in
                    try? KeyboardInjector.postIfActive(context: context) {}
                    if explicitCancel { f.ownedController?.cancel() }
                    return .uncertain
                }, copy: { _ in r.check(false, "M4 publication: no implicit copy") })
            let c = f.controller([capture, injection])
            f.ownedController = c
            var fired = false
            var summaries: [LastDeliverySummary] = []
            var newerCard: RecoveryCard?
            let subscription = c.$lastDeliverySummary.sink { summary in
                guard let summary else { return }
                summaries.append(summary)
                guard !fired else { return }
                fired = true
                f.level = .blocked(.microphoneDenied)
                c.cancel()
                c.startRecording()
                newerCard = c.recoveryCard
            }
            c.startRecording()
            await wait { fired }
            for _ in 0..<10 { await Task.yield() }
            let label = "M4 summary subscriber \(explicitCancel ? "cancel" : "finish")"
            r.eq(summaries.count, 1, "\(label): once-only synchronous summary publication")
            r.eq(f.histories.count, 1, "\(label): once-only history")
            r.eq(c.recoveryCard, newerCard, "\(label): newer blocked card retained")
            r.eq(c.sessionState, .error("麦克风权限未开启"), "\(label): newer message retained")
            r.eq(f.windows.last, "show", "\(label): newer window retained")
            if let card = c.recoveryCard { c.performRecoveryAction(.openMicrophoneSettings, cardID: card.id) }
            r.eq(f.events, ["mic"], "\(label): displayed card owns allowed effects")
            f.level = .blocked(.noEngine)
            if let card = c.recoveryCard { c.performRecoveryAction(.recheckReadiness, cardID: card.id) }
            r.eq(c.recoveryCard?.presentation.kind, .readiness(.noEngine), "\(label): newer context retains refresh authority")
            r.eq(c.recoveryCard?.sessionID, newerCard?.sessionID, "\(label): refreshed card retains newer identity")
            subscription.cancel()
            c.cancel(); c.cancel()
            r.eq(f.histories.count, 1, "\(label): repeated cancel never saves again")
        }

        let f = Fixture(configuration)
        f.level = .blocked(.microphoneDenied)
        let c = f.controller([f.capture(.complete)])
        c.startRecording()
        let original = c.recoveryCard!
        var armed = false, fired = false
        var newerCard: RecoveryCard?
        let subscription = c.recoveryCardPublisher.sink { card in
            guard armed, !fired, card != nil else { return }
            fired = true
            f.level = .blocked(.microphoneDenied)
            c.startRecording()
            newerCard = c.recoveryCard
        }
        armed = true
        f.level = .blocked(.noEngine)
        c.performRecoveryAction(.recheckReadiness, cardID: original.id)
        r.check(fired, "M4 card subscriber: real synchronous publisher fired")
        r.eq(c.recoveryCard, newerCard, "M4 card subscriber: public card matches newest private authority")
        r.eq(c.sessionState, .error("麦克风权限未开启"), "M4 card subscriber: newest message survives outer setter")
        r.eq(c.errorActions, newerCard?.presentation.actions ?? [], "M4 card subscriber: action projection coherent")
        r.eq(c.lastErrorRawText, nil, "M4 card subscriber: copy projection coherent")
        r.eq(f.windows.last, "show", "M4 card subscriber: newest window remains visible")
        if let card = c.recoveryCard { c.performRecoveryAction(.openMicrophoneSettings, cardID: card.id) }
        r.eq(f.events, ["mic"], "M4 card subscriber: displayed card can execute its allowed action")
        f.level = .ready
        if let card = c.recoveryCard { c.performRecoveryAction(.recheckReadiness, cardID: card.id) }
        r.eq(c.sessionState, .idle, "M4 card subscriber: current context owns recheck and clears coherently")
        subscription.cancel()
        c.cancel()
    }
}

extension M4RecoveryControllerSelfTests {
    @MainActor private static func statePublicationReentrancy(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) {
        for channel in ["state", "objectWillChange"] {
            let f = Fixture(configuration)
            f.level = .blocked(.microphoneDenied)
            let c = f.controller([f.capture(.complete)])
            c.startRecording()
            let original = c.recoveryCard!
            var fired = false
            var newerCard: RecoveryCard?
            let replace: @MainActor () -> Void = {
                guard f.armed, !fired else { return }
                fired = true
                f.level = .blocked(.microphoneDenied)
                c.startRecording()
                newerCard = c.recoveryCard
            }
            let subscription: AnyCancellable
            if channel == "state" {
                subscription = c.sessionStatePublisher.sink { state in
                    if state == .error("没有可用的语音识别引擎") { replace() }
                }
            } else {
                subscription = c.objectWillChange.sink {
                    if c.recoveryCard?.presentation.kind == .readiness(.noEngine) { replace() }
                }
            }
            var observedStates: [SessionState] = []
            var observedCards: [RecoveryCard?] = []
            let stateObservation = c.sessionStatePublisher.sink { observedStates.append($0) }
            let cardObservation = c.recoveryCardPublisher.sink { observedCards.append($0) }
            f.armed = true
            f.level = .blocked(.noEngine)
            c.performRecoveryAction(.recheckReadiness, cardID: original.id)
            r.check(fired, "M4 \(channel) subscriber: synchronous error callback exercised")
            r.eq(c.recoveryCard, newerCard, "M4 \(channel) subscriber: newest card retained")
            r.eq(c.sessionState, .error("麦克风权限未开启"), "M4 \(channel) subscriber: canonical error retained")
            r.eq(c.errorActions, newerCard?.presentation.actions ?? [], "M4 \(channel) subscriber: coherent actions")
            r.eq(observedStates.last, c.sessionState, "M4 \(channel) subscriber: later state consumer never ends on superseded outer value")
            r.eq(observedCards.last ?? nil, c.recoveryCard, "M4 \(channel) subscriber: later card consumer never ends on superseded outer value")
            r.eq(f.windows.last, "show", "M4 \(channel) subscriber: window remains visible")
            if let card = c.recoveryCard { c.performRecoveryAction(.openMicrophoneSettings, cardID: card.id) }
            r.eq(f.events, ["mic"], "M4 \(channel) subscriber: current card owns settings action")
            f.level = .ready
            if let card = c.recoveryCard { c.performRecoveryAction(.recheckReadiness, cardID: card.id) }
            r.eq(c.sessionState, .idle, "M4 \(channel) subscriber: current context owns refresh")
            stateObservation.cancel(); cardObservation.cancel()
            subscription.cancel(); c.cancel()
        }
    }
}

extension M4RecoveryControllerSelfTests {
    @MainActor private static func callerContinuationReentrancy(_ r: SelfTest.Reporter, _ configuration: ConfigurationStore) async {
        let target = DeliveryTargetSnapshot(pid: 42, focusIdentity: .init(testID: "caller-continuation"),
            signals: .init(secureInputActive: false, focus: .editableText))
        for replacement in ["new-session", "same-session"] {
            let f = Fixture(configuration)
            let cancellations = OSAllocatedUnfairLock<Int>(initialState: 0)
            let (recording, releaseRecording) = AsyncStream<Void>.makeStream()
            defer { releaseRecording.finish() }
            let capture = Stage(name: "Recording", run: { _, context in
                f.contexts.append(context)
                if f.contexts.count == 1 {
                    context.deliveryTarget = target
                    return .continue(.polished("complete result", raw: "raw"))
                }
                // The real controller must retain this task, as RecordingStage
                // relies on its task cancellation handler to stop the recorder.
                await withTaskCancellationHandler {
                    context.markReady()
                    var iterator = recording.makeAsyncIterator()
                    _ = await iterator.next()
                } onCancel: {
                    cancellations.withLock { $0 += 1 }
                }
                return .complete
            })
            let injection = InjectionStage(settle: {}, accessibilityTrusted: { true }, currentTarget: { target },
                mode: { .pasteInSupportedApps }, bundleID: { _ in "com.apple.TextEdit" }, paste: { _, context, _ in
                    try? KeyboardInjector.postIfActive(context: context) { f.events.append("event") }
                    return .uncertain
                }, copy: { f.copied.append($0) })
            let c = f.controller([capture, injection])
            var fired = false
            let subscription = c.sessionStatePublisher.sink { state in
                guard state == .injecting, !fired else { return }
                fired = true
                if replacement == "new-session" {
                    c.cancel()
                    c.startRecording()
                } else {
                    f.contexts.first?.statePublisher.send(.processing(provider: "replacement"))
                }
            }
            c.startRecording()
            await wait { fired && (replacement == "same-session" || c.isRecording) }
            if replacement == "same-session" { await wait { !f.histories.isEmpty } }
            for _ in 0..<10 { await Task.yield() }
            r.check(fired, "M4 caller \(replacement): injecting subscriber replaced the continuation")
            if replacement == "new-session" {
                r.eq(f.contexts.count, 2, "M4 caller replacement: new recording stage actually started")
                r.check(c.isRecording, "M4 caller replacement: new recording marked ready")
                c.cancel()
                await wait { cancellations.withLock { $0 } == 1 }
                r.eq(cancellations.withLock { $0 }, 1, "M4 caller replacement: cancel reaches the actual new recording task exactly once")
                c.cancel()
                r.eq(cancellations.withLock { $0 }, 1, "M4 caller replacement: repeated cancel does not repeat recorder cleanup")
            } else {
                r.eq(c.sessionState, .processing(provider: "replacement"), "M4 caller same-session: newer presentation retains authority")
            }
            r.eq(f.events, [], "M4 caller \(replacement): obsolete injection posts no event")
            r.eq(f.copied, [], "M4 caller \(replacement): obsolete injection copies no text")
            r.eq(f.histories, [], "M4 caller \(replacement): obsolete injection saves no history")
            subscription.cancel()
            c.cancel()
            releaseRecording.finish()
        }

        let f = Fixture(configuration)
        let c = f.controller([f.capture(.complete)])
        var fired = false
        let subscription = c.sessionStatePublisher.sink { state in
            guard state == .preparing, !fired else { return }
            fired = true
            c.cancel()
        }
        c.startRecording()
        for _ in 0..<10 { await Task.yield() }
        r.check(fired, "M4 preparing caller: synchronous cancellation exercised")
        r.eq(c.sessionState, .idle, "M4 preparing caller: cancellation stays idle")
        r.eq(f.windows.last, "hide", "M4 preparing caller: cancelled window is not reopened")
        r.eq(f.captures, 0, "M4 preparing caller: cancelled preparation starts no stage")
        subscription.cancel()
        c.cancel()
    }
}
