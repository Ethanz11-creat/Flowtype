import Foundation
import GRDB
import os

@MainActor
enum M5IsolationSelfTests {
    static func run(_ r: SelfTest.Reporter) async {
        do { try testLegacyMigrationBoundaries(r) }
        catch { r.check(false, "M5 isolation migration fixture failed") }
        testDeniedEffects(r)
        await testSingletonSideEffectBudget(r)
        checkEffectBudget(r)
    }

    static func checkEffectBudget(_ r: SelfTest.Reporter) {
        let counts = ValidationEffects.live.snapshot
        for operation in ValidationEffects.Operation.allCases {
            r.eq(counts.permitted[operation, default: 0], 0, "M5 actual \(operation.rawValue) budget zero")
        }
    }

    // Catches migrations escaping an injected directory or using SecItem instead of injected keys.
    static func testLegacyMigrationBoundaries(_ r: SelfTest.Reporter) throws {
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("m5-isolation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep synthetic DB and backup evidence in this run for inspection.
        let suite = "com.flowtype.validation.fixture.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = OSAllocatedUnfairLock(initialState: [String: String]())
        let systemCalls = OSAllocatedUnfairLock(initialState: 0)
        let fake = KeychainAccess(save: { key, value in keys.withLock { $0[key] = value }; return true },
                                  load: { key in keys.withLock { $0[key] } },
                                  delete: { key in keys.withLock { _ = $0.removeValue(forKey: key) } })
        // Version-zero persisted state must match the decoder's real key layout.
        // Flat llmApiKey is no longer decoded; the active provider resolves this map.
        defaults.set(Data(#"{"llmProviders":[{"id":"11111111-2222-3333-4444-555555555555","name":"synthetic","provider":"custom","baseURL":"https://synthetic.invalid/v1","model":"synthetic","isActive":true}],"providerAPIKeys":{"11111111-2222-3333-4444-555555555555":"synthetic-legacy-key"},"asrLanguage":"auto"}"#.utf8), forKey: "flowtype.config")
        let config = ConfigurationStore(defaults: defaults, backupDirectory: root, keychain: fake)
        r.eq(keys.withLock { $0["llmApiKey"] }, "synthetic-legacy-key", "M5 migration uses injected legacy key storage")
        if let provider = config.current.llmProviders.first {
            r.eq(config.loadProviderAPIKey(provider.id), "synthetic-legacy-key", "M5 provider key survives version-zero migration")
        } else { r.check(false, "M5 legacy migration creates provider") }
        r.eq(defaults.integer(forKey: "flowtype.migrationVersion"), 5, "M5 fixture migration completes")
        defaults.set(Data("{invalid sk-synthetic12345678".utf8), forKey: "flowtype.config")
        _ = ConfigurationStore(defaults: defaults, backupDirectory: root, keychain: fake)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("flowtype.config.corrupt-") }
        r.eq(backups.count, 1, "M5 corrupt config backup stays in fixture")
        if let backup = backups.first {
            r.check(!(try String(contentsOf: backup, encoding: .utf8)).contains("sk-synthetic12345678"), "M5 corrupt backup redacts synthetic key")
        }

        let db = AppDatabase.make(at: root)
        try Data(#"[{"id":"m5-synthetic-history","createdAt":"2026-01-01T00:00:00Z","rawTranscript":"synthetic","finalText":"synthetic","polishMode":"raw","durationMs":10}]"#.utf8)
            .write(to: root.appendingPathComponent("history.json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("daily_stats.json"))
        JSONMigration.runIfNeeded(db, dir: root)
        r.check(db.isOnDisk && JSONMigration.hasMigrated(db), "M5 durable fixture JSON migration commits")
        r.eq(try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM session") }, 1,
             "M5 fixture history row is imported into its durable SQLite DB")
        for name in ["history.json.bak", "daily_stats.json.bak", "flowtype.sqlite"] {
            r.check(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "M5 fixture migration evidence \(name)")
        }
        let store = PersistentStore<[String]>(filename: "synthetic.json", directory: root)
        store.save(["fixture"])
        r.eq(store.load(), ["fixture"], "M5 injected persistent store first save round-trips")
        let denied = ValidationEffects(role: .selfTest, external: { _ in systemCalls.withLock { $0 += 1 } })
        let keychain = KeychainAccess.guarded(role: .selfTest, system: fake, effects: denied)
        r.check(keychain.save("m5-memory", "synthetic-memory"), "M5 validation keychain saves in memory")
        r.eq(keychain.load("m5-memory"), "synthetic-memory", "M5 validation keychain reads memory")
        keychain.delete("m5-memory")
        r.eq(keychain.load("m5-memory"), nil, "M5 validation keychain deletes memory")
        r.eq(systemCalls.withLock { $0 }, 0, "M5 SecItem downstream spy remains zero")
        r.eq(keys.withLock { $0["m5-memory"] }, nil, "M5 validation keys never reach system adapter")
    }

    // Removing the role guard would invoke the independent downstream spy.
    private static func testDeniedEffects(_ r: SelfTest.Reporter) {
        let downstream = OSAllocatedUnfairLock(initialState: 0)
        let gate = ValidationEffects(role: .selfTest, external: { _ in downstream.withLock { $0 += 1 } })
        for operation in ValidationEffects.Operation.allCases {
            r.check(!gate.allow(operation), "M5 denies actual \(operation.rawValue) boundary")
        }
        r.eq(downstream.withLock { $0 }, 0, "M5 every external downstream spy stays zero")
        r.eq(gate.snapshot.permitted.values.reduce(0, +), 0, "M5 permitted external budget is zero")
        let app = ValidationEffects(role: .app, external: { _ in downstream.withLock { $0 += 1 } })
        r.check(app.allow(.keychain), "M5 app keeps live boundaries available")
        r.eq(downstream.withLock { $0 }, 1, "M5 downstream spy detects a permitted boundary")
    }

    static func testSingletonSideEffectBudget(_ r: SelfTest.Reporter) async {
        let paths = RuntimeEnvironment.current.paths
        r.eq(PersistentStore<[String]>(filename: "fixture.json").fileURL.deletingLastPathComponent(), paths.applicationSupportDirectory,
             "M5 default persistent store uses runtime support")
        r.eq(AppDatabaseProvider.dir, paths.applicationSupportDirectory, "M5 DB provider uses runtime support")
        _ = AppDatabaseProvider.shared
        r.eq(ModelPreset.modelsDirectory, paths.modelsDirectory, "M5 preset path uses runtime models")
        r.eq(ModelLocator.knownCacheDirs(), [], "M5 implicit cache locator performs no user scan")
        let shared = ConfigurationStore.shared
        r.check(shared.current.providerAPIKeys.isEmpty && shared.current.localModelPath == nil, "M5 shared starts without keys/model selection")
        _ = SessionController.shared
        _ = ASRRouter.shared
        _ = QwenModelState.shared
        _ = ModelDownloader.shared
        _ = DictionaryStore.shared
        SessionEffects.live.prepare()
        EnvMigration.migrateIfNeeded()
        AudioRecorder.restorePendingDeviceIfNeeded()
        for _ in 0..<32 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        r.eq(QwenModelState.shared.status, .notLoaded, "M5 singleton preparation does not schedule model work")
        r.eq(ValidationEffects.live.snapshot.permitted.values.reduce(0, +), 0, "M5 shared actual external boundary budget zero")
        r.check(KeychainHelper.save(key: "m5-isolation-key", value: "synthetic"), "M5 actual helper saves validation memory")
        r.eq(KeychainHelper.load(key: "m5-isolation-key"), "synthetic", "M5 actual helper reads validation memory")
        KeychainHelper.delete(key: "m5-isolation-key")
        r.eq(KeychainHelper.load(key: "m5-isolation-key"), nil, "M5 actual helper deletes validation memory")
        let recorder = AudioRecorder()
        r.check(!(await recorder.requestPermission()), "M5 recorder denies actual permission request")
        KeyboardInjector.copyText("synthetic")
        RecoveryEffects.live.copyText("synthetic")
        r.eq(SystemDeliveryPasteboard().contents(), nil, "M5 actual pasteboard adapter refuses OS reads")
        PermissionHelper.openMicrophoneSettings()
        PermissionHelper.openAccessibilitySettings()
        PermissionHelper.openSpeechRecognitionSettings()
        SoundFeedback.playRecordingStart()
        r.eq(await AXContextProvider().collect(), nil, "M5 actual context adapter refuses user AX reads")
        r.eq(await CloudProbe.measureLatency(host: "synthetic.invalid", port: 443), nil, "M5 actual probe refuses network")
        r.eq(ValidationEffects.live.snapshot.permitted.values.reduce(0, +), 0, "M5 actual denied adapter budget remains zero")
        // nil backupDirectory must resolve to isolated logs, including injected constructors.
        let suite = "com.flowtype.validation.corrupt.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid-synthetic".utf8), forKey: "flowtype.config")
        _ = ConfigurationStore(defaults: defaults)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.logsDirectory.path)) ?? []
        r.check(names.contains { $0.hasPrefix("flowtype.config.corrupt-") }, "M5 nil backup constructor uses isolated logs")
    }
}
