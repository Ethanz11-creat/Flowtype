import Foundation
import os

@MainActor
enum ASRCredentialSelfTests {
    static func run(_ r: SelfTest.Reporter) {
        testWriteFailurePreservesPreviousCredential(r)
        testPartialMigrationRetriesWithoutLoss(r)
        testCredentialLockDoesNotClearSelection(r)
        testSerializedNewConfigHasReferencesOnly(r)
        testPersistedMigrationSaveFailureAndRuntimeRead(r)
        testMigrationConflictAndReadbackFailure(r)
        testProfileRevisionEdits(r)
        testExplicitRemovalTombstoneSurvivesFailedSave(r)
        testGuardedASRCredentialAccess(r)
        testConcurrentSnapshots(r)
    }

    // A delete-before-add implementation loses the existing value on these failures.
    static func testWriteFailurePreservesPreviousCredential(_ r: SelfTest.Reporter) {
        let fixture = CredentialFixture()
        let store = KeychainASRCredentialStore(access: fixture.access)
        do {
            try store.write("fixture-old", id: "existing")
            let generation = store.generation(id: "existing")
            fixture.state.withLock { $0.failUpdate = true }
            r.check((try? store.write("fixture-new", id: "existing")) == nil, "credential update error propagates")
            r.eq(try store.read(id: "existing"), "fixture-old", "failed update preserves previous credential")
            r.eq(store.generation(id: "existing"), generation, "failed update preserves generation")
            fixture.state.withLock { $0.failAdd = true }
            r.check((try? store.write("fixture-new", id: "absent")) == nil, "credential add error propagates")
            r.eq(try store.read(id: "existing"), "fixture-old", "failed add never deletes another credential")
            fixture.state.withLock { $0.failUpdate = false }
            try store.write("fixture-old", id: "existing")
            r.eq(store.generation(id: "existing"), generation, "same value preserves generation")
            try store.write("fixture-new", id: "existing")
            let snapshot = try store.snapshot(id: "existing")
            r.eq(snapshot.value, "fixture-new", "snapshot captures changed value")
            r.check(snapshot.generation != generation, "changed value rotates generation")
            try store.remove(id: "existing")
            r.eq(try store.snapshot(id: "existing").value, nil, "remove clears credential")
            r.check(store.generation(id: "existing") != snapshot.generation, "remove rotates generation")
        } catch { r.check(false, "credential failure fixture unexpectedly threw") }
    }

    static func testPartialMigrationRetriesWithoutLoss(_ r: SelfTest.Reporter) {
        let fixture = CredentialFixture()
        let store = KeychainASRCredentialStore(access: fixture.access)
        let first = "11111111-1111-1111-1111-111111111111"
        let second = "22222222-2222-2222-2222-222222222222"
        var config = Configuration()
        config.cloudASRConfig.providerAPIKeys = [first: "fixture-first", second: "fixture-second"]
        fixture.state.withLock { $0.failID = "asr.cloud." + second }
        let result = ASRCredentialMigration.migrate(configuration: config, store: store)
        r.eq(result.configuration.cloudASRConfig.providerAPIKeys[second], "fixture-second", "failed migration retained")
        r.eq(result.configuration.cloudASRConfig.providerAPIKeys[first], nil, "only confirmed migration removed")
        r.eq(result.pendingIDs, ["asr.cloud." + second], "retry only unfinished key")
        let generation = store.generation(id: "asr.cloud." + first)
        fixture.state.withLock { $0.failID = nil }
        let retry = ASRCredentialMigration.migrate(configuration: result.configuration, store: store)
        r.check(retry.configuration.cloudASRConfig.providerAPIKeys.isEmpty, "retry migrates remaining key")
        r.eq(retry.pendingIDs, [], "retry has no pending IDs")
        r.eq(store.generation(id: "asr.cloud." + first), generation, "retry does not rewrite migrated key")
        let again = ASRCredentialMigration.migrate(configuration: retry.configuration, store: store)
        r.eq(again.configuration.cloudASRConfig, retry.configuration.cloudASRConfig, "second migration is idempotent")
        var orphan = config
        orphan.cloudASRConfig.providerAPIKeys = ["orphan": "fixture-orphan"]
        r.eq(ASRCredentialMigration.migrate(configuration: orphan, store: store).configuration.cloudASRConfig.providerAPIKeys["orphan"], "fixture-orphan", "unknown legacy key remains recoverable")
    }

