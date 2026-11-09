import Foundation

/// Real coordinator/configuration/router/stage boundaries; only inspection and model compute are replaced.
enum ImportedLifecycleSelfTests {
    private static let gib: UInt64 = 1_073_741_824
    private static func model(_ engine: LocalASREngine, name: String) -> ImportedASRModel {
        .init(name: name, directory: URL(fileURLWithPath: "/fixture/imported/" + name), engine: engine,
              variant: engine == .qwenMLX ? "0.6B" : "unverified", bits: engine == .qwenMLX ? 4 : nil,
              sizeBytes: 1234, tokenizerDirectory: URL(fileURLWithPath: "/fixture/imported/" + name),
              fileFingerprint: "fixture-fresh", minimumResidentBytes: engine == .qwenMLX ? gib / 2 : nil)
    }

    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        hardware(r)
        let qwen = model(.qwenMLX, name: "Qwen")
        let whisper = model(.whisperCoreML, name: "Whisper")
        let models = [qwen, whisper]
        let suite = "flowtype-imported-lifecycle-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { r.check(false, "imported fixture defaults"); return }
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        var initial = Configuration()
        initial.hasCompletedOnboarding = true
        initial.asrRoutingPolicy = .localOnly
        var oldDescriptor = qwen; oldDescriptor.minimumResidentBytes = nil
        initial.importedASRModels = [oldDescriptor, whisper]
        initial.activeImportedASRModelID = qwen.id
        initial.selectedLocalModelID = ModelPreset.qwen317B.id // stale legacy fields must not win
        initial.localModelPath = "/fixture/legacy-conflict"
        store.save(initial)
        let probe = ImportedLifecycleProbe()
        var saves = 0
        func makeState(_ io: ImportedLifecycleProbe) -> QwenModelState {
            QwenModelState(preflight: { _, _ in await io.preflight() }, load: { target, offline, _ in
                try await io.load(target, offline: offline)
            }, configuration: { store.current }, localModel: { _ in nil }, availableDisk: { _ in .max },
                environment: .init(read: { nil }, write: { _ in }), inspect: { directory in
                    guard let value = models.first(where: { $0.directory == directory }) else { throw ModelProvisionError.incompleteLocal() }
                    return value
                }, assessHardware: { model, active in
                    .assess(model: model, physicalMemory: 32 * gib, availableMemory: 16 * gib,
                            activeModelBytes: active, isAppleSilicon: true)
                }, saveConfiguration: { saves += 1; store.save($0) })
        }
        let state = makeState(probe)
        await state.loadModel()
        let oldLease = state.activeLease
        r.eq(oldLease?.identity.id, qwen.id.uuidString, "imported restart honors active UUID over stale preset and legacy path")
        r.eq(await probe.preflights, 0, "imported restart must never preflight a preset")
        r.eq(await probe.offlineValues, [true], "imported restart restores only active item strictly offline")
        r.eq(saves, 1, "successful restore commits configuration once")
        r.eq(oldLease?.minimumResidentBytes, gib / 2, "legacy descriptor refresh populates known reservation before runtime")
        r.eq(store.current.localModelPath, nil, "successful imported transaction clears legacy alias")
        r.eq(store.current.selectedLocalModelID, nil, "successful imported transaction clears preset selection")

        let router = ASRRouter(startMonitoring: false, configuration: { store.current },
            localAvailable: { state.activeLease != nil }, localLease: { state.activeLease })
        let captured = await router.captureStartRoute()
        let before = store.current
        await probe.setMode(.failure)
        try? await state.useImportedModel(whisper)
        r.eq(state.activeLease, oldLease, "Qwen to Whisper failure retains old lease")
        r.eq(store.current, before, "Qwen to Whisper failure preserves entire configuration")
        r.eq(saves, 1, "failed imported candidate never commits")
        r.check(!state.didAutoFallback, "failed imported restore must never fall back to preset")
        let availability = router.readinessBackends()
        let readiness = ReadinessSnapshotBuilder.make(config: store.current, modelStatus: state.status,
            accessibility: .granted, microphone: .granted, speechRecognition: .granted,
            networkReachable: false, appleAvailable: false, computedAt: Date(), backends: availability.backends, availableIDs: availability.availableIDs)
        r.eq(classifyReadiness(readiness), .ready, "candidate failure with old local lease remains ready")

        await probe.setMode(.suspended)
        let cancelled = Task { try await state.useImportedModel(whisper) }
        await waitForPending(probe, r)
        state.cancel()
        r.check(state.operationID != nil, "cancelled import keeps gate ownership until loader drains")
        r.eq(store.current, before, "pending and cancelled import has no configuration side effects")
        await probe.finish()
        _ = try? await cancelled.value
        r.eq(state.activeLease, oldLease, "cancelled late Whisper completion cannot replace Qwen")
        r.eq(store.current, before, "cancelled late completion preserves configuration")
        r.eq(saves, 1, "cancelled import never commits")

