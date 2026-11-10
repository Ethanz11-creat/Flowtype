import Foundation
import CryptoKit

/// C2 orchestration uses tiny injected metadata and PCM; never production credentials or transport.
enum ASRAcquisitionSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testHFPreviewDoesNotDownloadWeights(r)
        testDraftAndServicePresetCapabilities(r)
        testValidationResourceContract(r)
        await testDirectoryAddOnly(r)
        await testHFVariantsAndSafeErrors(r)
        testAtomicServiceDraft(r)
        testCloudSaveOnlyAndLegacyIntent(r)
        testLocalDraftCloseOwnership(r)
    }
    @MainActor static func testHFPreviewDoesNotDownloadWeights(_ r: SelfTest.Reporter) async {
        let f = HFInstallPlannerSelfTests.Fixture(data: HFInstallPlannerSelfTests.qwenData, weights: ["model.safetensors"])
        let planner = HFInstallPlannerSelfTests.planner([f])
        var resolves = 0, enqueues = 0
        let session = HFModelInstallSession(resolve: { _, _, _ in resolves += 1; return f.repository },
            plan: { repo, variant, tokenizer, credential in try await planner.plan(repository: repo, variant: variant, tokenizer: tokenizer, credentialID: credential) },
            enqueue: { enqueues += 1; return $0.id })
        session.input.repository = "org/model"
        await session.confirmInstall()
        r.eq(enqueues, 0, "C2 no enqueue without a current explicit preview")
        await session.preparePreview()
        r.eq(resolves, 1, "C2 HF metadata requested explicitly")
        r.eq(enqueues, 0, "C2 preview never enqueues or transfers weights")
        r.eq(session.preview?.plan.totalBytes, f.repository.files.reduce(0) { $0 + $1.sizeBytes }, "C2 preview exposes exact planned size")
        r.eq(session.preview?.repository.commit, f.repository.commit, "C2 preview exposes frozen commit")
        await session.confirmInstall()
        r.eq(enqueues, 1, "C2 explicit confirmation enqueues B2 plan once")
        await session.confirmInstall()
        r.eq(enqueues, 1, "C2 duplicate confirmation does not enqueue twice")
        session.input.revision = "changed"
        r.check(session.preview == nil, "C2 edited inputs invalidate preview")
        await session.confirmInstall()
        r.eq(enqueues, 1, "C2 changed input requires fresh preview")
    }
    @MainActor static func testDraftAndServicePresetCapabilities(_ r: SelfTest.Reporter) {
        let mlx = LocalASRServicePreset.mlxAudio.makeProfile(baseURL: "http://127.0.0.1:8000/v1", modelID: "fixture")
        r.check(mlx.fieldCapabilities.sendResponseFormat, "C2 MLX requests json response")
        let cpp = LocalASRServicePreset.whisperCpp.makeProfile(baseURL: "http://127.0.0.1:8080", modelID: "ignored")
        r.check(cpp.modelID == nil && cpp.protocolKind == .whisperCpp, "C2 cpp model is server managed")
        var config = Configuration(); config.localASRServices = []
        let draft = LocalASRServiceDraft(target: .new(cpp.id), profile: cpp)
        do {
            let saved = try draft.applying(to: config)
            r.eq(saved.localASRServices.map(\.id), [cpp.id], "C2 service draft commits exact UUID")
            r.eq(saved.asrBackendSelection, config.asrBackendSelection, "C2 saving service does not select")
        } catch { r.check(false, "C2 valid cpp draft saves") }
        var missing = mlx; missing.modelID = ""
        do { _ = try LocalASRServiceDraft(target: .new(mlx.id), profile: missing).applying(to: config); r.check(false, "C2 OpenAI service requires model") }
        catch { r.check(true, "C2 OpenAI service requires model") }
        config.localASRServices = [cpp]
        var stale = cpp; stale.revision = UUID()
        do { _ = try LocalASRServiceDraft(target: .existing(cpp.id), profile: stale).applying(to: config); r.check(false, "C2 stale revision refused") }
        catch { r.check(true, "C2 stale revision refused") }
    }
    @MainActor static func testDirectoryAddOnly(_ r: SelfTest.Reporter) async {
        let f = AcquisitionDirectoryFixture()
        let actions = f.actions()
        await actions.stage(directory: f.model.directory)?.value
        do { _ = try actions.savePreview { _ in throw ASRCredentialError.persistence }; r.check(false, "C2 failed import save throws") }
        catch { r.check(actions.preview != nil, "C2 failed import save preserves inspection preview") }
        do {
            let id = try actions.savePreview { f.config = $0 }
            r.eq(id.rawValue, "native:import:" + f.model.id.uuidString, "C2 directory add returns durable backend UUID")
            r.check(f.native.activeLease == nil && f.config.asrBackendSelection == nil, "C2 directory add has no runtime or selection")
            r.eq(f.config.importedASRModels.first?.directory, f.model.directory, "C2 external directory stays in place")
        } catch { r.check(false, "C2 new inspected directory can be saved") }
        await actions.stageExisting(id: f.model.id)?.value
        f.config.importedASRModels[0].name = "Newer editor name"
        f.config.importedASRModels[0].fileFingerprint = "newer-fingerprint"
        let latest = f.config
        do { _ = try actions.savePreview { f.config = $0 } } catch { }
        r.eq(f.config, latest, "C2 stale add-only preview never overwrites latest existing record")
        await actions.stage(directory: f.model.directory.appendingPathComponent("moved"), replacing: f.model.id)?.value
        let before = f.config
        do { _ = try actions.savePreview { f.config = $0 }; r.check(false, "C2 add-only cannot relocate an existing model") }
        catch { r.check(true, "C2 add-only cannot relocate an existing model") }
        r.eq(f.config, before, "C2 add-only cannot change existing path or validation evidence")
    }
    @MainActor static func testHFVariantsAndSafeErrors(_ r: SelfTest.Reporter) async {
        let f = HFInstallPlannerSelfTests.Fixture(data: HFInstallPlannerSelfTests.graphs("openai_whisper-tiny/").merging(HFInstallPlannerSelfTests.graphs("openai_whisper-base/")) { a, _ in a })
        let planner = HFInstallPlannerSelfTests.planner([f])
        var enqueues = 0
        let session = HFModelInstallSession(resolve: { _, _, _ in f.repository }, plan: {
            try await planner.plan(repository: $0, variant: $1, tokenizer: $2, credentialID: $3)
        }, enqueue: { enqueues += 1; return $0.id })
        session.input.repository = "org/multi"
        await session.preparePreview()
        r.eq(session.variants, ["openai_whisper-base", "openai_whisper-tiny"], "C2 multivariant preview presents choices")
        r.check(session.preview == nil && session.message?.contains("变体") == true, "C2 multivariant requires user choice")
        session.input.variant = "openai_whisper-tiny"
        await session.preparePreview()
        r.check(session.preview == nil && session.message?.contains("分词器") == true, "C2 missing tokenizer has actionable explanation")
        r.eq(enqueues, 0, "C2 ambiguous or tokenizer-missing preview cannot enqueue")
        struct TokenFailure: Error, LocalizedError { var errorDescription: String? { "fixture-private-token" } }
        let safe = HFModelInstallSession(resolve: { _, _, _ in throw TokenFailure() }, plan: { _, _, _, _ in throw TokenFailure() }, enqueue: { _ in throw TokenFailure() })
        safe.input.repository = "org/private"
        await safe.preparePreview()
        r.check(safe.message?.contains("fixture-private-token") == false, "C2 HF errors never echo token or transport detail")
        r.check(ASRAcquisitionEntry.allCases.count == 5, "C2 exposes five acquisition destinations")
        let disclosure = ASRValidationDisclosure(destination: "https://fixture.invalid/v1", language: .en, isCloud: true)
        r.check(disclosure.destination.contains("fixture.invalid") && disclosure.sampleLabel.contains("English") && disclosure.notice.contains("收费"), "C2 service test disclosure exposes destination sample and possible cost")
        r.check(disclosure.notice.contains("上下文") && disclosure.notice.contains("剪贴板"), "C2 explicit test disclosure excludes hidden capture")
    }
    @MainActor static func testAtomicServiceDraft(_ r: SelfTest.Reporter) {
        let suite = "flowtype-c2-service-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let boundary = CredentialFixture()
        let credentials = KeychainASRCredentialStore(access: boundary.access)
        var rejectPersistence = false
        let store = ConfigurationStore(defaults: defaults, asrCredentials: credentials, persistence: { data in
            if rejectPersistence { throw ASRCredentialError.persistence }
            defaults.set(data, forKey: "flowtype.config")
        })
        let profile = LocalASRServicePreset.whisperCpp.makeProfile(baseURL: "http://127.0.0.1:8080", modelID: nil)
        let draft = LocalASRServiceDraft(target: .new(profile.id), profile: profile, keyEdit: .replace("fixture-c2-private-token"))
        boundary.state.withLock { $0.failAdd = true }
        let before = store.current
        do { try store.saveLocalASRServiceDraft(draft); r.check(false, "C2 service credential failure rejects save") }
        catch { r.eq(store.current, before, "C2 credential failure does not publish half profile") }
        boundary.state.withLock { $0.failAdd = false }
        do {
            try store.saveLocalASRServiceDraft(draft)
            let saved = store.current
            let profile = saved.localASRServices.first { $0.id == draft.profile.id }!
            guard case .bearer(let reference) = profile.authentication else { r.check(false, "C2 credential reference saved"); return }
            r.eq(try credentials.snapshot(id: reference).value, "fixture-c2-private-token", "C2 service stores token separately")
            r.check(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("fixture-c2-private-token"), "C2 serialized profile excludes bearer value")
            var edit = LocalASRServiceDraft(target: .existing(profile.id), profile: profile, keyEdit: .replace("fixture-c2-next-token"))
            edit.profile.baseURL = "http://127.0.0.1:9090"
            rejectPersistence = true
            do { try store.saveLocalASRServiceDraft(edit); r.check(false, "C2 persistence failure rejects service edit") }
            catch { r.eq(store.current, saved, "C2 failed persistence preserves committed endpoint credential pair") }
            r.eq(try credentials.snapshot(id: reference).value, "fixture-c2-private-token", "C2 failed edit never overwrites old credential")
            rejectPersistence = false
            try store.saveLocalASRServiceDraft(edit)
            r.check(store.current.localASRServices.first?.revision != profile.revision, "C2 service wire/key edit rotates revision")
            r.eq(store.current.asrBackendSelection, saved.asrBackendSelection, "C2 service save never selects or validates")
        } catch { r.check(false, "C2 isolated atomic service fixture unexpectedly threw") }
    }
    @MainActor static func testCloudSaveOnlyAndLegacyIntent(_ r: SelfTest.Reporter) {
        let suite = "flowtype-c2-cloud-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = KeychainASRCredentialStore(access: .memory())
        var reject = false
        let store = ConfigurationStore(defaults: defaults, asrCredentials: credentials, persistence: { data in
            if reject { throw ASRCredentialError.persistence }; defaults.set(data, forKey: "flowtype.config")
        })
        for legacyPending in [false, true] {
            var initial = Configuration(); initial.cloudASRConfig.providers = []
            initial.pendingLegacyNativeResolution = legacyPending
            store.current = initial
            let expected = ASRBackendMigration.selection(from: initial)
            var profile = CloudASRProviderConfig.defaultSiliconFlow(isActive: false)
            profile.name = "C2 new cloud"
            let draft = ASRProviderDraft(target: .new(profile.id), profile: profile, keyEdit: .replace("fixture-cloud-save-only"))
            do {
                try store.saveModelCenterASRDraft(draft)
                r.eq(store.current.asrBackendSelection, expected, "C2 cloud save freezes prior effective selection even when explicit selection was nil")
                r.check(store.current.cloudASRConfig.providers.first?.isActive == false, "C2 cloud save does not activate first profile")
                r.eq(store.current.pendingLegacyNativeResolution, legacyPending, "C2 cloud save preserves unresolved native migration marker")
                r.check(store.current.asrServiceValidationRecords.isEmpty, "C2 cloud save never creates validation evidence")
                if legacyPending {
                    var resolved = store.current
                    let lease = LocalASRLease(id: UUID(), identity: .init(id: UUID().uuidString, displayName: "Fixture", engine: "qwenMLX", repoID: nil, directory: URL(fileURLWithPath: "/injected/legacy")), provider: NativeActivationFixtures.Provider())
                    resolved.resolveLegacyNativeSelection(lease: lease)
                    r.eq(resolved.asrBackendSelection?.fallback, ASRBackendID(nativeLease: lease), "C2 later native activation still resolves legacy intent")
                }
                let explicit = ASRBackendSelection(primary: .init(rawValue: "service:" + UUID().uuidString))
                store.current.setASRBackendSelection(explicit)
                var edit = ASRProviderDraft(target: .existing(profile.id), profile: store.current.cloudASRConfig.providers[0])
                edit.profile.name = "Changed display"
                try store.saveModelCenterASRDraft(edit)
                r.eq(store.current.asrBackendSelection, explicit, "C2 cloud edit preserves explicit selection")
                store.current.setASRBackendSelection(.init())
                edit.profile = store.current.cloudASRConfig.providers[0]
                try store.saveModelCenterASRDraft(edit)
                r.eq(store.current.asrBackendSelection, .init(), "C2 cloud save cannot resurrect explicitly cleared selection")
                let before = store.current
                edit.profile.baseURL = "https://fixture.invalid/v1"; edit.keyEdit = .replace("fixture-failed-cloud-key")
                reject = true
                do { try store.saveModelCenterASRDraft(edit); r.check(false, "C2 save-only persistence failure throws") }
                catch { r.eq(store.current, before, "C2 save-only failure preserves profile key selection and migration state") }
                reject = false
            } catch { r.check(false, "C2 cloud save-only fixture unexpectedly threw") }
        }
    }
    @MainActor static func testLocalDraftCloseOwnership(_ r: SelfTest.Reporter) {
        let profile = LocalASRServicePreset.whisperCpp.makeProfile(baseURL: "http://127.0.0.1:8080", modelID: nil)
        let session = LocalASRServiceDraftSession(draft: .init(target: .new(profile.id), profile: profile))
        let navigation = SettingsNavigation(initialTab: .settings)
        var closed = 0
        session.attach(to: navigation) { closed += 1 }
        session.draft.profile.name = "Unsaved service"
        navigation.navigate(to: .history("c2-original"))
        r.check(session.confirmingDiscard && closed == 0, "C2 dirty local draft guards external navigation")
        session.keepEditing()
        r.eq(session.draft.profile.name, "Unsaved service", "C2 keep editing retains local draft")
        navigation.navigate(to: .history("c2-original"))
        session.discard()
        r.eq(navigation.request?.destination, .history("c2-original"), "C2 local discard forwards original navigation")
        r.eq(closed, 1, "C2 local discard closes once")
    }
    static func testValidationResourceContract(_ r: SelfTest.Reporter) {
        for language: WhisperLanguage in [.zh, .en, .auto] {
            do {
                let sample = try ASRValidationSampleStore.load(language: language)
                r.eq(sample.sampleRate, 16_000, "C2 bundled sample 16k mono PCM")
                r.check(!sample.samples.isEmpty && sample.samples.count <= 128_000, "C2 bundled sample at most eight seconds")
                r.check(sample.samples.contains { abs($0) > 0.01 }, "C2 sample contains synthesized speech rather than silence")
                let canonical = try ASRValidationSample(samples: sample.samples, sampleRate: 16_000, label: sample.label)
                r.eq(canonical.sha256, sample.sha256, "C2 canonical PCM checksum")
            } catch { r.check(false, "C2 bundled \(language.rawValue) sample loads with verified resource checksum: \(error)") }
        }
    }
}

@MainActor private final class AcquisitionDirectoryFixture {
    var config = Configuration()
    let model = ImportedASRModel(name: "C2 directory fixture", directory: URL(fileURLWithPath: "/injected/c2-external"), engine: .qwenMLX, variant: "0.6B", bits: 4, sizeBytes: 8, tokenizerDirectory: nil, fileFingerprint: "fixture")
    lazy var native = QwenModelState(configuration: { [self] in config }, localModel: { _ in nil }, environment: .init(read: { nil }, write: { _ in }), usageRegistry: NativeModelUsageRegistry())
    func actions() -> ImportedASRModelActions {
        .init(coordinator: native, configuration: { [self] in config }, inspect: { [model] directory in
            var value = model; value.directory = directory; return value
        }, assess: { _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: 8) })
    }
}
