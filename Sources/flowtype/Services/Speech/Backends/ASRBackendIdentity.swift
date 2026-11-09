import Foundation

/// Persistent reference; display names, list positions and availability are not identity.
struct ASRBackendID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

enum ASRBackendLocation: String, Codable, Sendable {
    case native, loopbackService, cloud
}

enum ASRServiceProtocol: String, Codable, Sendable {
    case openAICompatible, whisperCpp, dashScopeRealtime
}

enum ASRServiceAuthentication: Codable, Equatable, Sendable {
    case none
    case bearer(credentialID: String)
}

/// A user-managed loopback service. Stores credential references only.
struct LocalASRServiceProfile: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var revision: UUID
    var name: String
    var baseURL: String
    var protocolKind: ASRServiceProtocol
    var modelID: String?
    var authentication: ASRServiceAuthentication
    var fieldCapabilities: CloudASRFieldCapabilities
}


extension ASRBackendID {
    init(nativeLease lease: LocalASRLease) {
        rawValue = UUID(uuidString: lease.identity.id) != nil
            ? "native:import:" + lease.identity.id
            : "native:preset:" + lease.identity.id
    }
}
