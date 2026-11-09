import Foundation

/// Owns the exact profile and credential captured before recording accepts audio.
struct CapturedCloudASRProvider: ASRProvider {
    let configuration: CloudASRRequestConfiguration
    let underlying: any ASRProvider
    var id: String { "cloud:" + configuration.provider.id.uuidString }
    var displayName: String { configuration.provider.name }
    var capabilities: ASRCapabilities {
        configuration.provider.protocolKind == .dashScopeRealtime ? DashScopeRealtimeASR.capabilities : underlying.capabilities
    }
    var isAvailable: Bool { get async { true } }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        guard configuration.provider.protocolKind != .dashScopeRealtime else { throw CloudASRError.unsupportedRealtimeTransport }
        let captured = ASRRequest(samples: request.samples, sampleRate: request.sampleRate, language: request.language,
            context: request.context, timeout: request.timeout, cloudConfiguration: configuration)
        let result = try await underlying.transcribe(captured)
        return ASRResult(text: result.text, providerID: id, latencyMs: result.latencyMs)
    }
}

extension ASRBackendBinding {
    var cloudConfiguration: CloudASRRequestConfiguration? { (provider as? CapturedCloudASRProvider)?.configuration }
    var isRealtime: Bool { cloudConfiguration?.provider.protocolKind == .dashScopeRealtime }
}
