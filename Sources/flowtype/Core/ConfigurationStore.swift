import Foundation
import Combine

class ConfigurationStore: ObservableObject, @unchecked Sendable {
    static let shared = ConfigurationStore()

    @Published var current: Configuration

    private let defaultsKey = "flowtype.config"
    private let migrationVersionKey = "flowtype.migrationVersion"
    private let currentMigrationVersion = 5
    private let keychainServicePrefix = "llmProvider."

    private let defaults: UserDefaults
    private let backupDirectory: URL?

    init(defaults: UserDefaults = .standard, backupDirectory: URL? = nil) {
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
                    _ = KeychainHelper.save(key: "llmApiKey", value: config.llmApiKey)
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
                    if let legacyApiKey = KeychainHelper.load(key: "llmApiKey"), !legacyApiKey.isEmpty {
                        let providerKey = "\(self.keychainServicePrefix)\(oldProvider.id.uuidString)"
                        _ = KeychainHelper.save(key: providerKey, value: legacyApiKey)
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
                if let encoded = try? JSONEncoder().encode(config) {
                    defaults.set(encoded, forKey: defaultsKey)
                }
            }
            self.current = config
        }
    }

    /// Persists a copy of an undecodable config blob so the user's settings are
    /// recoverable for diagnosis, instead of being silently discarded.
    private static func backupCorruptConfig(_ data: Data, error: Error, directory: URL?) {
        let dir = directory ?? URL(fileURLWithPath:
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/flowtype"))
        let stamp = Int(Date().timeIntervalSince1970)
        let backupURL = dir.appendingPathComponent("flowtype.config.corrupt-\(stamp).json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: backupURL)
        AppLogger.log("[ConfigurationStore] Failed to decode persisted config (\(error)); backed up raw blob to \(backupURL.path) and reset to default")
    }

    private var saveWorkItem: DispatchWorkItem?

    func save(_ config: Configuration) {
        self.current = config

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(config) {
                self.defaults.set(data, forKey: self.defaultsKey)
            }
        }
        self.saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - Provider API Key Helpers

    func keychainKey(for providerID: UUID) -> String {
        return "\(keychainServicePrefix)\(providerID.uuidString)"
    }

    func saveProviderAPIKey(_ apiKey: String, for providerID: UUID) {
        let key = keychainKey(for: providerID)
        if !apiKey.isEmpty {
            _ = KeychainHelper.save(key: key, value: apiKey)
        } else {
            KeychainHelper.delete(key: key)
        }
    }

    func loadProviderAPIKey(_ providerID: UUID) -> String? {
        let key = keychainKey(for: providerID)
        return KeychainHelper.load(key: key)
    }

    func deleteProviderAPIKey(_ providerID: UUID) {
        let key = keychainKey(for: providerID)
        KeychainHelper.delete(key: key)
    }
}
