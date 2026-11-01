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
        let audio = samples.withUnsafeBytes { Data($0) }
        guard let wav = WAVEncoder.encode(samples: audio, sampleRate: 16000) else { throw CloudASRError.audioEncodingFailed }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", configuration.provider.model)
        let capabilities = configuration.fieldCapabilities
        if capabilities.sendResponseFormat { field("response_format", "json") }
        if capabilities.sendTemperature { field("temperature", "0.0") }
        if capabilities.sendLanguage, let language { field("language", language) }
        if capabilities.sendPrompt, configuration.sendContext, let prompt = composeProviderContext(context) { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}
