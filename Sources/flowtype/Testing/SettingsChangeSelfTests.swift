import Foundation

enum SettingsChangeSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        print("--- SettingsChangeSelfTests.unrelatedSettingsDoNotReloadHotkey ---")
        await unrelatedSettingsDoNotReloadHotkey(r)
        print("--- SettingsChangeSelfTests.hotkeySettingsReloadOnce ---")
        await hotkeySettingsReloadOnce(r)
        print("--- SettingsChangeSelfTests.saveSurvivesPageClose ---")
        await saveSurvivesPageClose(r)
        print("--- SettingsChangeSelfTests.sameTurnChangesKeepLatestSettings ---")
        await sameTurnChangesKeepLatestSettings(r)
        print("--- SettingsChangeSelfTests.duplicatePublicationsDoNotResave ---")
        await duplicatePublicationsDoNotResave(r)
    }

    private final class ObservedSaveStore: ConfigurationStore, @unchecked Sendable {
        var submittedSaves = 0
        override func save(_ config: Configuration) {
            submittedSaves += 1
            super.save(config)
        }
    }

    // Each test owns a separate defaults domain and never reads live configuration.
    private final class Fixture {
        let suite = "flowtype.settings-change.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: ObservedSaveStore

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(5, forKey: "flowtype.migrationVersion")
            store = ObservedSaveStore(defaults: defaults)
            store.current.asrBackendSelection = ASRBackendMigration.selection(from: store.current)
            store.current.llmProviders = [LLMProvider(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                name: "Test", provider: "Custom", baseURL: "https://example.invalid/v1",
                model: "test-model", isActive: true)]
        }

        func restored() -> Configuration {
            ConfigurationStore(defaults: defaults).current
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor
    private static func drainChanges() async {
        // Main-queue barriers let the deferred snapshot and its save publication settle.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    // Catches broad hotkey invalidation and missing automatic persistence.
    @MainActor
    private static func unrelatedSettingsDoNotReloadHotkey(_ r: SelfTest.Reporter) async {
        let f = Fixture()
        var reloads = 0
        let coordinator = SettingsChangeCoordinator(store: f.store) { reloads += 1 }
        coordinator.startObserving()
        let edits: [(inout Configuration) -> Void] = [
            { $0.appearancePreference = .dark }, { $0.storeTranscriptText = false },
            { $0.cloudASRSendContext = false }, { $0.asrLanguage = .en },
            { $0.llmProviders[0].model = "edited-model" }, { $0.systemPrompt = "Edited prompt" }
        ]
        for edit in edits {
            edit(&f.store.current)
            await drainChanges()
        }
        r.eq(reloads, 0, "unrelatedSettingsDoNotReloadHotkey: appearance/privacy/ASR/LLM keep binding")
        r.eq(f.store.submittedSaves, 6, "unrelatedSettingsDoNotReloadHotkey: each settled edit submits once")
        f.store.flushPendingSave()
        r.eq(f.restored(), f.store.current, "unrelatedSettingsDoNotReloadHotkey: all edited fields restore")
        withExtendedLifetime(coordinator) {}
    }

    // Catches missed field dependencies, duplicate reloads, or willSet save recursion.
    @MainActor
    private static func hotkeySettingsReloadOnce(_ r: SelfTest.Reporter) async {
        let f = Fixture()
        var bindings: [(TriggerKey, InteractionMode)] = []
        let coordinator = SettingsChangeCoordinator(store: f.store) {
            bindings.append((f.store.current.triggerKey, f.store.current.interactionMode))
        }
        coordinator.startObserving()
        coordinator.startObserving()
        await drainChanges()
        r.eq(f.store.submittedSaves, 0, "hotkeySettingsReloadOnce: opening observation does not save")
        r.check(f.defaults.data(forKey: "flowtype.config") == nil,
                "hotkeySettingsReloadOnce: opening observation does not persist defaults")
        f.store.current.triggerKey = .f13
        await drainChanges()
        r.eq(bindings.count, 1, "hotkeySettingsReloadOnce: trigger key reloads once")
        r.eq(bindings.last?.0, .f13, "hotkeySettingsReloadOnce: reload sees committed trigger")
        f.store.current.interactionMode = .toggle
        await drainChanges()
        r.eq(bindings.count, 2, "hotkeySettingsReloadOnce: interaction mode reloads once")
        r.eq(bindings.last?.1, .toggle, "hotkeySettingsReloadOnce: reload sees committed mode")
        let latest = f.store.current
        f.store.current = latest
        await drainChanges()
        r.eq(bindings.count, 2, "hotkeySettingsReloadOnce: identical publication has no reload")
        f.store.flushPendingSave()
        r.eq(f.restored(), latest, "hotkeySettingsReloadOnce: latest binding settings restore")
        withExtendedLifetime(coordinator) {}
    }

    // Catches persistence tied to a settings view's onChange/disappearance.
    @MainActor
    private static func saveSurvivesPageClose(_ r: SelfTest.Reporter) async {
        let f = Fixture()
        let coordinator = SettingsChangeCoordinator(store: f.store, reloadHotkey: {})
        coordinator.startObserving()
        var navigation: SettingsNavigation? = SettingsNavigation(initialTab: .settings)
        f.store.current.systemPrompt = "Saved after leaving settings"
        navigation?.navigate(to: .tab(.overview))
        navigation = nil
        await drainChanges()
        r.check(f.defaults.data(forKey: "flowtype.config") == nil,
                "saveSurvivesPageClose: existing save debounce remains active")
        try? await Task.sleep(for: .milliseconds(650))
        r.eq(f.restored().systemPrompt, "Saved after leaving settings",
             "saveSurvivesPageClose: debounce saves without a mounted page")
        f.store.current.systemPrompt = "Latest edit before termination"
        // Termination flush must preserve even a not-yet-observed latest assignment.
        f.store.flushPendingSave()
        r.eq(f.restored().systemPrompt, "Latest edit before termination",
             "saveSurvivesPageClose: immediate termination flush preserves latest edit")
        await drainChanges()
        f.store.flushPendingSave()
        withExtendedLifetime(coordinator) {}
    }

    // Catches saving willSet's previous snapshot, which loses concurrent field edits.
    @MainActor
    private static func sameTurnChangesKeepLatestSettings(_ r: SelfTest.Reporter) async {
        let f = Fixture()
        var reloaded: Configuration?
        let coordinator = SettingsChangeCoordinator(store: f.store) { reloaded = f.store.current }
        coordinator.startObserving()
        f.store.current.appearancePreference = .light
        f.store.current.triggerKey = .rightCommand
        f.store.current.storeTranscriptText = false
        f.store.current.interactionMode = .toggle
        f.store.current.llmProviders[0].name = "Latest service name"
        let expected = f.store.current
        await drainChanges()
        r.eq(f.store.current, expected, "sameTurnChangesKeepLatestSettings: no in-memory edits lost")
        r.eq(reloaded, expected, "sameTurnChangesKeepLatestSettings: effect sees latest complete snapshot")
        r.eq(f.store.submittedSaves, 1, "sameTurnChangesKeepLatestSettings: coalesces one turn")
        f.store.flushPendingSave()
        r.eq(f.restored(), expected, "sameTurnChangesKeepLatestSettings: all same-turn fields restore")
        withExtendedLifetime(coordinator) {}
    }

    // Catches resaving save()'s own publication or repeatedly processing identical values.
    @MainActor
    private static func duplicatePublicationsDoNotResave(_ r: SelfTest.Reporter) async {
        let f = Fixture()
        var reloads = 0
        let coordinator = SettingsChangeCoordinator(store: f.store) { reloads += 1 }
        coordinator.startObserving()
        f.store.current.triggerKey = .f14
        let expected = f.store.current
        f.store.current = expected
        f.store.current = expected
        await drainChanges()
        f.store.current = expected
        await drainChanges()
        r.eq(f.store.submittedSaves, 1, "duplicatePublicationsDoNotResave: one save across duplicate events")
        r.eq(reloads, 1, "duplicatePublicationsDoNotResave: one hotkey effect")
        f.store.flushPendingSave()
        r.eq(f.restored(), expected, "duplicatePublicationsDoNotResave: persisted configuration is complete")
        withExtendedLifetime(coordinator) {}
    }
}
