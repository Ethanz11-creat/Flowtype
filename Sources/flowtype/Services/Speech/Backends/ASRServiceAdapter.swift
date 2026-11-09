import Foundation

protocol ASRServiceAdapter: Sendable {
    var protocolKind: ASRServiceProtocol { get }
    func makeProvider(profile: LocalASRServiceProfile, credential: String?) throws -> any ASRProvider
}

enum ASRServiceAdapterError: Error { case duplicateProtocol, unsupportedProtocol }

/// Immutable provider captured from a local service profile; does not access persistence.
struct LocalServiceASRProvider: ASRProvider {
    let profile: LocalASRServiceProfile
    let credential: String?
    let endpoint: URL
    let transport: ASRHTTPTransport
    let resolver: LocalASRServiceEndpoint.Resolver
    var id: String { "service:" + profile.id.uuidString }
    var displayName: String { profile.name }
    var capabilities: ASRCapabilities {
        .init(supportsLanguageHint: profile.fieldCapabilities.sendLanguage,
              supportsContextHint: profile.fieldCapabilities.sendPrompt, requiresNetwork: true, location: .localService)
    }
    var isAvailable: Bool { get async { true } }

    init(profile: LocalASRServiceProfile, credential: String?, session: URLSession?, resolver: @escaping LocalASRServiceEndpoint.Resolver) throws {
        self.profile = profile; self.resolver = resolver
        endpoint = try LocalASRServiceEndpoint.transcriptionURL(profile: profile)
        if profile.protocolKind == .openAICompatible, profile.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw CloudASRError.noModel }
        switch profile.authentication {
        case .none: self.credential = nil
        case .bearer:
            guard let credential, !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !credential.contains(where: { $0.isNewline || $0 == "\0" }) else { throw CloudASRError.noAPIKey }
            self.credential = credential
        }
        transport = ASRHTTPTransport(session: session)
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        try Task.checkCancellation()
        guard request.sampleRate == 16000 else { throw CloudASRError.audioEncodingFailed }
        let start = Date()
        let destination = try LocalASRServiceEndpoint.destination(for: endpoint, resolver: resolver)
        var fields = profile.fieldCapabilities
        if profile.protocolKind == .whisperCpp { fields.sendResponseFormat = true }
        var upload = try ASRMultipartRequest.make(url: destination.url,
            model: profile.protocolKind == .whisperCpp ? nil : profile.modelID, fields: fields,
            samples: request.samples, language: request.language, context: request.context, credential: credential,
            timeout: request.timeout, maxUploadBytes: nil)
        upload.setValue(destination.hostHeader, forHTTPHeaderField: "Host")
        let text = try await transport.transcribe(upload, originalHost: destination.originalHost)
        try Task.checkCancellation()
        return .init(text: text, providerID: id, latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}
