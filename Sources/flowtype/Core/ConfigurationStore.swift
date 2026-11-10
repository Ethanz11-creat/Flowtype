import Foundation
import Combine

class ConfigurationStore: ObservableObject, @unchecked Sendable {
    static let shared = ConfigurationStore(defaults: RuntimeEnvironment.defaults,
                                            backupDirectory: RuntimeEnvironment.current.paths.logsDirectory)

    @Published var current: Configuration

    private let defaultsKey = "flowtype.config"
    private let migrationVersionKey = "flowtype.migrationVersion"
    private let currentMigrationVersion = 5
    private let keychainServicePrefix = "llmProvider."

    private let defaults: UserDefaults
    private let backupDirectory: URL?
    let asrCredentials: any ASRCredentialStore
    private let persistData: (Data) throws -> Void
    private(set) var pendingASRCredentialIDs: [String] = []
    private(set) var asrPersistenceError: String?

    init(defaults: UserDefaults = RuntimeEnvironment.defaults, backupDirectory: URL? = nil, keychain: KeychainAccess = .helper,
         asrCredentials: any ASRCredentialStore = KeychainASRCredentialStore.shared,
         persistence: ((Data) throws -> Void)? = nil) {
        self.asrCredentials = asrCredentials
        self.persistData = persistence ?? { data in
            defaults.set(data, forKey: "flowtype.config")
            guard defaults.synchronize(), defaults.data(forKey: "flowtype.config") == data else { throw ASRCredentialError.persistence }
        }
        self.defaults = defaults
        self.backupDirectory = backupDirectory

        guard let data = defaults.data(forKey: defaultsKey) else {
            // No persisted config = first launch; a clean default is the correct outcome.
            self.current = Configuration.default
            return
        }

        let decoded: Configuration
        do {
            decoded = try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            // Corrupt blob: preserve it for diagnosis instead of silently wiping the
            // user's entire configuration.
            Self.backupCorruptConfig(data, error: error, directory: backupDirectory)
            self.current = Configuration.default
            return
        }

        do {
            var config = decoded
            let storedVersion = defaults.integer(forKey: migrationVersionKey)
            var needsSave = false

            if storedVersion < 1 {
                if config.asrLanguage == .auto {
                    config.asrLanguage = .zh
                }
                needsSave = true
            }

            // Migration 2: move API key from UserDefaults JSON to Keychain
            if storedVersion < 2 {
                if !config.llmApiKey.isEmpty {
                    _ = keychain.save("llmApiKey", config.llmApiKey)
                    AppLogger.log("[ConfigurationStore] Migrated API key to Keychain")
                }
                needsSave = true
            }

            // Migration 3: migrate from single-provider to multi-provider format
            if storedVersion < 3 {
                if config.llmProviders.isEmpty {
                    let oldProvider = LLMProvider(
                        id: UUID(),
                        name: "默认配置",
                        provider: config.llmProvider,
                        baseURL: config.llmBaseURL,
                        model: config.llmModel,
                        isActive: true
                    )
                    if let legacyApiKey = keychain.load("llmApiKey"), !legacyApiKey.isEmpty {
                        let providerKey = "\(self.keychainServicePrefix)\(oldProvider.id.uuidString)"
                        _ = keychain.save(providerKey, legacyApiKey)
                        AppLogger.log("[ConfigurationStore] Migrated legacy API key to provider \(oldProvider.id)")
                    }
                    config.llmProviders = [oldProvider]
                    needsSave = true
                }
            }

            if storedVersion < 4 {
                // Migration 4: new fields have default values, just bump version
                needsSave = true
            }

            if storedVersion < 5 {
                if config.maxRecordingDuration == 0 {
                    config.maxRecordingDuration = 600
                }
                needsSave = true
            }

            defaults.set(currentMigrationVersion, forKey: migrationVersionKey)

            if config.systemPrompt.isEmpty {
                config.systemPrompt = Configuration.default.systemPrompt
                needsSave = true
            }

            if needsSave {
                if let encoded = try? JSONEncoder().encode(config) { try? persistData(encoded) }
            }
            self.current = config
            retryASRCredentialMigration()
        }
    }

