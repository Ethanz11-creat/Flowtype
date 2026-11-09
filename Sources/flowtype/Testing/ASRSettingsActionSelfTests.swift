import Foundation

/// Store/action → real capture regressions: a displayed choice must route the next session.
@MainActor enum ASRSettingsActionSelfTests {
    @MainActor final class Fixture {
        let suite = "flowtype.asr-actions." + UUID().uuidString
        let defaults: UserDefaults
        let credentials = KeychainASRCredentialStore(access: .memory())
        let store: ConfigurationStore
        let first = CloudASRVendor.makeProfile(.openAI, isActive: true)
        let second = CloudASRVendor.makeProfile(.siliconFlow, isActive: false)
        let other = CloudASRVendor.makeProfile(.custom, isActive: false)
        let lease = LocalASRLease(id: UUID(), identity: .init(id: "action-native", displayName: "Action native", engine: "fixture",
            repoID: nil, directory: URL(fileURLWithPath: "/nonexistent/action-native")), provider: Provider())
        var nativeID: ASRBackendID { ASRBackendID(nativeLease: lease) }
        var firstID: ASRBackendID { .init(rawValue: "cloud:" + first.id.uuidString) }
        var secondID: ASRBackendID { .init(rawValue: "cloud:" + second.id.uuidString) }
        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(5, forKey: "flowtype.migrationVersion")
            store = ConfigurationStore(defaults: defaults, keychain: .init(save: { _, _ in true }, load: { _ in nil }, delete: { _ in }),
                asrCredentials: credentials)
            var config = store.current
            config.cloudASRConfig = .init(providers: [first, second, other], providerAPIKeys: [first.id.uuidString: "fixture-A", second.id.uuidString: "fixture-B"])
            config.selectedLocalModelID = "action-native"
            config.asrRoutingPolicy = .auto
            config.setASRBackendSelection(.init(primary: firstID, fallback: nativeID, allowsCloudFallback: false))
            store.save(config)
            store.flushPendingSave()
        }
        func cleanUp() { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        func router() -> ASRRouter {
            ASRRouter(startMonitoring: false, internetAvailable: { true }, credentials: credentials,
                persistNativeResolution: { _ in }, configuration: { self.store.current }, localAvailable: { true }, localLease: { self.lease })
        }
        func restored() -> ConfigurationStore {
            ConfigurationStore(defaults: defaults, keychain: .init(save: { _, _ in true }, load: { _ in nil }, delete: { _ in }), asrCredentials: credentials)
        }
    }
    private struct Provider: ASRProvider {
        let id = "native-fixture", displayName = "Native fixture"
        let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: false, location: .onDevice)
        var isAvailable: Bool { get async { true } }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult { .init(text: "fixture", providerID: id, latencyMs: 1) }
    }
    static func run(_ r: SelfTest.Reporter) async {
        let f = Fixture()
        defer { f.cleanUp() }
        let router = f.router()
        let captured = await router.captureStartRoute()
        try? f.store.applyASRSettingsAction(.activateCloud(f.second.id))
        f.store.save(f.store.current); f.store.flushPendingSave()
        r.eq((await router.captureStartRoute()).candidateIDs, [f.secondID.rawValue, f.nativeID.rawValue], "I1 explicit activate B routes next capture to B")
        r.eq(captured.candidateIDs, [f.firstID.rawValue, f.nativeID.rawValue], "I1 activation cannot mutate captured A")
        r.eq(f.restored().current.asrBackendSelection?.primary, f.secondID, "I1 activation survives restart")

        let deletion = Fixture()
        defer { deletion.cleanUp() }
        try? deletion.store.applyASRSettingsAction(.deleteCloud(deletion.first.id, confirmSelected: true))
        r.eq(deletion.store.current.cloudASRConfig.providers.filter(\.isActive).map(\.id), [], "I1 delete selected A never promotes arbitrary B")
        r.eq(deletion.store.current.asrBackendSelection?.primary, deletion.firstID, "I1 deleted selected identity stays unavailable")

        let policy = Fixture()
        defer { policy.cleanUp() }
        var local = policy.store.current
        local.asrRoutingPolicy = .localOnly
        local.setASRBackendSelection(.init(primary: policy.nativeID))
        policy.store.save(local)
        try? policy.store.applyASRSettingsAction(.changePolicy(.cloudOnly))
        r.eq((await policy.router().captureStartRoute()).candidateIDs, [policy.firstID.rawValue], "I1 localOnly to cloudOnly uses explicit active cloud")
        var cloud = policy.store.current
        cloud.setASRBackendSelection(.init(primary: policy.firstID))
        cloud.asrRoutingPolicy = .cloudOnly
        policy.store.save(cloud)
        try? policy.store.applyASRSettingsAction(.changePolicy(.localOnly))
        r.eq((await policy.router().captureStartRoute()).candidateIDs, [policy.nativeID.rawValue], "I1 cloudOnly to localOnly uses exact configured native")

        r.eq(captured.bindings.first?.descriptor.maxUploadBytes, 25_000_000, "M1 captured known OpenAI upload bound is exposed")
        // Deletion is an explicit destructive action; no reference can silently promote another row.
        let deleteCases = Fixture(); defer { deleteCases.cleanUp() }
        let original = deleteCases.store.current
        r.check((try? deleteCases.store.applyASRSettingsAction(.deleteCloud(deleteCases.first.id, confirmSelected: false))) == nil,
                "I1 selected primary deletion requires confirmation")
        r.eq(deleteCases.store.current, original, "I1 cancelled primary deletion leaves configuration intact")
        var fallbackConfig = original
        fallbackConfig.setASRBackendSelection(.init(primary: deleteCases.nativeID, fallback: deleteCases.firstID, allowsCloudFallback: false))
        deleteCases.store.save(fallbackConfig)
        r.check((try? deleteCases.store.applyASRSettingsAction(.deleteCloud(deleteCases.first.id, confirmSelected: false))) == nil,
                "I1 selected fallback deletion requires confirmation")
        try? deleteCases.store.applyASRSettingsAction(.deleteCloud(deleteCases.other.id, confirmSelected: false))
        r.eq(deleteCases.store.current.asrBackendSelection, fallbackConfig.asrBackendSelection, "I1 deleting unrelated provider preserves both roles and consent")
        try? deleteCases.store.applyASRSettingsAction(.deleteCloud(deleteCases.first.id, confirmSelected: true))
        r.eq((await deleteCases.router().captureStartRoute()).candidateIDs, [deleteCases.nativeID.rawValue], "I1 deleted cloud fallback never uploads or replaces local primary")
        r.eq(deleteCases.store.current.asrBackendSelection?.fallback, deleteCases.firstID, "I1 deleted fallback retains exact unavailable ID")
        r.eq(deleteCases.store.current.cloudASRConfig.providers.filter(\.isActive).map(\.id), [], "I1 fallback deletion never autoactivates other provider")

        // Policy-only transitions preserve unrelated selected roles and never create upload consent.
        let boundary = Fixture(); defer { boundary.cleanUp() }
        let boundaryOriginal = boundary.store.current
        var boundaryConfig = boundaryOriginal
        boundaryConfig.asrRoutingPolicy = .localOnly
        boundaryConfig.setASRBackendSelection(.init(primary: boundary.nativeID, allowsCloudFallback: false))
        boundary.store.save(boundaryConfig)
        r.check((try? boundary.store.applyASRSettingsAction(.activateCloud(boundary.second.id))) == nil,
                "I1 activation conflicts visibly under localOnly")
        r.eq(boundary.store.current, boundaryConfig, "I1 rejected activation cannot alter flags or route")
        boundaryConfig.cloudASRConfig.providers = boundaryConfig.cloudASRConfig.providers.map { profile in var p = profile; p.isActive = false; return p }
        boundary.store.save(boundaryConfig)
        r.check((try? boundary.store.applyASRSettingsAction(.changePolicy(.cloudOnly))) == nil, "I1 all inactive cloud rows cannot supply arbitrary first replacement")
        r.eq(boundary.store.current, boundaryConfig, "I1 no intended backend leaves policy and selection unchanged")
        boundaryConfig = boundaryOriginal
        boundaryConfig.asrRoutingPolicy = .cloudOnly
        boundaryConfig.setASRBackendSelection(.init(primary: boundary.firstID, allowsCloudFallback: false))
        boundary.store.save(boundaryConfig)
        try? boundary.store.applyASRSettingsAction(.changePolicy(.auto))
        r.eq((await boundary.router().captureStartRoute()).candidateIDs, [boundary.firstID.rawValue, boundary.nativeID.rawValue], "I1 automatic recovery restores explicitly configured native fallback")
        r.eq(boundary.store.current.asrBackendSelection?.allowsCloudFallback, false, "I1 policy action never grants cloud fallback consent")
        try? boundary.store.applyASRSettingsAction(.changePolicy(.localOnly))
        try? boundary.store.applyASRSettingsAction(.changePolicy(.auto))
        r.eq((await boundary.router().captureStartRoute()).candidateIDs, [boundary.nativeID.rawValue], "I1 auto from local primary cannot enable unconsented cloud fallback")
        boundaryConfig = boundary.store.current
        boundaryConfig.setASRBackendSelection(.init(primary: boundary.nativeID, fallback: .init(rawValue: "service:keep-me")))
        boundaryConfig.asrRoutingPolicy = .localOnly
        boundary.store.save(boundaryConfig)
        r.check((try? boundary.store.applyASRSettingsAction(.changePolicy(.cloudOnly))) == nil,
                "I1 changing mode cannot silently evict an occupied unrelated fallback")
        r.eq(boundary.store.current, boundaryConfig, "I1 occupied roles conflict preserves complete configuration")

        try? boundary.store.setASRBackendSelection(.init())
        var unrelated = boundary.store.current
        unrelated.appearancePreference = .dark
        unrelated.asrLanguage = .en
        boundary.store.save(unrelated); boundary.store.flushPendingSave()
        r.eq(boundary.restored().current.asrBackendSelection, .init(), "I1 unrelated save and restart preserve explicit clear")
        r.eq((await boundary.router().captureStartRoute()).candidateIDs, [], "I1 unrelated save cannot resurrect native or cloud after clear")
        let flagsBefore = f.store.current.cloudASRConfig.providers.map(\.isActive)
        let rolesBefore = f.store.current.asrBackendSelection
        let failing = ConfigurationStore(defaults: f.defaults, keychain: .init(save: { _, _ in true }, load: { _ in nil }, delete: { _ in }),
            asrCredentials: f.credentials, persistence: { _ in throw ASRCredentialError.persistence })
        r.check((try? failing.applyASRSettingsAction(.activateCloud(f.first.id))) == nil, "I1 action persistence failure is surfaced")
        r.eq(failing.current.asrBackendSelection, rolesBefore, "I1 failed persistence retains old route")
        r.eq(failing.current.cloudASRConfig.providers.map(\.isActive), flagsBefore, "I1 failed persistence retains old selected presentation")

    }
}