        // The failed descriptor is retried as an import, never reinterpreted as a preset.
        let actions = ModelRecoveryActions(coordinator: state, store: store)
        await probe.setMode(.suspended)
        var duplicate = whisper; duplicate.id = UUID(); duplicate.fileFingerprint = "stale"
        let successful = Task { try await state.useImportedModel(duplicate) }
        await waitForPending(probe, r)
        store.current.asrLanguage = .en
        await probe.finish()
        _ = try? await successful.value
        let newLease = state.activeLease
        r.eq(newLease?.identity.engine, LocalASREngine.whisperCoreML.rawValue, "successful replacement carries real engine")
        r.eq(newLease?.identity.id, whisper.id.uuidString, "duplicate directory canonical UUID is assigned before lease creation")
        r.eq(store.current.activeImportedASRModelID, whisper.id, "success commits canonical active ID")
        r.eq(store.current.importedASRModels.count, 2, "duplicate import updates library without extra row")
        r.eq(store.current.importedASRModels.first { $0.id == whisper.id }?.variant, "small", "only successful verified Whisper graph family persists")
        r.eq(store.current.customLocalModelPath, nil, "Whisper selection cannot masquerade as legacy Qwen path")
        r.eq(saves, 2, "one successful replacement makes one central save")
        r.eq(store.current.asrLanguage, .en, "successful transaction reads latest config and preserves concurrent settings edits")
        if case .imported(let loaded) = (await probe.targets).last {
            r.eq(loaded.fileFingerprint, "fixture-fresh", "stale selection is reinspected before loading")
            r.eq(loaded.variant, "unverified", "static Whisper inspection does not invent verified runtime metadata")
        } else { r.check(false, "imported candidate reaches injected runtime") }

        let stage = FixtureASRStage(healthRecorder: { _, _, _ in }, providerForID: { _ in nil })
        let first = SessionContext(sessionID: 9301); first.captureRoute = captured
        _ = await stage.execute(payload: .audio(samples: [0.25, -0.5, 0.75], previewText: ""), context: first)
        r.eq(first.rawTranscript, "qwenMLX:3", "recording captured before switch retains Qwen provider")
        let next = SessionContext(sessionID: 9302); next.captureRoute = await router.captureStartRoute()
        _ = await stage.execute(payload: .audio(samples: [0.25, -0.5], previewText: ""), context: next)
        r.eq(next.rawTranscript, "whisperCoreML:2", "new recording captures Whisper provider")
        r.eq(SessionController.backendLabel(forProviderID: next.usedProviderID, localIdentity: next.captureRoute?.localLease?.identity),
             "whisperCoreML", "history derives Whisper identity from capture lease")

        store.flushPendingSave()
        let restartedStore = ConfigurationStore(defaults: defaults)
        r.eq(restartedStore.current.activeImportedASRModelID, whisper.id, "active import survives configuration restart")
        let restoredProbe = ImportedLifecycleProbe()
        let restored = makeState(restoredProbe)
        await restored.loadModel()
        r.eq(restored.activeLease?.identity.id, whisper.id.uuidString, "persisted verified Whisper reinspection accepts static unverified variant")
        r.eq(await restoredProbe.offlineValues, [true], "Whisper restart performs one offline load")
        r.eq(await restoredProbe.preflights, 0, "Whisper restart has zero network preflight")

        await probe.setMode(.failure)
        let count = (await probe.targets).count
        try? await state.useImportedModel(qwen)
        try? await actions.retry()
        r.eq((await probe.targets).count, count + 2, "failed custom retry makes exactly one attempt each")
        r.eq(await probe.preflights, 0, "custom retry never falls through to preset network")
        r.eq(store.current.activeImportedASRModelID, whisper.id, "failed retry leaves active Whisper selected")

        state.removeImportedModel(id: whisper.id)
        r.eq(state.activeLease, newLease, "removing active library row preserves usable lease")
        r.eq(store.current.activeImportedASRModelID, nil, "removing active row clears durable intent")
        r.eq(store.current.customLocalModelPath, nil, "removing library row clears legacy aliases")
        let retained = SessionContext(sessionID: 9303); retained.captureRoute = next.captureRoute
        _ = await stage.execute(payload: .audio(samples: [0.25], previewText: ""), context: retained)
        r.eq(retained.rawTranscript, "whisperCoreML:1", "removed library row cannot invalidate an existing capture")
        store.flushPendingSave()
        r.eq(ConfigurationStore(defaults: defaults).current.activeImportedASRModelID, nil, "removed active import stays removed after restart")

