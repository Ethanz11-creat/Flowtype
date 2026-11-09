import Foundation

struct ASRBackendDescriptor: Sendable, Equatable {
    let id: ASRBackendID
    let revision: UUID
    let displayName: String
    let modelID: String?
    let location: ASRBackendLocation
    /// Internet reachability differs from the socket requirement of loopback services.
    let requiresInternet: Bool
    let capabilities: ASRCapabilities
    let maxUploadBytes: Int64?
}

extension ASRBackendDescriptor {
    init(nativeLease: LocalASRLease, id: ASRBackendID) {
        self.init(id: id, revision: nativeLease.id, displayName: nativeLease.identity.displayName,
                  modelID: nativeLease.identity.id, location: .native, requiresInternet: false,
                  capabilities: nativeLease.provider.capabilities, maxUploadBytes: nil)
    }
}

/// Retains the captured provider and native resources for an entire recording.
struct ASRBackendBinding: Sendable, Equatable {
    let descriptor: ASRBackendDescriptor
    let provider: any ASRProvider
    let nativeLease: LocalASRLease?
    let credentialGeneration: UUID?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.descriptor == rhs.descriptor && lhs.nativeLease?.id == rhs.nativeLease?.id
            && lhs.credentialGeneration == rhs.credentialGeneration
    }
}
