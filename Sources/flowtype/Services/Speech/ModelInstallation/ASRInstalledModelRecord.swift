import Foundation

enum ModelStorageOwnership: String, Codable, Sendable { case managed, external }

struct ASRInstalledModelRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let importedModelID: UUID
    let ownership: ModelStorageOwnership
    let installPlan: ASRInstallPlan?
    let directory: URL
    var validation: ASRNativeValidationRecord?
}

struct ASRNativeValidationRecord: Codable, Equatable, Sendable {
    let fileFingerprint: String
    let engineVersion: String
    let sampleSHA256: String
    let validatedAt: Date
    let latencyMs: Int
}