        // A legacy path is inspected and migrated only on successful runtime ownership.
        var legacy = Configuration(); legacy.localModelPath = qwen.directory.path
        store.save(legacy)
        let legacyProbe = ImportedLifecycleProbe(); await legacyProbe.setMode(.failure)
        let legacyState = makeState(legacyProbe)
        await legacyState.loadModel()
        r.eq(store.current, legacy, "failed legacy load does not migrate configuration")
        await legacyProbe.setMode(.success)
        await legacyState.retryConfiguredModel()
        r.check(store.current.activeImportedASRModelID != nil, "successful legacy load migrates active library item")
        r.eq(store.current.customLocalModelPath, qwen.directory.path, "successful legacy Qwen migration preserves selected path")
        r.eq(store.current.localModelPath, nil, "successful legacy migration clears old alias")

        // Explicit preset selection must clear imported intent only after success.
        let selected = store.current
        await legacyProbe.setMode(.failure)
        await legacyState.selectPreset(.qwen306B)
        r.eq(store.current, selected, "failed explicit preset switch preserves imported selection")
        await legacyProbe.setMode(.success)
        await legacyState.selectPreset(.qwen306B)
        r.eq(store.current.activeImportedASRModelID, nil, "successful explicit preset clears imported active reference")
        r.eq(store.current.selectedLocalModelID, ModelPreset.qwen306B.id, "successful preset switch persists chosen preset")
        r.eq(store.current.customLocalModelPath, nil, "successful preset switch clears imported legacy alias")
        r.check(!store.current.importedASRModels.isEmpty, "switching to preset retains library records")

        let unavailableProbe = ImportedLifecycleProbe()
        let blocked = QwenModelState(preflight: { _, _ in await unavailableProbe.preflight() }, load: { target, offline, _ in
            try await unavailableProbe.load(target, offline: offline)
        }, configuration: { store.current }, localModel: { _ in nil }, inspect: { _ in qwen },
            assessHardware: { model, old in
                .assess(model: model, physicalMemory: 8 * gib, availableMemory: 1, activeModelBytes: old, isAppleSilicon: true)
            }, saveConfiguration: { store.save($0) })
        let beforeBlock = store.current
        try? await blocked.useImportedModel(qwen)
        r.eq(await unavailableProbe.targets, [], "resource rejection happens before candidate runtime construction")
        r.eq(await unavailableProbe.preflights, 0, "resource rejection never preflights")
        r.eq(store.current, beforeBlock, "resource rejection cannot change selection or library")
        r.check(blocked.importFailureDetail?.contains("预算") == true, "resource rejection explains admission reservation")

        var brokenSelection = store.current; brokenSelection.activeImportedASRModelID = UUID()
        store.save(brokenSelection)
        let missingProbe = ImportedLifecycleProbe()
        let missing = makeState(missingProbe)
        await missing.loadModel()
        r.eq(await missingProbe.targets, [], "missing active UUID never loads an unrelated library or preset item")
        r.eq(await missingProbe.preflights, 0, "missing active UUID never silently downloads")
        r.eq(missing.failure, .incompleteLocal(), "missing active UUID reports recoverable explicit intent")

        let invalidProbe = ImportedLifecycleProbe()
        let invalid = makeState(invalidProbe)
        let invalidActions = ModelRecoveryActions(coordinator: invalid, store: store)
        try? await invalidActions.importOfflineModel(at: URL(fileURLWithPath: "/fixture/missing-import"))
        try? await invalidActions.retry()
        r.eq(await invalidProbe.targets, [], "invalid custom inspection retry remains custom without preset fallback")
        r.eq(await invalidProbe.preflights, 0, "invalid custom inspection retry performs no network")
        r.eq(store.current, brokenSelection, "invalid static inspection never changes configuration")

