import Foundation

/// Real child bindings/actions and coordinator commits; only model I/O is fake.
@MainActor
enum LocalSettingsOwnershipSelfTests {
    private struct Provider: ASRProvider {
        let id = "fixture-local"
        let displayName = "Fixture local model"
        let capabilities = ASRCapabilities(supportsLanguageHint: true, supportsContextHint: false,
                                           requiresNetwork: false, location: .onDevice)
        var isAvailable: Bool { get async { true } }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            .init(text: "fixture", providerID: id, latencyMs: 0)
        }
    }

    static func coordinator(store: ConfigurationStore) -> QwenModelState {
        QwenModelState(preflight: { _, _ in }, load: { target, _, _ in
            let preset: ModelPreset
            switch target {
            case .preset(let value): preset = value
            case .offline(let value):
                guard let value = ModelPreset.allPresets.first(where: { $0.repoId == value.modelId }) else {
                    throw ModelProvisionError.incompleteLocal()
                }
                preset = value
            default: throw ModelProvisionError.incompleteLocal()
            }
            return LocalASRLease(id: UUID(), identity: .init(id: preset.id, displayName: preset.name,
                engine: "qwen", repoID: preset.repoId, directory: URL(fileURLWithPath: "/fixture/" + preset.id)),
                provider: Provider())
        }, configuration: { store.current }, localModel: { _ in nil },
            destination: { URL(fileURLWithPath: "/fixture/" + $0.id) }, availableDisk: { _ in .max },
            environment: .init(read: { nil }, write: { _ in }), inspect: { NativeActivationFixtures.model($0) }, saveConfiguration: { store.save($0) }, persistActivation: { try store.commitNativeASRActivation($0) },
            sampleProvider: NativeActivationFixtures.sample)
    }

    static func run(_ r: SelfTest.Reporter) async {
        print("--- LocalSettingsOwnershipSelfTests.localChildrenHonorConfigurationOwner ---")
        let suite = "flowtype.local-settings-owner.\(UUID())"
        let sentinelSuite = "flowtype.local-settings-sentinel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let sentinelDefaults = UserDefaults(suiteName: sentinelSuite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        sentinelDefaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        let sentinel = ConfigurationStore(defaults: sentinelDefaults)
        defer {
            store.flushPendingSave(); sentinel.flushPendingSave()
            defaults.removePersistentDomain(forName: suite)
            sentinelDefaults.removePersistentDomain(forName: sentinelSuite)
        }
        store.current.downloadSource = .official
        sentinel.current.downloadSource = .custom("https://sentinel.invalid")
        sentinel.current.selectedLocalModelID = ModelPreset.qwen317B.id
        let sentinelBefore = sentinel.current
        let effects = ValidationEffects.live.snapshot
        let coordinator = coordinator(store: store)
        let downloader = ModelDownloader(coordinator: coordinator, configuration: { store.current })
        let importedActions = ImportedASRModelActions(coordinator: coordinator, configuration: { store.current })
        let monitor = ReadinessMonitor(snapshot: ReadinessSnapshot(accessibility: .granted, microphone: .granted,
            speechRecognition: .notDetermined, localModel: .unavailable(reason: "fixture"),
            cloudASR: .unavailable(reason: "fixture"), appleSpeech: .unavailable(reason: "fixture"), computedAt: Date()))
        let asr = ASRSettingsContent(store: store, monitor: monitor, modelState: coordinator,
            downloader: downloader, importedActions: importedActions, navigation: nil,
            checks: CloudASRConnectionCheck(recognitionTest: { _, _ in .success("fixture") }),
            draftChecks: CloudASRConnectionCheck(recognitionTest: { _, _ in .success("fixture") }), devices: { [] })
        let picker = asr.localModelPicker
        let card = asr.localModelStatus
        r.eq(card.downloadSourceSelection.wrappedValue, .official, "localChildrenOwner: source reads alternate store")
        card.downloadSourceSelection.wrappedValue = .mirror
        r.eq(store.current.downloadSource, .mirror, "localChildrenOwner: source control changes alternate store")
        await picker.selectPreset(.qwen306B)
        r.eq(store.current.selectedLocalModelID, ModelPreset.qwen306B.id, "localChildrenOwner: preset action commits to alternate store")
        r.eq(coordinator.activeLease?.identity.id, ModelPreset.qwen306B.id, "localChildrenOwner: preset action uses injected fake coordinator")
        let first = ImportedASRModel(name: "Fixture first", directory: URL(fileURLWithPath: "/fixture/first"),
            engine: .qwenMLX, variant: "0.6B", bits: 4, sizeBytes: 1,
            tokenizerDirectory: URL(fileURLWithPath: "/fixture/first"), fileFingerprint: "fixture")
        let second = ImportedASRModel(name: "Fixture second", directory: URL(fileURLWithPath: "/fixture/second"),
            engine: .qwenMLX, variant: "0.6B", bits: 4, sizeBytes: 1,
            tokenizerDirectory: URL(fileURLWithPath: "/fixture/second"), fileFingerprint: "fixture")
        store.current.importedASRModels = [first, second]
        picker.importedModels.actions.remove(id: first.id)
        r.eq(store.current.importedASRModels.map(\.id), [second.id],
             "localChildrenOwner: picker import removal updates alternate store by UUID")
        card.modelLibrary.modelList.actions.remove(id: second.id)
        r.check(store.current.importedASRModels.isEmpty,
                "localChildrenOwner: nested library removal uses same injected owner")
        r.eq(sentinel.current, sentinelBefore, "localChildrenOwner: unrelated sentinel store unchanged")
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "localChildrenOwner: zero attempted external effects")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "localChildrenOwner: zero external effects")
    }
}
