import Foundation

/// One multipart contract shared by dictation and the explicit synthetic-audio connection test.
/// This type is pure: all credentials, capabilities and content come from the captured value.
enum CloudTranscriptionRequestBuilder {
    static func validate(provider: CloudASRProviderConfig, apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains(where: { $0.isNewline }) else { throw CloudASRError.noAPIKey }
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudASRError.noModel }
        switch provider.protocolKind {
        case .openAICompatible: _ = try CloudASREndpoint.transcriptionURL(provider.baseURL)
        case .dashScopeRealtime:
            _ = try CloudASREndpoint.validateRealtimeURL(provider.baseURL)
            // Validation must also accept the original saved value at the runtime boundary;
            // endpoint normalization alone can hide whitespace rejected by realtime capture.
            guard (try? RealtimeASRConfiguration(provider: provider, apiKey: apiKey, language: nil)) != nil else {
                throw CloudASRError.invalidURL("无效的 WSS 实时识别地址")
            }
        }
    }

    static func make(configuration: CloudASRRequestConfiguration, samples: [Float], language: String?,
                     context: ASRContext?, timeout: TimeInterval) throws -> URLRequest {
        guard configuration.provider.protocolKind == .openAICompatible else { throw CloudASRError.unsupportedRealtimeTransport }
        try validate(provider: configuration.provider, apiKey: configuration.apiKey)
        let url = try CloudASREndpoint.transcriptionURL(configuration.provider.baseURL)
        return try ASRMultipartRequest.make(url: url, model: configuration.provider.model,
            fields: configuration.fieldCapabilities, samples: samples, language: language,
            context: configuration.sendContext ? context : nil, credential: configuration.apiKey,
            timeout: timeout, maxUploadBytes: CloudASRVendor.maxUploadBytes(for: configuration.provider))
    }
}