    static func testCredentialLockDoesNotClearSelection(_ r: SelfTest.Reporter) {
        let fixture = CredentialFixture()
        fixture.state.withLock { $0.failRead = true }
        let store = KeychainASRCredentialStore(access: fixture.access)
        var config = Configuration()
        let profile = CloudASRProviderConfig.defaultSiliconFlow()
        config.cloudASRConfig.providers = [profile]
        config.cloudASRConfig.providerAPIKeys[profile.id.uuidString] = "fixture-locked"
        config.asrBackendSelection = .init(primary: .init(rawValue: "cloud:" + profile.id.uuidString), fallback: nil, allowsCloudFallback: false)
        let result = ASRCredentialMigration.migrate(configuration: config, store: store)
        r.eq(result.configuration.asrBackendSelection, config.asrBackendSelection, "credential lock keeps selection")
        r.eq(result.configuration.cloudASRConfig.providerAPIKeys[profile.id.uuidString], "fixture-locked", "credential lock keeps legacy key")
        r.eq(result.pendingIDs.count, 1, "credential lock exposes retry status")
    }

    // Removing the last legacy copy before verified persistence loses retry ownership.
    static func testPersistedMigrationSaveFailureAndRuntimeRead(_ r: SelfTest.Reporter) {
        let suite = "com.flowtype.validation.asr.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CredentialFixture()
        let credentials = KeychainASRCredentialStore(access: fixture.access)
        var legacy = Configuration()
        let profile = CloudASRProviderConfig.defaultSiliconFlow()
        legacy.cloudASRConfig.providers = [profile]
        legacy.cloudASRConfig.providerAPIKeys[profile.id.uuidString] = "fixture-persisted"
        legacy.providerAPIKeys["llm-fixture"] = "fixture-llm-untouched"
        do {
            defaults.set(try JSONEncoder().encode(legacy), forKey: "flowtype.config")
            defaults.set(5, forKey: "flowtype.migrationVersion")
            var writes = 0
            let configStore = ConfigurationStore(defaults: defaults, asrCredentials: credentials, persistence: { data in
                writes += 1
                if writes == 2 { throw ASRCredentialError.persistence }
                defaults.set(data, forKey: "flowtype.config")
            })
            r.eq(configStore.current.cloudASRConfig.providerAPIKeys[profile.id.uuidString], "fixture-persisted", "failed save preserves in-memory legacy copy")
            let disk = try JSONDecoder().decode(Configuration.self, from: defaults.data(forKey: "flowtype.config")!)
            r.eq(disk.cloudASRConfig.providerAPIKeys[profile.id.uuidString], "fixture-persisted", "failed save preserves persisted legacy copy")
            r.check(configStore.asrPersistenceError != nil, "failed save exposes recoverable state")
            configStore.retryASRCredentialMigration()
            r.check(configStore.current.cloudASRConfig.providerAPIKeys.isEmpty, "retry commits reference-only cloud config")
            r.eq(configStore.current.providerAPIKeys["llm-fixture"], "fixture-llm-untouched", "ASR migration excludes LLM keys")
            r.eq(configStore.current.asrBackendSelection?.primary?.rawValue, "cloud:" + profile.id.uuidString, "selection persisted with stable legacy identity")
            let saved = try JSONDecoder().decode(Configuration.self, from: defaults.data(forKey: "flowtype.config")!)
            r.eq(saved.asrBackendSelection, configStore.current.asrBackendSelection, "selection migration saved")
            r.eq(try saved.cloudASRCredential(profileID: profile.id, store: credentials).value, "fixture-persisted", "runtime resolves migrated credential after dict emptied")
            let revision = saved.cloudASRConfig.providers[0].revision
            let reloaded = ConfigurationStore(defaults: defaults, asrCredentials: credentials)
            r.eq(reloaded.current.cloudASRConfig.providers[0].revision, revision, "migration revision persists across restart")
            fixture.state.withLock { $0.failRead = true }
            r.check((try? saved.cloudASRCredential(profileID: profile.id, store: credentials)) == nil, "runtime read denial propagates instead of empty credential")
        } catch { r.check(false, "persistence fixture unexpectedly threw") }
    }

