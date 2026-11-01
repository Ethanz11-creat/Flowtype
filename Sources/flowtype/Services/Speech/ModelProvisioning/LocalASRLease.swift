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

    init(id: UUID, identity: LocalModelIdentity, provider: any ASRProvider,
         whisperMetadata: WhisperRuntimeMetadata? = nil) {
        self.id = id
        self.identity = identity
        self.provider = provider
        self.whisperMetadata = whisperMetadata
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
