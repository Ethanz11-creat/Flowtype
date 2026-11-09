import Foundation

enum ModelInstallState: String, Codable, Equatable, Sendable {
    case queued, downloading, paused, verifying, installed, failed, cancelled
}

struct ModelInstallSnapshot: Codable, Equatable, Sendable {
    let jobID: UUID
    let plan: ASRInstallPlan
    var state: ModelInstallState
    var receivedBytes: Int64
    var errorCode: String?
}

/// Coordinator-owned, distinct from HFDownloadJournal. Paths are derived from jobID, never decoded.
struct ModelInstallationJobJournal: Codable, Sendable {
    let version: Int
    var snapshot: ModelInstallSnapshot
    let createdAt: Date
    var libraryDetached: Bool
}
