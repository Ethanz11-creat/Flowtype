import Foundation

struct LocalModelIdentity: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: String
    let repoID: String?
    let directory: URL
}

/// A recording can retain this immutable value while a replacement model is provisioned.
struct LocalASRLease: Sendable, Equatable {
    let id: UUID
    let identity: LocalModelIdentity
    let provider: any ASRProvider
    let whisperMetadata: WhisperRuntimeMetadata?
    /// Wait for real native work, which may outlive a cancelled caller continuation.
    let drain: @Sendable () async -> Void
    let usageToken: ModelUsageToken?
    let engineVersion: String
    let minimumResidentBytes: UInt64?

    init(id: UUID, identity: LocalModelIdentity, provider: any ASRProvider,
         whisperMetadata: WhisperRuntimeMetadata? = nil, minimumResidentBytes: UInt64? = nil, engineVersion: String? = nil, usageToken: ModelUsageToken? = nil, drain: @escaping @Sendable () async -> Void = {}) {
        self.usageToken = usageToken
        self.drain = drain
        self.id = id
        self.identity = identity
        self.provider = usageToken.map { NativeUsageProvider(base: provider, token: $0, drain: drain) as any ASRProvider } ?? provider
        self.whisperMetadata = whisperMetadata
        self.minimumResidentBytes = minimumResidentBytes
        self.engineVersion = engineVersion ?? LocalASRRuntimeFactory.engineVersion(
            for: identity.engine == LocalASREngine.whisperCoreML.rawValue ? .whisperCoreML : .qwenMLX)
    }

    func retainingUsage(_ token: ModelUsageToken, identity: LocalModelIdentity? = nil) -> Self {
        Self(id: id, identity: identity ?? self.identity, provider: (provider as? NativeUsageProvider)?.base ?? provider, whisperMetadata: whisperMetadata,
             minimumResidentBytes: minimumResidentBytes, engineVersion: engineVersion, usageToken: token, drain: drain)
    }
    func captured(externalModelID: UUID? = nil) throws -> Self {
        if let usageToken { return retainingUsage(try usageToken.captured()) }
        // A raw legacy lease is registered as an external source. Routing supplies an
        // existing library UUID when known; otherwise the immutable lease UUID is stable.
        let modelID = externalModelID ?? id
        return retainingUsage(try NativeModelUsageRegistry.shared.registerExternalCapture(modelID: modelID))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
