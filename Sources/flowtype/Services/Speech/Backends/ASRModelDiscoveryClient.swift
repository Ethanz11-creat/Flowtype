import Foundation

enum ASRModelDiscoveryError: Error, LocalizedError {
    case responseTooLarge, tooManyModels
    var errorDescription: String? {
        switch self {
        case .responseTooLarge: "模型列表超过 1 MiB，请手动填写模型 ID"
        case .tooManyModels: "模型列表超过 1000 项，请手动填写模型 ID"
        }
    }
}

/// Explicit candidate discovery only. A returned ID is no evidence of ASR support.
/// The caller owns revision/invalidation of a displayed list; this client stores no state.
final class ASRModelDiscoveryClient: Sendable {
    private let session: URLSession
    private let injected: Bool
    private let resolver: LocalASRServiceEndpoint.Resolver
    private static let byteLimit = 1024 * 1024

    init(session: URLSession? = nil, resolver: @escaping LocalASRServiceEndpoint.Resolver = LocalASRServiceEndpoint.resolve) {
        let configuration = ASRHTTPTransport.loopbackConfiguration()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        self.session = session ?? URLSession(configuration: configuration)
        injected = session != nil
        self.resolver = resolver
    }
    deinit { if !injected { session.invalidateAndCancel() } }

    func models(profile: LocalASRServiceProfile, credential: String?) async throws -> [String] {
        try Task.checkCancellation()
        let transcription = try LocalASRServiceEndpoint.transcriptionURL(profile: profile)
        // whisper.cpp owns its model server-side. Never probe /load or invent a model list.
        guard profile.protocolKind != .whisperCpp else { return [] }
        let key: String?
        switch profile.authentication {
        case .none: key = nil
        case .bearer: try Self.validateCredential(credential); key = credential
        }
        let destination = try LocalASRServiceEndpoint.destination(for: Self.modelsURL(transcription), resolver: resolver)
        var request = Self.request(url: destination.url, credential: key)
        request.setValue(destination.hostHeader, forHTTPHeaderField: "Host")
        return try await fetch(request, originalHost: destination.originalHost)
    }

    func models(cloudProfile: CloudASRProviderConfig, apiKey: String) async throws -> [String] {
        try Task.checkCancellation()
        guard cloudProfile.protocolKind == .openAICompatible else { throw CloudASRError.unsupportedRealtimeTransport }
        try Self.validateCredential(apiKey)
        let transcription = try CloudASREndpoint.transcriptionURL(cloudProfile.baseURL)
        return try await fetch(Self.request(url: Self.modelsURL(transcription), credential: apiKey), originalHost: nil)
    }

    private static func validateCredential(_ value: String?) throws {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw CloudASRError.noAPIKey }
    }

    private static func modelsURL(_ transcription: URL) -> URL {
        // Work from the already validated/normalized endpoint, preserving escaped proxy prefixes.
        var parts = URLComponents(url: transcription, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast("/audio/transcriptions".count)) + "/models"
        return parts.url!
    }

    private static func request(url: URL, credential: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func fetch(_ request: URLRequest, originalHost: String?) async throws -> [String] {
        guard injected || ValidationEffects.live.allow(.network) else { throw CloudASRError.networkError(URLError(.notConnectedToInternet)) }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: ASRHTTPTaskPolicy(originalHost: originalHost))
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CloudASRError.invalidResponse }
            if [404, 405].contains(response.statusCode) { return [] }
            guard (200...299).contains(response.statusCode) else { throw CloudASRError.apiError(statusCode: response.statusCode, message: "") }
            guard response.expectedContentLength <= Int64(Self.byteLimit) else { throw ASRModelDiscoveryError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.byteLimit else { throw ASRModelDiscoveryError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            struct Model: Decodable { let id: String }
            struct List: Decodable { let data: [Model] }
            guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw CloudASRError.invalidResponse }
            guard list.data.count <= 1000 else { throw ASRModelDiscoveryError.tooManyModels }
            var seen = Set<String>()
            return try list.data.compactMap { model in
                guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudASRError.invalidResponse }
                return seen.insert(model.id).inserted ? model.id : nil
            }
        } catch {
            let underlying = error as NSError
            if error is CancellationError || Task.isCancelled || underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled { throw CancellationError() }
            if let error = error as? CloudASRError { throw error }
            if let error = error as? ASRModelDiscoveryError { throw error }
            if underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorTimedOut { throw CloudASRError.timeout }
            throw CloudASRError.networkError(NSError(domain: NSURLErrorDomain, code: underlying.domain == NSURLErrorDomain ? underlying.code : NSURLErrorUnknown))
        }
    }
}
