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
    let engineVersion: String
    let minimumResidentBytes: UInt64?

    init(id: UUID, identity: LocalModelIdentity, provider: any ASRProvider,
         whisperMetadata: WhisperRuntimeMetadata? = nil, minimumResidentBytes: UInt64? = nil, engineVersion: String? = nil, drain: @escaping @Sendable () async -> Void = {}) {
        self.drain = drain
        self.id = id
        self.identity = identity
        self.provider = provider
        self.whisperMetadata = whisperMetadata
        self.minimumResidentBytes = minimumResidentBytes
        self.engineVersion = engineVersion ?? LocalASRRuntimeFactory.engineVersion(
            for: identity.engine == LocalASREngine.whisperCoreML.rawValue ? .whisperCoreML : .qwenMLX)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