    /// Persists a copy of an undecodable config blob so the user's settings are
    /// recoverable for diagnosis, instead of being silently discarded.
    private static func backupCorruptConfig(_ data: Data, error: Error, directory: URL?) {
        let dir = directory ?? RuntimeEnvironment.current.paths.logsDirectory
        let stamp = Int(Date().timeIntervalSince1970)
        let backupURL = dir.appendingPathComponent("flowtype.config.corrupt-\(stamp).json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // An undecodable blob cannot safely identify arbitrary-prefix tokens by regex.
        // Keep diagnostic size/format only; never emit user string values or decoder details.
        let text = "[REDACTED undecodable configuration: \(data.count) bytes]"
        try? text.data(using: .utf8)?.write(to: backupURL)
        AppLogger.log("[ConfigurationStore] Failed to decode persisted config; saved redacted diagnostic")
    }

    private func persist(_ config: Configuration) throws {
        let data = try JSONEncoder().encode(config)
        try persistData(data)
        guard defaults.data(forKey: defaultsKey) == data else { throw ASRCredentialError.persistence }
    }

    /// Native trial evidence and selection become visible only after one durable write.
    @MainActor func commitNativeASRActivation(_ candidate: Configuration) throws {
        try persist(candidate)
        current = candidate
    }

    /// Installation success is reported only after the complete library pair is durable.
    @MainActor func registerInstalledASRModel(_ record: ASRInstalledModelRecord, model: ImportedASRModel) throws {
        let candidate = try LocalModelLibrary.registering(record, model: model, in: current)
        try persist(candidate)
        current = candidate
    }

    /// Persist identity/revisions with legacy recovery copies before touching credentials.
    func retryASRCredentialMigration() {
        var source = current
        source.migrateASRBackendSelectionIfNeeded()
        do {
            try persist(source)
            current = source
            let result = ASRCredentialMigration.migrate(configuration: source, store: asrCredentials)
            try persist(result.configuration)
            current = result.configuration
            pendingASRCredentialIDs = result.pendingIDs
            asrPersistenceError = nil
        } catch {
            pendingASRCredentialIDs = source.cloudASRConfig.providerAPIKeys.keys.sorted().map { "asr.cloud." + $0 }
            asrPersistenceError = ASRCredentialError.persistence.localizedDescription
        }
    }

    func cloudASRCredential(profileID: UUID) throws -> ASRCredentialSnapshot {
        try current.cloudASRCredential(profileID: profileID, store: asrCredentials)
    }

    /// A committed profile's credential is immutable during a draft transaction.
    /// Stage a fresh credential version, then commit its reference and call fields
    /// together in one config blob. Every restart sees a matching endpoint/key pair.
    func saveASRDraft(_ draft: ASRProviderDraft) throws {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        var candidate = current
        try ProviderDraftCommit.apply(draft, to: &candidate)
        guard let index = candidate.cloudASRConfig.providers.firstIndex(where: { $0.id == draft.target.id }) else {
            throw ProviderDraftCommitError.deleted
        }
        let oldID = try candidate.cloudASRConfig.providers[index].validatedCredentialID()
        let stored = try asrCredentials.snapshot(id: oldID)
        let snapshot: ASRCredentialSnapshot
        if candidate.cloudASRConfig.providers[index].credentialReferenceID != nil {
            // Missing selected versions never read legacy backups. An explicit
            // replace/remove may repair the missing item; preserve must fail.
            snapshot = stored
        } else {
            snapshot = try current.cloudASRCredential(profileID: draft.target.id, store: asrCredentials)
        }
        let editedValue: String?
        switch draft.keyEdit {
        case .preserve: editedValue = snapshot.value
        case .replace(let value): editedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? snapshot.value : value
        case .remove: editedValue = ""
        }
        if candidate.cloudASRConfig.providers[index].credentialReferenceID != nil && editedValue == nil {
            throw ASRCredentialError.invalidData
        }
        let credentialChanged = editedValue != snapshot.value
        if credentialChanged { candidate.cloudASRConfig.providers[index].revision = UUID() }
        candidate.cloudASRConfig.providerAPIKeys.removeValue(forKey: draft.target.id.uuidString)

        // This first durable write contains only the previously committed call pair
        // and its recovery copies. It cannot publish any draft endpoint/model changes.
        try persist(current)
        do {
            if let editedValue, credentialChanged || stored.value == nil {
                let reference = "asr.cloud." + draft.target.id.uuidString + "." + UUID().uuidString
                try asrCredentials.write(editedValue, id: reference)
                guard try asrCredentials.read(id: reference) == editedValue else { throw ASRCredentialError.unavailable }
                candidate.cloudASRConfig.providers[index].credentialReferenceID = reference
            }
        } catch {
            asrPersistenceError = ASRCredentialError.unavailable.localizedDescription
            throw ASRCredentialError.unavailable
        }
        do { try persist(candidate) }
        catch {
            // Old config/key remain usable. An unreferenced staged item can be
            // collected later; deleting or overwriting committed keys is unsafe.
            asrPersistenceError = ASRCredentialError.persistence.localizedDescription
            throw ASRCredentialError.persistence
        }
        current = candidate
        pendingASRCredentialIDs.removeAll { $0 == oldID }
        asrPersistenceError = nil
    }

    /// Persist an explicit legacy-control action atomically before publishing it.
    func applyASRSettingsAction(_ action: ASRSettingsAction, activeNativeID: ASRBackendID? = nil) throws {
        var candidate = current
        try action.apply(to: &candidate, activeNativeID: activeNativeID)
        try persist(candidate)
        current = candidate
    }

    func setASRBackendSelection(_ selection: ASRBackendSelection) throws {
        var candidate = current
        candidate.setASRBackendSelection(selection)
        try persist(candidate)
        current = candidate
    }

    /// Called only after a successful native lease is already available.
    func resolveLegacyNativeSelection(lease: LocalASRLease) {
        var candidate = current
        candidate.migrateASRBackendSelectionIfNeeded()
        guard candidate.pendingLegacyNativeResolution else { return }
        candidate.resolveLegacyNativeSelection(lease: lease)
        do { try persist(candidate); current = candidate }
        catch { asrPersistenceError = ASRCredentialError.persistence.localizedDescription }
    }

    private var saveWorkItem: DispatchWorkItem?

    func save(_ config: Configuration) {
        self.current = config

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.retryASRCredentialMigration()
        }
        self.saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Write `current` to disk immediately, cancelling any pending debounced save.
    /// Must be called on app termination — otherwise a change made within the 0.5s
    /// debounce window (including a just-saved API key) is silently lost.
    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        retryASRCredentialMigration()
    }

    // MARK: - Provider API Key Helpers

    func keychainKey(for providerID: UUID) -> String {
        return "\(keychainServicePrefix)\(providerID.uuidString)"
    }

    // API keys are now stored LOCALLY in the config (Configuration.providerAPIKeys), not the Keychain.
    // The data-protection keychain needs an entitlement unsigned apps lack (SecItemAdd -34018), which is
    // why keys weren't persisting. `save(_:)` updates `current` synchronously + debounces the disk write.
    func saveProviderAPIKey(_ apiKey: String, for providerID: UUID) {
        var c = current
        if apiKey.isEmpty {
            c.providerAPIKeys.removeValue(forKey: providerID.uuidString)
        } else {
            c.providerAPIKeys[providerID.uuidString] = apiKey
        }
        save(c)
    }

    func loadProviderAPIKey(_ providerID: UUID) -> String? {
        let v = current.providerAPIKeys[providerID.uuidString]
        return (v?.isEmpty == false) ? v : nil
    }

    func deleteProviderAPIKey(_ providerID: UUID) {
        var c = current
        c.providerAPIKeys.removeValue(forKey: providerID.uuidString)
        save(c)
    }
}