    static func testMigrationConflictAndReadbackFailure(_ r: SelfTest.Reporter) {
        let fixture = CredentialFixture()
        let store = KeychainASRCredentialStore(access: fixture.access)
        let id = "11111111-1111-1111-1111-111111111111"
        var legacy = Configuration()
        legacy.cloudASRConfig.providerAPIKeys[id] = "fixture-stale"
        fixture.state.withLock { $0.values["asr.cloud." + id] = "fixture-newer" }
        let conflict = ASRCredentialMigration.migrate(configuration: legacy, store: store)
        r.eq(try? store.read(id: "asr.cloud." + id), "fixture-newer", "retry never overwrites newer credential")
        r.eq(conflict.configuration.cloudASRConfig.providerAPIKeys[id], "fixture-stale", "conflicting backup remains recoverable")
        r.eq(conflict.pendingIDs.count, 1, "conflict remains pending")
        fixture.state.withLock { $0.values = [:]; $0.failReadAfterAdd = true }
        let denied = ASRCredentialMigration.migrate(configuration: legacy, store: store)
        r.eq(denied.configuration.cloudASRConfig.providerAPIKeys[id], "fixture-stale", "readback denial preserves backup")
        r.eq(denied.pendingIDs.count, 1, "readback denial remains pending")
    }

    static func testProfileRevisionEdits(_ r: SelfTest.Reporter) {
        let checks = CloudASRConnectionCheck()
        let profile = CloudASRProviderConfig.defaultSiliconFlow()
        var config = CloudASRConfig(providers: [profile])
        var changed = profile
        changed.name = "Renamed"
        checks.updateProfile(changed, in: &config)
        r.eq(config.providers[0].revision, profile.revision, "rename preserves call revision")
        changed.model = "fixture-model"
        checks.updateProfile(changed, in: &config)
        r.check(config.providers[0].revision != profile.revision, "model edit rotates call revision")
        let revision = config.providers[0].revision
        checks.updateAPIKey("fixture-key", profileID: profile.id, in: &config)
        r.check(config.providers[0].revision != revision, "credential edit rotates call revision")
    }

    // A crash after deleting Keychain but before removing legacy JSON must not revive a key.
    static func testExplicitRemovalTombstoneSurvivesFailedSave(_ r: SelfTest.Reporter) {
        let suite = "com.flowtype.validation.asr.remove.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CredentialFixture()
        let credentials = KeychainASRCredentialStore(access: fixture.access)
        var config = Configuration()
        let profile = CloudASRProviderConfig.defaultSiliconFlow()
        config.cloudASRConfig.providers = [profile]
        config.cloudASRConfig.providerAPIKeys[profile.id.uuidString] = "fixture-remove"
        do {
            defaults.set(try JSONEncoder().encode(config), forKey: "flowtype.config")
            defaults.set(5, forKey: "flowtype.migrationVersion")
            fixture.state.withLock { $0.failRead = true }
            var failScrub = false
            var writes = 0
            let store = ConfigurationStore(defaults: defaults, asrCredentials: credentials, persistence: { data in
                writes += 1
                if failScrub && writes.isMultiple(of: 2) { throw ASRCredentialError.persistence }
                defaults.set(data, forKey: "flowtype.config")
            })
            fixture.state.withLock { $0.failRead = false }
            writes = 0
            failScrub = true
            var draft = ASRProviderDraft(target: .existing(profile.id), profile: profile)
            draft.keyEdit = .remove
            r.check((try? store.saveASRDraft(draft)) == nil, "failed removal scrub reports failure")
            r.eq(try credentials.read(id: profile.credentialID), "", "explicit removal writes durable tombstone")
            let restarted = ConfigurationStore(defaults: defaults, asrCredentials: credentials)
            r.eq(try restarted.cloudASRCredential(profileID: profile.id).value, "", "restart never resurrects removed legacy credential")
            r.eq(restarted.current.cloudASRConfig.providerAPIKeys[profile.id.uuidString], "fixture-remove", "failed scrub retains recoverable legacy copy")
            r.eq(restarted.pendingASRCredentialIDs, [profile.credentialID], "tombstone conflict remains visible for recovery")
        } catch { r.check(false, "removal fixture unexpectedly threw") }
    }

    static func testGuardedASRCredentialAccess(_ r: SelfTest.Reporter) {
        let downstream = OSAllocatedUnfairLock(initialState: 0)
        let access = ASRCredentialAccess(read: { _ in downstream.withLock { $0 += 1 }; return nil },
            update: { _, _ in downstream.withLock { $0 += 1 }; return false },
            add: { _, _ in downstream.withLock { $0 += 1 } }, remove: { _ in downstream.withLock { $0 += 1 } })
        for role in [ProcessRole.selfTest, .smokeTest] {
            let effects = ValidationEffects(role: role)
            let store = KeychainASRCredentialStore(access: .guarded(role: role, system: access, effects: effects))
            do {
                try store.write("fixture-only", id: "asr.hf.official")
                r.eq(try store.read(id: "asr.hf.official"), "fixture-only", "validation ASR store uses memory")
                try store.remove(id: "asr.hf.official")
                r.eq(try store.read(id: "asr.hf.official"), nil, "validation ASR store removes memory item")
            } catch { r.check(false, "guarded memory unexpectedly threw") }
            r.eq(effects.snapshot.permitted[.keychain, default: 0], 0, "validation ASR actual Keychain budget zero")
        }
        r.eq(downstream.withLock { $0 }, 0, "ASR SecItem downstream never entered")
    }

