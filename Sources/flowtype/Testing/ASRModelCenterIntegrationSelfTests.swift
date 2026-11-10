import Foundation
import Combine

/// Exercises the application composition with isolated persistence and synthetic recognition.
enum ASRModelCenterIntegrationSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testUserCancellation(r)
        await testExplicitHealthRecovery(r)
        await testWindowRecreationKeepsOwnership(r)
        await testRecoveryTargetsSpecificModel(r)
        await testLegacyEntryUsesSameSelection(r)
        await testClockCredentialAndSample(r)
        await testExpiredServiceRecordingPreflight(r)
        await testSavedServiceRuntimeCredentials(r)
        await testNativeSampleAndReservation(r)
    }
    @MainActor static func testUserCancellation(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment, actions = env.actions(navigation: nil)
        let before = f.store.current
        f.block = true
        let first = Task { await env.model.selectPrimary(f.id) }
        await f.waitForRecognition()
        let cancel = actions.currentOperation?()
        r.check(cancel != nil, "I2 production host exposes captured operation cancellation")
        cancel?.cancel()
        r.check(env.model.isBusy && env.validation.isTesting(profileID: f.service.id), "I2 cancelled service retains admission through real drain")
        await env.model.test(f.id)
        r.eq(f.calls, 1, "I2 draining service refuses overlapping transport")
        f.finish(); await first.value
        r.eq(f.store.current, before, "I2 user cancellation prevents late service selection and evidence persistence")
        r.check(env.model.currentValidatedServices.isEmpty && env.model.lastTrialResult == nil, "I2 cancellation cannot publish trial success")
        let second = Task { await env.model.test(f.id) }
        await f.waitForRecognition()
        cancel?.cancel()
        f.finish(); await second.value
        r.check(env.model.lastTrialResult != nil, "I2 old captured cancel cannot affect new operation")
    }
    @MainActor static func testExplicitHealthRecovery(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        f.store.current.setASRBackendSelection(.init(primary: f.id))
        let router = ASRRouter(startMonitoring: false, credentials: f.store.asrCredentials, persistNativeResolution: { _ in },
            configuration: { f.store.current }, localAvailable: { false }, localLease: { nil })
        f.beginHealthRecovery = { router.explicitRecoveryCompletion($0) }
        let route = await router.captureStartRoute(), binding = await router.captureStartRoute().bindings[0]
        for _ in 0..<2 { router.recordFailure(providerID: f.id.rawValue, route: route) }
        await f.environment.model.test(f.id)
        r.check(!router.backendHealth.isDegraded(binding: binding), "I1 production model-center Test repairs same service health")
        for _ in 0..<2 { router.recordFailure(providerID: f.id.rawValue, route: route) }
        f.block = true
        let trial = Task { await f.environment.model.selectPrimary(f.id) }
        await f.waitForRecognition()
        router.recordFailure(providerID: f.id.rawValue, route: route)
        f.finish(); await trial.value
        r.check(router.backendHealth.isDegraded(binding: binding), "I1 late explicit success cannot clear a newer real failure")
        let stale = router.explicitRecoveryCompletion(f.id)
        f.store.current.localASRServices[0].revision = UUID()
        stale?()
        r.check(router.backendHealth.isDegraded(binding: binding), "I1 old profile callback cannot clear route after revision change")
        f.block = false
        await f.environment.model.selectPrimary(f.id)
        r.eq(f.store.current.asrBackendSelection?.primary, f.id, "I1 explicit successful reselect keeps exact primary")
        let credentialID = "asr.service." + f.service.id.uuidString
        try? f.store.asrCredentials.write("fixture-old", id: credentialID)
        f.store.current.localASRServices[0].authentication = .bearer(credentialID: credentialID)
        let keyed = await router.captureStartRoute()
        for _ in 0..<2 { router.recordFailure(providerID: f.id.rawValue, route: keyed) }
        f.block = true
        let keyedTrial = Task { await f.environment.model.test(f.id) }
        await f.waitForRecognition()
        try? f.store.asrCredentials.write("fixture-new", id: credentialID)
        let replacement = await router.captureStartRoute()
        for _ in 0..<2 { router.recordFailure(providerID: f.id.rawValue, route: replacement) }
        f.finish(); await keyedTrial.value
        r.check(router.backendHealth.isDegraded(binding: keyed.bindings[0]) && router.backendHealth.isDegraded(binding: replacement.bindings[0]),
                "I1 stale credential trial clears neither old nor replacement credential health")
        r.check(f.environment.model.currentValidatedServices.isEmpty, "I1 credential edit invalidates explicit recovery evidence")
    }
    @MainActor static func testWindowRecreationKeepsOwnership(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment
        let first = SettingsWindowController.makeRootView(initialTab: .settings, navigation: .init(), connectionChecks: f.checks, modelCenter: env)
        f.block = true
        let operation = Task { await first.modelCenter?.model.test(f.id) }
        await f.waitForRecognition()
        let second = SettingsWindowController.makeRootView(initialTab: .settings, navigation: .init(), connectionChecks: f.checks, modelCenter: env)
        r.check(first.modelCenter === second.modelCenter, "testWindowRecreationKeepsOwnership: same application owner")
        r.check(second.modelCenter?.model.isBusy == true, "C4 reopened tab observes in-flight verification")
        await second.modelCenter?.model.test(f.id)
        r.eq(f.calls, 1, "C4 window recreation cannot duplicate recognition")
        f.finish(); await operation.value
        r.eq(second.modelCenter?.model.lastTrialResult?.backendID, f.id, "C4 recreated host receives original result")
        r.eq(f.store.current.asrServiceValidationRecords.count, 1, "C4 A5 callback and VM deduplicate history save")
    }
    @MainActor static func testRecoveryTargetsSpecificModel(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment
        env.focus(.asrBackend(f.id))
        r.eq(env.model.selectedID, f.id, "testRecoveryTargetsSpecificModel: disconnected service exact ID")
        env.focus(.asrBackend(.init(rawValue: "native:preset:" + ModelPreset.qwen306B.id)))
        r.eq(env.model.selectedID?.rawValue, "native:preset:" + ModelPreset.qwen306B.id, "C4 missing preset recovery targets preset")
        env.focus(.asrBackend(.init(rawValue: "service:" + UUID().uuidString)))
        r.eq(env.model.selectedID, nil, "C4 deleted recovery identity falls back to speech, never another row")
        let missing = ASRBackendID(rawValue: "service:" + UUID().uuidString)
        f.store.current.setASRBackendSelection(.init(primary: missing))
        env.focus(.asrBackend(missing))
        r.eq(env.model.selectedID, nil, "C4 selected deleted backend also falls back to speech")
        let fixture = HFInstallTransactionSelfTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let owner = ModelInstallationCoordinator(transport: { _, _, _, _ in throw HFDownloadError(code: .network) },
                publisher: .init(installedRoot: fixture.models, register: { _, _ in }), diskSample: { _ in .max }, journalRoot: fixture.jobs)
            let id = try await owner.enqueue(fixture.plan)
            await owner.cancel(jobID: id)
            let jobs = ASRModelCenterEnvironment(store: f.store, native: f.native, installer: owner,
                resources: f.resources, checks: f.checks, usage: f.usage, sample: { try f.sample() }, now: { f.date })
            await jobs.model.refreshInstallations()
            jobs.focus(.modelInstallation(id))
            r.eq(jobs.model.selectedInstallationID, id, "C4 download failure recovery targets exact job")
            jobs.focus(.modelInstallation(UUID()))
            r.eq(jobs.model.selectedInstallationID, nil, "C4 unknown job never targets another installation")
        } catch { r.check(false, "C4 recovery fixture: \(error)") }
    }
    @MainActor static func testLegacyEntryUsesSameSelection(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment
        env.focus(.provider(f.cloud.id))
        r.eq(env.model.selectedID, f.cloudID, "testLegacyEntryUsesSameSelection: legacy provider opens same row")
        let before = f.store.current.asrBackendSelection
        env.focus(.localModels)
        r.eq(f.store.current.asrBackendSelection, before, "C4 browsing legacy models never selects")
        await env.model.selectPrimary(f.id)
        r.eq(f.store.current.asrBackendSelection?.primary, f.id, "C4 shared model-center selection commits once")
        env.focus(.asrBackend(f.id))
        r.eq(env.model.selectedID, f.id, "C4 recovery and legacy host share selected backend")
    }
    @MainActor static func testClockCredentialAndSample(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment
        do {
            try f.store.asrCredentials.write("old", id: "asr.service." + f.service.id.uuidString)
            f.store.current.localASRServices[0].authentication = .bearer(credentialID: "asr.service." + f.service.id.uuidString)
            env.refresh()
            f.block = true
            let task = Task { await env.model.test(f.id) }
            await f.waitForRecognition()
            try f.store.asrCredentials.write("new", id: "asr.service." + f.service.id.uuidString)
            r.eq(f.capturedKey, "old", "C4 in-flight recognition retains atomic captured key")
            f.finish(); await task.value
            r.check(env.model.currentValidatedServices.isEmpty, "C4 edited credential invalidates late validation")
            f.block = false
            env.refresh()
            await env.model.test(f.id)
            r.eq(f.capturedKey, "new", "C4 next recognition captures new credential")
            r.eq(f.capturedSample?.sha256, try f.sample().sha256, "C4 VM receives canonical sample closure")
            r.eq(env.model.currentValidatedServices.first?.validatedAt, f.date, "C4 callback date remains authoritative")
            f.date.addTimeInterval(60)
            env.refresh()
            r.eq(env.model.rows.first(where: { $0.id == f.id })?.status, .previouslyValidated, "C4 clock expires visible readiness without another UI action")
            r.check(env.model.currentValidatedServices.isEmpty, "C4 clock cannot supply history to readiness")
            f.store.current.localASRServices[0].baseURL = "http://127.0.0.1:9124"
            f.store.current.localASRServices[0].revision = UUID()
            env.refresh()
            r.eq(env.model.rows.first(where: { $0.id == f.id })?.status, .installedUntested, "C4 edit refresh invalidates old evidence")
        } catch { r.check(false, "C4 snapshot fixture: \(error)") }
    }

    @MainActor static func testExpiredServiceRecordingPreflight(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment
        f.store.current.asrRoutingPolicy = .localOnly
        let router = ASRRouter(startMonitoring: false, internetAvailable: { false }, credentials: f.store.asrCredentials,
            persistNativeResolution: { _ in }, configuration: { f.store.current }, localAvailable: { false }, localLease: { nil })
        func snapshot(using source: ASRRouter? = nil, live: Bool = true, microphone: PermissionState = .granted, accessibility: PermissionState = .granted) -> ReadinessSnapshot {
            let availability = (source ?? router).readinessBackends(currentValidatedServices: live ? env.model.currentValidatedServices : [])
            return ReadinessSnapshotBuilder.make(config: f.store.current, modelStatus: .notLoaded,
                accessibility: accessibility, microphone: microphone, speechRecognition: .denied,
                networkReachable: false, appleAvailable: false, computedAt: f.date,
                backends: availability.backends, availableIDs: availability.availableIDs,
                attemptableServiceIDs: availability.attemptableServiceIDs)
        }
        r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), .noEngine,
             "I1 unselected configured service cannot admit recording")
        await env.model.selectPrimary(f.id)
        r.eq(f.calls, 1, "I1 selection requires one explicit sample Test")
        r.eq(snapshot().readyBackendIDs, [f.id], "I1 fresh success supplies live readiness")
        f.date.addTimeInterval(60)
        env.refresh()
        r.eq(env.model.rows.first(where: { $0.id == f.id })?.status, .previouslyValidated,
             "I1 expired service row is historical")
        r.check(env.model.currentValidatedServices.isEmpty, "I1 expiry revokes live evidence")
        r.eq(snapshot().readyBackendIDs, [], "I1 expiry never claims live ready")
        r.eq(classifyReadiness(snapshot()), .degraded(.serviceCheckOnUse), "I1 expired route has honest attempt-only presentation")
        let shown = ReadinessPresentation.make(snapshot: snapshot(), level: classifyReadiness(snapshot()))
        r.check(!shown.details.contains(ReadinessIssue.noEngine.reason), "I1 settings does not contradict permitted attempt with no-engine issue")
        r.check(shown.details.contains(ReadinessIssue.serviceCheckOnUse.reason), "I1 settings explains service check on real use")
        r.check(!readinessMenuTitle(snapshot(accessibility: .denied)).contains("已就绪"),
                "I1 missing accessibility must not relabel an unverified service as ready")
        r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), nil,
             "I1 expiry alone must allow real recording preflight")
        r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot(microphone: .denied))), .microphoneDenied,
             "I1 admitted service does not bypass microphone blocker")
        r.eq((await router.captureStartRoute()).bindings.first?.descriptor.id, f.id,
             "I1 expired selection captures actual service for runtime attempt")
        r.eq(f.calls, 1, "I1 expiry refresh and preflight perform no hidden sample recognition")
        f.store.current.asrRoutingPolicy = .cloudOnly
        r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), .noEngine,
             "I1 service attempt cannot bypass cloud-only policy")
        f.store.current.asrRoutingPolicy = .localOnly
        f.store.current.localASRServices[0].baseURL = "http://127.0.0.1:9124"
        env.refresh()
        r.check(env.model.currentValidatedServices.isEmpty, "I1 exact profile edit without revision rotation revokes live evidence")
        r.eq(snapshot().readyBackendIDs, [], "I1 edited selected profile is not live verified")
        r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), nil,
             "I1 valid edited explicit selection can attempt a real request")
        await env.model.test(f.id)
        f.date.addTimeInterval(60)
        env.refresh()
        r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), nil,
             "I1 retested selection remains attemptable beyond freshness")
        do {
            let draft = LocalASRServiceDraft(target: .existing(f.service.id), profile: f.store.current.localASRServices[0], keyEdit: .replace("new-key"))
            try env.actions(navigation: nil).saveLocal!(draft)
            r.check(env.model.currentValidatedServices.isEmpty, "I1 saved credential edit revokes verification evidence")
            r.eq(snapshot().readyBackendIDs, [], "I1 changed credential is not live verified")
            r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), nil,
                 "I1 explicit selection with new valid credentials can attempt")
            let persisted = try JSONEncoder().encode(f.store.current)
            f.store.current = try JSONDecoder().decode(Configuration.self, from: persisted)
            let restarted = ASRRouter(startMonitoring: false, internetAvailable: { false }, credentials: f.store.asrCredentials,
                persistNativeResolution: { _ in }, configuration: { f.store.current }, localAvailable: { false }, localLease: { nil })
            r.eq(snapshot(using: restarted, live: false).readyBackendIDs, [], "I1 restart selection/history never becomes live ready")
            r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot(using: restarted, live: false))), nil,
                 "I1 persisted explicit selection may attempt after restart without another sample")
            var lockedAccess = ASRCredentialAccess.memory()
            lockedAccess.read = { _ in throw ASRCredentialError.unavailable }
            let locked = ASRRouter(startMonitoring: false, internetAvailable: { false },
                credentials: KeychainASRCredentialStore(access: lockedAccess), configuration: { f.store.current },
                localAvailable: { false }, localLease: { nil })
            r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot(using: locked))), .noEngine,
                 "I1 credential lookup failure still blocks recording")
            f.store.current.localASRServices[0].baseURL = "https://remote.invalid/v1"
            r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), .noEngine,
                 "I1 invalid nonloopback profile cannot admit recording")
            f.store.current.localASRServices[0].baseURL = "http://127.0.0.1:9124"
            f.store.current.setASRBackendSelection(.init(primary: .init(rawValue: "service:unknown")))
            r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), .noEngine,
                 "I1 unknown selection cannot adopt configured unrelated service")
            f.store.current.setASRBackendSelection(.init())
            r.eq(SessionController.readinessPreflight(classifyReadiness(snapshot())), .noEngine,
                 "I1 cleared selection cannot adopt historical configured service")
            r.eq(f.calls, 2, "I1 restart and invalid routes perform no implicit recognition")
        } catch { r.check(false, "I1 isolated credential edit: \(error)") }
    }

    @MainActor static func testSavedServiceRuntimeCredentials(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let env = f.environment
        let router = ASRRouter(startMonitoring: false, internetAvailable: { false }, credentials: f.store.asrCredentials,
            persistNativeResolution: { _ in }, configuration: { f.store.current }, localAvailable: { false }, localLease: { nil })
        await env.model.selectPrimary(f.id)
        r.eq(router.readinessBackends(currentValidatedServices: env.model.currentValidatedServices).availableIDs, [f.id], "C4 anonymous VM evidence reaches actual router readiness")
        do {
            let draft = LocalASRServiceDraft(target: .existing(f.service.id), profile: f.store.current.localASRServices[0], keyEdit: .replace("version-one"))
            try env.actions(navigation: nil).saveLocal!(draft)
            env.refresh()
            await env.model.test(f.id)
            r.eq(f.capturedKey, "version-one", "C4 saved versioned credential reaches VM test")
            r.eq(router.readinessBackends(currentValidatedServices: env.model.currentValidatedServices).availableIDs, [f.id], "C4 saved versioned service reaches readiness")
            let route = await router.captureStartRoute()
            let captured = route.bindings.first?.provider as? LocalServiceASRProvider
            r.eq(captured?.credential, "version-one", "C4 recording binding captures saved exact credential")
            let newer = LocalASRServiceDraft(target: .existing(f.service.id), profile: f.store.current.localASRServices[0], keyEdit: .replace("version-two"))
            try env.actions(navigation: nil).saveLocal!(newer)
            env.refresh()
            r.eq(captured?.credential, "version-one", "C4 in-flight recording retains old profile and key")
            let next = await router.captureStartRoute()
            r.eq((next.bindings.first?.provider as? LocalServiceASRProvider)?.credential, "version-two", "C4 next recording captures new version")
            r.check(env.model.currentValidatedServices.isEmpty, "C4 save invalidates readiness before next explicit trial")
            for forged in ["asr.hf.official", "asr.cloud." + UUID().uuidString, "asr.service." + UUID().uuidString, "asr.service." + f.service.id.uuidString + ".bad"] {
                f.store.current.localASRServices[0].authentication = .bearer(credentialID: forged)
                r.check((try? ASRModelCenterEnvironment.credential(f.id, store: f.store)) == nil, "C4 foreign service credential rejected by editor and VM")
                r.check((await router.captureStartRoute()).bindings.isEmpty, "C4 foreign service credential rejected by recording")
            }
        } catch { r.check(false, "C4 saved service integration: \(error)") }
    }

    @MainActor static func testNativeSampleAndReservation(_ r: SelfTest.Reporter) async {
        let f = Fixture(); defer { f.cleanup() }
        let model = NativeActivationFixtures.model(f.root.appendingPathComponent("synthetic-native"))
        f.store.current.importedASRModels = [model]
        let recorder = SampleRecorder()
        let native = QwenModelState(preflight: { _, _ in }, load: { _, _, _ in
            LocalASRLease(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name,
                engine: model.engine.rawValue, repoID: nil, directory: model.directory), provider: recorder)
        }, configuration: { f.store.current }, localModel: { _ in nil }, environment: .init(read: { nil }, write: { _ in }),
            inspect: { _ in model }, assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: 10) },
            persistActivation: { try f.store.commitNativeASRActivation($0) },
            sampleProvider: { try ASRApplicationModelDependencies.sample(store: f.store) }, usageRegistry: f.usage,
            canUnload: { ASRApplicationModelDependencies.canUnload(resources: f.resources) })
        do {
            try await native.useImportedModel(model)
            let expected = try ASRApplicationModelDependencies.sample(store: f.store)
            r.eq(await recorder.samples, expected.samples, "C4 legacy native activation uses same bundled canonical sample")
            r.check(native.activeLease != nil, "C4 native legacy activation completes validated load")
            var admissionAtWillSet: Bool?
            let observation = f.resources.$owner.dropFirst().sink { _ in admissionAtWillSet = ASRApplicationModelDependencies.canUnload(resources: f.resources) }
            let token = f.resources.acquire(owner: UUID())!
            r.eq(admissionAtWillSet, false, "C4 unload permission reads actual reservation before published owner changes")
            do { try await native.unloadCurrentAfterDrain(); r.check(false, "C4 recording reservation denies unload") }
            catch { r.check(native.activeLease != nil, "C4 denied unload preserves native owner") }
            f.resources.release(token: token)
            var captured: LocalASRLease? = try native.activeLease?.captured()
            r.check(captured != nil, "C4 native capture fixture owns lease")
            do { try await native.unloadCurrentAfterDrain(); r.check(false, "C4 captured resource denies unload after recording reservation ends") }
            catch { r.check(native.activeLease != nil, "C4 capture guard preserves native owner") }
            captured = nil
            try await native.unloadCurrentAfterDrain()
            r.eq(native.activeLease, nil, "C4 actual release permits unique-owner unload")
            withExtendedLifetime(observation) {}
            var locked = ASRCredentialAccess.memory(); locked.read = { _ in throw ASRCredentialError.unavailable }
            let anonymous = try f.service.credentialSnapshot(store: KeychainASRCredentialStore(access: locked))
            r.eq(anonymous.value, nil, "C4 anonymous service does not require reading unused Keychain value")
        } catch { r.check(false, "C4 native composition fixture: \(error)") }
    }
    actor SampleRecorder: ASRProvider {
        nonisolated let id = "c4-native", displayName = "synthetic"
        nonisolated let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: false, location: .onDevice)
        var isAvailable: Bool { true }
        var samples: [Float] = []
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            samples = request.samples
            return .init(text: "synthetic native transcript", providerID: id, latencyMs: 1)
        }
    }

    @MainActor final class Fixture {
        let suite = "flowtype-c4-" + UUID().uuidString
        let defaults: UserDefaults
        let store: ConfigurationStore
        let root: URL
        let resources = SessionResourceCoordinator(), usage = NativeModelUsageRegistry()
        var date = Date(timeIntervalSince1970: 1000), calls = 0, block = false
        var capturedKey: String?, capturedSample: ASRValidationSample?
        var beginHealthRecovery: (ASRBackendID) -> (() -> Void)? = { _ in nil }
        var continuation: CheckedContinuation<Void, Never>?
        let service = LocalASRServicePreset.whisperCpp.makeProfile(baseURL: "http://127.0.0.1:9123", modelID: nil)
        let cloud = CloudASRProviderConfig(name: "Fixture cloud", provider: "custom", baseURL: "https://fixture.invalid/v1", model: "fixture")
        var id: ASRBackendID { .init(rawValue: "service:" + service.id.uuidString) }
        var cloudID: ASRBackendID { .init(rawValue: "cloud:" + cloud.id.uuidString) }
        lazy var checks = SettingsConnectionChecks(configuration: store, checks: .init(), draftChecks: .init())
        lazy var native = QwenModelState(configuration: { [self] in store.current }, localModel: { _ in nil },
            environment: .init(read: { nil }, write: { _ in }), usageRegistry: usage, canUnload: { [self] in resources.owner == nil })
        lazy var installer = ModelInstallationCoordinator(transport: { _, _, _, _ in throw HFDownloadError(code: .network) },
            publisher: .init(installedRoot: root.appendingPathComponent("installed"), register: { _, _ in }),
            diskSample: { _ in .max }, journalRoot: root.appendingPathComponent("installation-jobs"), usageRegistry: usage)
        lazy var environment = ASRModelCenterEnvironment(store: store, native: native, installer: installer,
            resources: resources, checks: checks, usage: usage, sample: { [self] in try sample() }, now: { [self] in date },
            beginHealthRecovery: { [self] in beginHealthRecovery($0) },
            makeValidation: { [self] callback in .init(resolver: { _ in ["127.0.0.1"] }, now: { [self] in date }, onVerified: callback,
                serviceRecognition: { [self] _, key, sample in
                    calls += 1; capturedKey = key; capturedSample = sample
                    if block { await withCheckedContinuation { continuation = $0 } }
                    return "synthetic integration transcript"
                }, cloudRecognition: { _, _, _ in "synthetic cloud transcript" }) })
        func sample() throws -> ASRValidationSample { try ASRValidationSampleStore.load(language: store.current.asrLanguage) }
        init() {
            defaults = UserDefaults(suiteName: suite)!
            store = ConfigurationStore(defaults: defaults, asrCredentials: KeychainASRCredentialStore(access: .memory()), persistence: { [defaults] in defaults.set($0, forKey: "flowtype.config") })
            root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent(suite)
            store.current.localASRServices = [service]; store.current.cloudASRConfig.providers = [cloud]
            store.current.setASRBackendSelection(.init())
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func waitForRecognition() async { for _ in 0..<10_000 { if continuation != nil { return }; await Task.yield() } }
        func finish() { let c = continuation; continuation = nil; c?.resume() }
    }
}
