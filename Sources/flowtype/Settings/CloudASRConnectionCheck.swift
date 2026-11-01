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
    private let service: CloudASRProvider

    init(service: CloudASRProvider = CloudASRProvider()) {
        self.service = service
    }

    func begin(profileID: UUID) -> CloudASRCheckToken {
        let token = CloudASRCheckToken(profileID: profileID, revision: UUID())
        revisions[profileID] = token.revision
        return token
    }

    func invalidate(profileID: UUID) {
        revisions.removeValue(forKey: profileID)
        states.removeValue(forKey: profileID)
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
        return Task {
            defer {
                // A stale completion may release only its own operation.
                if inFlight[provider.id] == token { inFlight.removeValue(forKey: provider.id) }
            }
            // Editing before the queued task starts also suppresses the old upload.
            guard accepts(token) else { return }
            let result = await service.testConnection(provider: provider, apiKey: apiKey)
            guard inFlight[provider.id] == token, accepts(token) else { return }
            switch result {
            case .success: states[provider.id] = .connected
            case .failure(.cancelled): states[provider.id] = .idle
            case .failure(let error): states[provider.id] = .failure(error.localizedDescription)
            }
        }
    }

    func updateProfile(_ profile: CloudASRProviderConfig, in config: inout CloudASRConfig) {
        guard let index = config.providers.firstIndex(where: { $0.id == profile.id }),
              config.providers[index] != profile else { return }
        invalidate(profileID: profile.id)
        config.providers[index] = profile
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