        let presetProbe = ImportedLifecycleProbe()
        let offlinePreset = makeState(presetProbe)
        let resolvedPreset = ResolvedModel(directory: URL(fileURLWithPath: "/fixture/installed-preset"), modelId: ModelPreset.qwen306B.repoId)
        await presetProbe.setMode(.failure)
        await offlinePreset.perform(.init(target: .offline(resolvedPreset), source: .official, origin: .manual))
        try? await ModelRecoveryActions(coordinator: offlinePreset, store: store).retry()
        r.eq(await presetProbe.targets, [.offline(resolvedPreset), .offline(resolvedPreset)],
             "installed preset recovery remains offline preset rather than becoming a custom library import")
        r.eq(store.current, brokenSelection, "failed offline preset retry cannot migrate library")
    }

    private static func hardware(_ r: SelfTest.Reporter) {
        var small = model(.qwenMLX, name: "hardware")
        func assess(_ model: ImportedASRModel, physical: UInt64 = 16 * gib, available: UInt64? = 8 * gib,
                    old: UInt64? = nil, silicon: Bool = true) -> LocalModelHardwareAssessment {
            .assess(model: model, physicalMemory: physical, availableMemory: available, activeModelBytes: old, isAppleSilicon: silicon)
        }
        r.eq(assess(small).recommendedMinimumMemory, 4 * gib, "0.6B 4-bit retains 4 GiB product recommendation")
        small.variant = "1.7B"
        r.eq(assess(small).recommendedMinimumMemory, 8 * gib, "1.7B 4-bit retains 8 GiB product recommendation")
        r.eq(assess(small, physical: 4 * gib).compatibility, .warning, "below recommendation alone is not a proven hard failure")
        small.bits = 8
        r.eq(assess(small).recommendedMinimumMemory, nil, "8-bit peak recommendation stays unknown")
        r.eq(assess(small, silicon: false).compatibility, .incompatible, "MLX rejects other architecture")
        let intelWhisper = assess(model(.whisperCoreML, name: "coreml"), silicon: false)
        r.eq(intelWhisper.compatibility, .incompatible, "Whisper rejects pinned runtime Intel cache ABI")
        r.check(intelWhisper.explanation.contains("WhisperKit 0.18") && intelWhisper.explanation.contains("不是 Core ML"), "Whisper Intel explanation distinguishes runtime from format")
        r.eq(assess(model(.whisperCoreML, name: "coreml")).compatibility, .warning, "Whisper Apple Silicon retains unknown memory warning")
        r.eq(assess(small, available: nil).compatibility, .warning, "unknown available memory is honest warning")
        r.eq(assess(small, available: gib / 4).compatibility, .incompatible, "candidate below packed-weight reservation is blocked")
        r.eq(assess(small, physical: gib, available: gib, old: gib).compatibility, .incompatible, "old plus candidate reservation over physical budget blocks")
        r.eq(assess(small, old: .max).compatibility, .incompatible, "combined reservation arithmetic is overflow safe")
        small.minimumResidentBytes = nil; small.sizeBytes = Int64.max
        r.eq(assess(small).compatibility, .warning, "unknown residency never treats directory bytes as measured RAM")
        r.check(assess(small).explanation.contains("未实测"), "unknown peak is explicit")
    }

    @MainActor
    private static func waitForPending(_ probe: ImportedLifecycleProbe, _ r: SelfTest.Reporter) async {
        for _ in 0..<1000 {
            if await probe.pending { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        r.check(false, "imported fixture reached suspended runtime within deadline")
    }
}

private actor ImportedLifecycleProbe {
    enum Mode { case success, failure, suspended }
    var mode: Mode = .success
    var preflights = 0
    var targets: [ModelProvisionTarget] = []
    var offlineValues: [Bool] = []
    var pending: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?
    func preflight() { preflights += 1 }
    func setMode(_ value: Mode) { mode = value }
    func finish() { continuation?.resume(); continuation = nil }
    func load(_ target: ModelProvisionTarget, offline: Bool) async throws -> LocalASRLease {
        targets.append(target); offlineValues.append(offline)
        if mode == .failure { throw ModelProvisionError.loadFailed() }
        if mode == .suspended { await withCheckedContinuation { continuation = $0 } }
        switch target {
        case .imported(let model):
            let metadata = model.engine == .whisperCoreML ? try WhisperRuntimeMetadata(logitsSize: 51865, encoderSize: 768, decoderSize: 768) : nil
            return .init(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name,
                engine: model.engine.rawValue, repoID: nil, directory: model.directory),
                provider: ImportedSpeechFixture(name: model.engine.rawValue), whisperMetadata: metadata,
                minimumResidentBytes: model.minimumResidentBytes)
        case .preset(let preset):
            return .init(id: UUID(), identity: .init(id: preset.id, displayName: preset.name, engine: "qwen",
                repoID: preset.repoId, directory: URL(fileURLWithPath: "/fixture/preset")), provider: ImportedSpeechFixture(name: "preset"))
        case .offline, .uninspectedDirectory: throw ModelProvisionError.incompleteLocal()
        }
    }
}

private actor ImportedSpeechFixture: ASRProvider {
    nonisolated let id = ASRProviderID.local
    nonisolated let displayName: String
    nonisolated let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false,
        requiresNetwork: false, location: .onDevice)
    var isAvailable: Bool { true }
    init(name: String) { displayName = name }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        .init(text: "\(displayName):\(request.samples.count)", providerID: id, latencyMs: 1)
    }
}