    static func testConcurrentSnapshots(_ r: SelfTest.Reporter) {
        let store = KeychainASRCredentialStore(access: .memory())
        let seen = OSAllocatedUnfairLock(initialState: [UUID: Set<String>]())
        DispatchQueue.concurrentPerform(iterations: 600) { index in
            if index.isMultiple(of: 2) { try? store.write("fixture-\(index)", id: "race") }
            if let snap = try? store.snapshot(id: "race") {
                _ = seen.withLock { $0[snap.generation, default: []].insert(snap.value ?? "<missing>") }
            }
        }
        r.check(seen.withLock { $0.values.allSatisfy { $0.count == 1 } }, "atomic snapshots never pair one generation with different values")
    }

    static func testSerializedNewConfigHasReferencesOnly(_ r: SelfTest.Reporter) {
        var config = Configuration()
        config.localASRServices = [.init(id: UUID(), revision: UUID(), name: "Fixture", baseURL: "http://127.0.0.1:8000",
            protocolKind: .openAICompatible, modelID: nil, authentication: .bearer(credentialID: "asr.service.fixture"), fieldCapabilities: .init())]
        do {
            let fixture = CredentialFixture()
            let store = KeychainASRCredentialStore(access: fixture.access)
            try store.write("arbitrary-prefix-fixture-token", id: "asr.service.fixture")
            try store.write("arbitrary-prefix-hf-token", id: "asr.hf.official")
            let data = try JSONEncoder().encode(config)
            let text = String(decoding: data, as: UTF8.self)
            r.check(text.contains("asr.service.fixture"), "serialized service retains credential reference")
            r.check(!text.contains("arbitrary-prefix"), "new configuration never serializes token contents")
            let suite = "com.flowtype.validation.asr.new.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var persistedBodies: [String] = []
            let configurationStore = ConfigurationStore(defaults: defaults, asrCredentials: store, persistence: { data in
                persistedBodies.append(String(decoding: data, as: UTF8.self))
                defaults.set(data, forKey: "flowtype.config")
            })
            var profile = CloudASRProviderConfig.defaultSiliconFlow()
            profile.name = "New fixture cloud profile"
            var draft = ASRProviderDraft(target: .new(profile.id), profile: profile)
            draft.keyEdit = .replace("arbitrary-prefix-new-cloud-token")
            try configurationStore.saveASRDraft(draft)
            r.check(persistedBodies.allSatisfy { !$0.contains("arbitrary-prefix") }, "every staged new cloud save excludes newly typed token")
            r.eq(try configurationStore.cloudASRCredential(profileID: profile.id).value, "arbitrary-prefix-new-cloud-token", "new cloud key is resolved from injected credential store")
            r.check(configurationStore.current.cloudASRConfig.providerAPIKeys.isEmpty, "new cloud settings retain references only")
        } catch { r.check(false, "serialization fixture unexpectedly threw") }
    }
}

/// Only the SecItem boundary is replaced; the real credential store owns mutation/revisions.
final class CredentialFixture: Sendable {
    struct State: Sendable {
        var values: [String: String] = [:]
        var failRead = false
        var failReadAfterAdd = false
        var failUpdate = false
        var failAdd = false
        var failID: String?
    }
    enum Failure: Error { case denied }
    let state = OSAllocatedUnfairLock(initialState: State())
    var access: ASRCredentialAccess {
        .init(read: { id in try self.state.withLock { s in
            if s.failRead { throw Failure.denied }; return s.values[id]
        } }, update: { id, value in try self.state.withLock { s in
            if s.failUpdate || s.failID == id { throw Failure.denied }
            guard s.values[id] != nil else { return false }; s.values[id] = value; return true
        } }, add: { id, value in try self.state.withLock { s in
            if s.failAdd || s.failID == id { throw Failure.denied }; s.values[id] = value; if s.failReadAfterAdd { s.failRead = true }
        } }, remove: { id in self.state.withLock { _ = $0.values.removeValue(forKey: id) } })
    }
}
