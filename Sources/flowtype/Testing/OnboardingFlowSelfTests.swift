import Foundation

/// Drives the same navigation and button actions as the UI with real trial controllers.
@MainActor
enum OnboardingFlowSelfTests {
    private struct Stage: PipelineStage {
        let name = "Onboarding fake capture"
        let capture: @MainActor @Sendable (SessionContext) async -> StageResult
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { await capture(context) }
    }
    @MainActor private final class Capture {
        var contexts: [SessionContext] = []
        var continuations: [CheckedContinuation<Void, Never>] = []
        func run(_ context: SessionContext) async -> StageResult {
            contexts.append(context)
            context.markReady()
            await withCheckedContinuation { continuations.append($0) }
            return .complete
        }
        func drain() { let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
    }
    private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    static func snapshot(engine: EngineReadiness = .ready, mic: PermissionState = .granted,
                         ax: PermissionState = .granted) -> ReadinessSnapshot {
        .init(accessibility: ax, microphone: mic, speechRecognition: .notDetermined,
              localModel: engine, cloudASR: .unavailable(reason: "fixture"),
              appleSpeech: .unavailable(reason: "fixture"), computedAt: Date())
    }
    static func run(_ r: SelfTest.Reporter) async {
        let suite = "FlowTypeOnboarding.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        let effects = ValidationEffects.live.snapshot
        await finishDoesNotPrepareEngine(r, store)
        await lifecycleActions(r, store)
        await trialConfigurationAndReadiness(r, store)
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "onboarding/trial: zero attempted real external effects")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "onboarding/trial: zero permitted real external effects")
    }

    private static func finishDoesNotPrepareEngine(_ r: SelfTest.Reporter, _ store: ConfigurationStore) async {
        print("--- OnboardingFlowSelfTests.finishDoesNotPrepareEngine ---")
        for skipAt in OnboardingStep.allCases {
            var refreshes = 0, copies = 0, finishes = 0
            let capture = Capture(), resources = SessionResourceCoordinator()
            let presenter = TrialSessionPresenter(configuration: store, resources: resources,
                refreshReadiness: { refreshes += 1; return .ready }, readinessLevel: { .ready },
                copy: { _ in copies += 1 }, makeStages: { _ in [Stage(capture: { await capture.run($0) })] })
            let flow = OnboardingFlow(trial: presenter, navigation: SettingsNavigation(), onNavigate: { _ in }) { finishes += 1 }
            r.eq(flow.step, .introduction, "onboarding: begins with introduction")
            flow.back()
            r.eq(flow.step, .introduction, "onboarding: back at first step is inert")
            for _ in 0..<skipAt.rawValue { flow.advance() }
            r.eq(flow.step, skipAt, "onboarding: engine precedes permissions and trial")
            if skipAt != .introduction { flow.back(); flow.advance() }
            r.eq(capture.contexts.count, 0, "trialNeedsExplicitStart: browsing/back never records")
            flow.finish(); flow.finish(); flow.advance()
            for _ in 0..<10 { await Task.yield() }
            r.eq(finishes, 1, "onboarding: skip/finish completion is once only at \(skipAt)")
            r.eq(refreshes, 0, "finishDoesNotPrepareEngine: no recording/preflight/permission entry at \(skipAt)")
            r.eq(capture.contexts.count, 0, "finishDoesNotPrepareEngine: zero capture at \(skipAt)")
            r.eq(copies, 0, "finishDoesNotPrepareEngine: zero copies at \(skipAt)")
            presenter.cancel(); capture.drain()
            await wait { resources.owner == nil }
        }
    }

    private static func lifecycleActions(_ r: SelfTest.Reporter, _ store: ConfigurationStore) async {
        print("--- OnboardingFlowSelfTests.lifecycleActions ---")
        let monitor = ReadinessMonitor(snapshot: snapshot())
        let capture = Capture(), resources = SessionResourceCoordinator()
        let presenter = TrialSessionPresenter(configuration: store, resources: resources,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { _ in },
            makeStages: { _ in [Stage(capture: { await capture.run($0) })] })
        let flow = OnboardingFlow(trial: presenter, navigation: SettingsNavigation(), onNavigate: { _ in }, onFinish: {})
        let view = TrialSessionView(presenter: presenter, store: store, monitor: monitor, configureEngine: flow.configureEngine)
        _ = view.body
        r.eq(capture.contexts.count, 0, "trialNeedsExplicitStart: evaluating actual trial view is inert")
        for _ in 0..<3 { flow.advance() }
        view.start()
        await wait { capture.contexts.count == 1 }
        r.eq(capture.contexts.count, 1, "trial button starts injected actual presenter")
        view.stop()
        r.check(presenter.controller.isProcessing, "trial stop button stops actual recording")
        flow.back()
        r.check(capture.contexts.first?.isCancelled == true, "onboarding: back from trial cancels actual presenter")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }

        flow.advance(); view.start()
        await wait { capture.contexts.count == 2 }
        view.disappear()
        r.check(capture.contexts.last?.isCancelled == true, "trial onDisappear action cancels actual injected presenter")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }

        view.start(); await wait { capture.contexts.count == 3 }
        flow.close()
        r.check(capture.contexts.last?.isCancelled == true, "onboarding window-close action cancels actual presenter")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }

        view.start(); await wait { capture.contexts.count == 4 }
        flow.finish()
        r.check(capture.contexts.last?.isCancelled == true, "onboarding finish cancels actual presenter")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }

        view.start(); await wait { capture.contexts.count == 5 }
        view.start()
        r.check(capture.contexts.last?.isCancelled == true, "trial explicit restart cancels old injected presenter session")
        r.eq(capture.contexts.count, 5, "trial restart waits for old capture to drain without implicit queue")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }
        var destinations: [ClientDestination] = []
        let navigation = SettingsNavigation()
        let navigationFlow = OnboardingFlow(trial: presenter, navigation: navigation,
            onNavigate: { destinations.append($0) }, onFinish: {})
        view.start(); await wait { capture.contexts.count == 6 }
        let guardOwner = UUID()
        navigation.installNavigationGuard(owner: guardOwner, permits: { _ in false })
        navigation.navigate(to: .settings(.text))
        r.eq(destinations, [], "onboarding secondary navigation preserves editor guard")
        r.check(capture.contexts.last?.isCancelled == false, "rejected navigation leaves current trial intact")
        navigation.removeNavigationGuard(owner: guardOwner)
        navigation.navigate(to: .settings(.text))
        r.eq(destinations, [.settings(.text)], "onboarding secondary navigation reaches explicit destination callback")
        r.check(capture.contexts.last?.isCancelled == true, "accepted secondary navigation cancels actual trial")
        r.eq(navigationFlow.step, .introduction, "secondary settings navigation does not finish onboarding")
        view.cancel()
        r.check(capture.contexts.last?.isCancelled == true, "trial cancel button cancels actual presenter")
        capture.drain(); await wait { resources.owner == nil }
    }

    private static func trialConfigurationAndReadiness(_ r: SelfTest.Reporter, _ store: ConfigurationStore) async {
        print("--- OnboardingFlowSelfTests.trialConfigurationAndReadiness ---")
        let capture = Capture(), resources = SessionResourceCoordinator()
        let presenter = TrialSessionPresenter(configuration: store, resources: resources,
            refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { _ in },
            makeStages: { _ in [Stage(capture: { await capture.run($0) })] })
        let flow = OnboardingFlow(trial: presenter, navigation: SettingsNavigation(), onNavigate: { _ in }, onFinish: {})
        for _ in 0..<3 { flow.advance() }
        let noEngine = ReadinessMonitor(snapshot: snapshot(engine: .unavailable(reason: "fixture"), mic: .denied))
        var settingsDestinations: [ClientDestination] = []
        let settingsTrial = TrialSessionView(presenter: presenter, store: store, monitor: noEngine,
            configureEngine: { settingsDestinations.append(.settings(.speech)) })
        settingsTrial.start()
        for _ in 0..<10 { await Task.yield() }
        r.eq(settingsDestinations, [.settings(.speech)], "trial without engine directs settings to speech even if mic denied")
        r.eq(capture.contexts.count, 0, "trial without engine never enters capture")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }
        let onboardingTrial = TrialSessionView(presenter: presenter, store: store, monitor: noEngine,
            configureEngine: flow.configureEngine)
        onboardingTrial.start()
        r.eq(flow.step, .engine, "onboarding without engine returns to engine configuration despite mic denial")
        presenter.cancel(); capture.drain(); await wait { resources.owner == nil }

        let deniedMonitor = ReadinessMonitor(snapshot: snapshot(mic: .denied))
        let deniedPresenter = TrialSessionPresenter(configuration: store, resources: resources,
            refreshReadiness: { .blocked(.microphoneDenied) }, readinessLevel: { .blocked(.microphoneDenied) },
            copy: { _ in }, makeStages: { _ in [Stage(capture: { await capture.run($0) })] })
        let deniedTrial = TrialSessionView(presenter: deniedPresenter, store: store, monitor: deniedMonitor,
            configureEngine: flow.configureEngine)
        let beforeDenied = capture.contexts.count
        deniedTrial.start()
        for _ in 0..<10 { await Task.yield() }
        r.eq(capture.contexts.count, beforeDenied, "trial with denied microphone never enters capture")
        flow.advance(); flow.advance(); flow.back(); flow.back()
        r.eq(flow.step, .engine, "microphone denial leaves back/engine configuration navigation available")
        deniedTrial.cancel()

        store.current.triggerKey = .f14
        store.current.interactionMode = .toggle
        store.current.asrRoutingPolicy = .localOnly
        store.current.polishOnStop = true
        r.check(settingsTrial.triggerHint.contains("F14") && settingsTrial.triggerHint.contains("单击"),
                "trial hint uses current actual trigger and interaction mode")
        r.check(settingsTrial.transmissionDisclosure.contains("录音不发送") && settingsTrial.transmissionDisclosure.contains("转写文字"),
                "trial disclosure separates local ASR audio and cloud polish text")
        store.current.asrRoutingPolicy = .cloudOnly
        store.current.polishOnStop = false
        r.check(settingsTrial.transmissionDisclosure.contains("云端 ASR") && settingsTrial.transmissionDisclosure.contains("已关闭"),
                "trial disclosure follows cloud config and disabled polish")
        let degradedMonitor = ReadinessMonitor(snapshot: snapshot(ax: .denied))
        let degraded = TrialSessionPresenter(configuration: store, resources: resources,
            refreshReadiness: { .degraded(.accessibilityMissing) }, readinessLevel: { .degraded(.accessibilityMissing) },
            copy: { _ in }, makeStages: { _ in [Stage(capture: { await capture.run($0) })] })
        let degradedView = TrialSessionView(presenter: degraded, store: store, monitor: degradedMonitor, configureEngine: {})
        degradedView.start()
        r.check(degradedView.preparationText?.contains("结果留在这里") == true,
                "trial AX preparation explains result stays here")
        r.check(degradedView.preparationText?.contains("结果将复制") == false,
                "trial AX preparation never promises automatic copy")
        await wait { !capture.continuations.isEmpty }
        degradedView.cancel(); capture.drain(); await wait { resources.owner == nil }
    }
}
