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

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
