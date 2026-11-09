import Combine
import Foundation

struct CloudASRCheckToken: Equatable, Sendable {
    let profileID: UUID
    let revision: UUID
}

/// Shared settings actions. Tokens and diagnostics never contain credentials.
@MainActor
final class CloudASRConnectionCheck: ObservableObject {
    enum State: Equatable {
        case idle, testing, configurationValid, connected
        case failure(String)
    }

    @Published private var states: [UUID: State] = [:]
    @Published private var inFlight: [UUID: CloudASRCheckToken] = [:]
    private var revisions: [UUID: UUID] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private let service: CloudASRProvider
    private let recognitionTest: @MainActor (CloudASRProviderConfig, String) async -> Result<String, CloudASRError>

    init(service: CloudASRProvider = CloudASRProvider(),
         recognitionTest: (@MainActor (CloudASRProviderConfig, String) async -> Result<String, CloudASRError>)? = nil) {
        self.service = service
        self.recognitionTest = recognitionTest ?? { provider, key in
            await service.testConnection(provider: provider, apiKey: key)
        }
    }

    func begin(profileID: UUID) -> CloudASRCheckToken {
        let token = CloudASRCheckToken(profileID: profileID, revision: UUID())
        revisions[profileID] = token.revision
        return token
    }

    func invalidate(profileID: UUID) {
        revisions.removeValue(forKey: profileID)
        states.removeValue(forKey: profileID)
        operations[profileID]?.cancel()
        // Keep the transport slot until its owner finishes, even after edits/deletion.
    }

    func accepts(_ token: CloudASRCheckToken) -> Bool {
        revisions[token.profileID] == token.revision
    }

    func state(for profileID: UUID) -> State { states[profileID] ?? .idle }
    func isTesting(_ profileID: UUID) -> Bool { inFlight[profileID] != nil }

    func checkConfiguration(provider: CloudASRProviderConfig, apiKey: String) {
        guard !isTesting(provider.id) else { return }
        _ = begin(profileID: provider.id)
        switch service.validateConfiguration(provider: provider, apiKey: apiKey) {
        case .success: states[provider.id] = .configurationValid
        case .failure(let error): states[provider.id] = .failure(error.localizedDescription)
        }
    }

    /// Reserve ownership synchronously with the click, before an edit can interleave.
    @discardableResult
    func testRecognition(provider: CloudASRProviderConfig, apiKey: String) -> Task<Void, Never>? {
        guard !isTesting(provider.id) else { return nil }
        guard provider.protocolKind == .openAICompatible else {
            checkConfiguration(provider: provider, apiKey: apiKey)
            return nil
        }
        let token = begin(profileID: provider.id)
        inFlight[provider.id] = token
        states[provider.id] = .testing
        let operation = Task {
            defer {
                // A stale completion may release only its own operation.
                if inFlight[provider.id] == token {
                    inFlight.removeValue(forKey: provider.id)
                    operations.removeValue(forKey: provider.id)
                }
            }
            // Editing before the queued task starts also suppresses the old upload.
            guard accepts(token) else { return }
            guard !Task.isCancelled else { states[provider.id] = .idle; return }
            let result = await recognitionTest(provider, apiKey)
            guard inFlight[provider.id] == token, accepts(token) else { return }
            guard !Task.isCancelled else { states[provider.id] = .idle; return }
            switch result {
            case .success: states[provider.id] = .connected
            case .failure(.cancelled): states[provider.id] = .idle
            case .failure(let error): states[provider.id] = .failure(error.localizedDescription)
            }
        }
        operations[provider.id] = operation
        return operation
    }

    func updateProfile(_ profile: CloudASRProviderConfig, in config: inout CloudASRConfig) {
        guard let index = config.providers.firstIndex(where: { $0.id == profile.id }),
              config.providers[index] != profile else { return }
        invalidate(profileID: profile.id)
        var updated = profile
        updated.revision = config.providers[index].hasSameCallConfiguration(as: profile) ? config.providers[index].revision : UUID()
        config.providers[index] = updated
    }

    func selectModel(_ model: String, profileID: UUID, in config: inout CloudASRConfig) {
        guard var profile = config.providers.first(where: { $0.id == profileID }) else { return }
        profile.model = model
        updateProfile(profile, in: &config)
    }

    func updateAPIKey(_ key: String, profileID: UUID, in config: inout CloudASRConfig) {
        guard config.providers.contains(where: { $0.id == profileID }),
              config.providerAPIKeys[profileID.uuidString] != key else { return }
        invalidate(profileID: profileID)
        config.providerAPIKeys[profileID.uuidString] = key
        if let index = config.providers.firstIndex(where: { $0.id == profileID }) { config.providers[index].revision = UUID() }
    }

    func setActive(_ active: Bool, profileID: UUID, in config: inout CloudASRConfig) {
        guard config.providers.contains(where: { $0.id == profileID }) else { return }
        for var profile in config.providers {
            if profile.id == profileID { profile.isActive = active }
            else if active { profile.isActive = false }
            updateProfile(profile, in: &config)
        }
    }

    func deleteProfile(_ profileID: UUID, in config: inout CloudASRConfig) {
        let wasActive = config.providers.first(where: { $0.id == profileID })?.isActive == true
        invalidate(profileID: profileID)
        config.providers.removeAll(where: { $0.id == profileID })
        config.providerAPIKeys.removeValue(forKey: profileID.uuidString)
        if wasActive, let next = config.providers.first {
            setActive(true, profileID: next.id, in: &config)
        }
    }

    /// Also covers configuration changes made by another settings surface.
    func synchronize(old: CloudASRConfig, new: CloudASRConfig) {
        for profile in old.providers {
            if new.providers.first(where: { $0.id == profile.id }) != profile
                || old.providerAPIKeys[profile.id.uuidString] != new.providerAPIKeys[profile.id.uuidString] {
                invalidate(profileID: profile.id)
            }
        }
    }
}


/// Application-lived settings owners. Result revisions remain independent for
/// live profiles and drafts; neither a tab change nor window recreation drops
/// a cancellation-resistant transport reservation.
@MainActor
final class SettingsConnectionChecks {
    static let shared = SettingsConnectionChecks(configuration: .shared,
        checks: CloudASRConnectionCheck(), draftChecks: CloudASRConnectionCheck())

    let checks: CloudASRConnectionCheck
    let draftChecks: CloudASRConnectionCheck
    private var configurationObservation: AnyCancellable?
    private var previous: CloudASRConfig

    init(configuration: ConfigurationStore, checks: CloudASRConnectionCheck, draftChecks: CloudASRConnectionCheck) {
        self.checks = checks
        self.draftChecks = draftChecks
        previous = configuration.current.cloudASRConfig
        configurationObservation = configuration.$current.sink { [weak self] configuration in
            guard let self else { return }
            let old = previous
            let new = configuration.cloudASRConfig
            previous = new
            // The owner observes edits even when no settings page is installed.
            checks.synchronize(old: old, new: new)
            draftChecks.synchronize(old: old, new: new)
        }
    }
}
