import Foundation

enum WholeM2FixSelfTests {
    @MainActor
    static func runGraphAdmission(_ r: SelfTest.Reporter) async {
        let suite = "flowtype-graph-admission-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { r.check(false, "graph admission defaults"); return }
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        let model = ImportedASRModel(name: "bad-graph", directory: URL(fileURLWithPath: "/fixture/bad-graph"),
            engine: .whisperCoreML, variant: "unverified", sizeBytes: 1,
            tokenizerDirectory: URL(fileURLWithPath: "/fixture/bad-graph"), fileFingerprint: "fixture")
        for rankFailure in [true, false] {
            var malformed = WhisperGraphFixtures.decoder
            if rankFailure { malformed.outputs["logits"]?.shape = [51865] }
            else { malformed.inputs["encoder_output_embeds"]?.shape = [1,768,1,100] }
            let graph = malformed
            let probe = RetryIntentProbe()
            await probe.repairSmall()
            let state = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in
                if case .imported = target {
                    let metadata = try WhisperGraphContract.validate(mel: WhisperGraphFixtures.mel, encoder: WhisperGraphFixtures.encoder,
                        decoder: graph, prefill: nil)
                    return LocalASRLease(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name,
                        engine: model.engine.rawValue, repoID: nil, directory: model.directory),
                        provider: NativeActivationFixtures.Provider(), whisperMetadata: metadata)
                }
                return try await probe.load(target)
            }, configuration: { store.current }, localModel: { _ in nil }, availableDisk: { _ in .max },
                environment: .init(read: { nil }, write: { _ in }), inspect: { directory in directory == model.directory ? model : NativeActivationFixtures.model(directory) },
                assessHardware: { _, _ in .init(compatibility: .warning, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: nil) },
                saveConfiguration: { store.save($0) },
                persistActivation: { try store.commitNativeASRActivation($0) }, sampleProvider: NativeActivationFixtures.sample)
            await state.selectPreset(.qwen306B)
            let previous = state.activeLease
            let before = store.current
            do { try await ModelRecoveryActions(coordinator: state, store: store).importOfflineModel(at: model.directory); r.check(false, "invalid graph admission fails") }
            catch { r.check(true, "invalid graph admission fails") }
            r.eq(state.activeLease, previous, "invalid rank/interface graph cannot replace old ready lease")
            r.eq(store.current, before, "invalid rank/interface graph cannot commit selection")
            r.eq(state.activeLease?.whisperMetadata, nil, "invalid graph never becomes verified Whisper lease")
        }
    }

    @MainActor
    static func runRetry(_ r: SelfTest.Reporter) async {
        let suite = "flowtype-retry-intent-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { r.check(false, "retry defaults"); return }
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        var config = Configuration()
        config.hasCompletedOnboarding = true
        config.selectedLocalModelID = nil
        config.downloadSource = .custom("https://original.invalid")
        store.save(config)
        let probe = RetryIntentProbe()
        func state(_ configStore: ConfigurationStore, installed: Bool = false) -> QwenModelState {
            QwenModelState(preflight: { preset, source in await probe.preflight(preset, source) },
                load: { target, _, _ in try await probe.load(target) }, configuration: { configStore.current },
                localModel: { config in
                    guard installed, config.selectedLocalModelID == nil || config.selectedLocalModelID == ModelPreset.qwen306B.id else { return nil }
                    return ResolvedModel(directory: URL(fileURLWithPath: "/fixture/" + ModelPreset.qwen306B.id), modelId: ModelPreset.qwen306B.repoId)
                }, availableDisk: { _ in .max }, environment: .init(read: { nil }, write: { _ in }),
                inspect: { NativeActivationFixtures.model($0) },
                assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: nil) },
                saveConfiguration: { configStore.save($0) },
                persistActivation: { try configStore.commitNativeASRActivation($0) }, sampleProvider: NativeActivationFixtures.sample)
        }
        let automatic = state(store)
        await automatic.selectPreset(.qwen317B, automatic: true)
        r.eq(await probe.attempts, [ModelPreset.qwen317B.id, ModelPreset.qwen306B.id], "retry automatic initial failure attempts primary then fallback")
        r.eq(automatic.target, .preset(.qwen306B), "retry failure presentation retains actual fallback target")
        r.eq(store.current.selectedLocalModelID, nil, "retry failed fallback preserves automatic config")
        config = store.current; config.downloadSource = .custom("https://repaired.invalid"); store.save(config)
        await probe.repairSmall()
        do { try await ModelRecoveryActions(coordinator: automatic, store: store).retry() }
        catch { r.check(false, "ordinary automatic retry succeeds: \(error)") }
        r.eq(Array((await probe.attempts).suffix(2)), [ModelPreset.qwen317B.id, ModelPreset.qwen306B.id], "retry starts original automatic primary and still falls back")
        r.check(automatic.didAutoFallback, "retry automatic fallback is reported")
        r.eq(automatic.activeLease?.identity.id, ModelPreset.qwen306B.id, "retry activates actual fallback lease")
        r.eq(store.current.selectedLocalModelID, nil, "retry success persists automatic intent, never current attempt ID")
        r.eq((await probe.sources).last, .custom("https://repaired.invalid"), "retry takes latest download source")
        store.flushPendingSave()
        let restartedStore = ConfigurationStore(defaults: defaults)
        r.eq(restartedStore.current.selectedLocalModelID, nil, "retry automatic intent survives store restart")
        let restarted = state(restartedStore, installed: true)
        await restarted.loadModel()
        r.eq(restarted.activeLease?.identity.id, ModelPreset.qwen306B.id, "restart automatically loads available local fallback")
        r.eq(restartedStore.current.selectedLocalModelID, nil, "restart does not convert local fallback to explicit selection")

        let manual = state(store)
        let before = await probe.attempts.count
        await manual.selectPreset(.qwen317B)
        try? await ModelRecoveryActions(coordinator: manual, store: store).retry()
        r.eq(Array((await probe.attempts).dropFirst(before)), [ModelPreset.qwen317B.id, ModelPreset.qwen317B.id], "explicit primary ordinary retry never automatically falls back")
        await probe.repairLarge()
        try? await ModelRecoveryActions(coordinator: manual, store: store).retry()
        r.eq(store.current.selectedLocalModelID, ModelPreset.qwen317B.id, "explicit retry persists explicit primary")
        store.flushPendingSave()
        r.eq(ConfigurationStore(defaults: defaults).current.selectedLocalModelID, ModelPreset.qwen317B.id, "explicit intent survives store restart")
    }
}

private actor RetryIntentProbe {
    var attempts: [String] = []
    var sources: [DownloadSource] = []
    var smallReady = false
    var largeReady = false
    func repairSmall() { smallReady = true }
    func repairLarge() { largeReady = true }
    func preflight(_ preset: ModelPreset, _ source: DownloadSource) { sources.append(source) }
    func load(_ target: ModelProvisionTarget) throws -> LocalASRLease {
        let preset: ModelPreset
        switch target {
        case .preset(let value): preset = value
        case .offline(let value): preset = value.modelId == ModelPreset.qwen317B.repoId ? .qwen317B : .qwen306B
        case .imported, .uninspectedDirectory: throw ModelProvisionError.loadFailed()
        }
        attempts.append(preset.id)
        guard preset.id == ModelPreset.qwen317B.id ? largeReady : smallReady else { throw ModelProvisionError.loadFailed() }
        return LocalASRLease(id: UUID(), identity: .init(id: preset.id, displayName: preset.name, engine: "qwen",
            repoID: preset.repoId, directory: URL(fileURLWithPath: "/fixture/" + preset.id)), provider: NativeActivationFixtures.Provider())
    }
}
