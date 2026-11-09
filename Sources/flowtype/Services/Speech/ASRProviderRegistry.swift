import Foundation

/// provider 实例容器。路由决策不在这里 —— 见 `ASRRouter`（Task A4）。
final class ASRProviderRegistry: @unchecked Sendable {
    static let shared = try! ASRProviderRegistry(adapters: [OpenAICompatibleASRAdapter(), WhisperCppASRAdapter()])

    /// Legacy compatibility instance. Live local routing always uses a captured lease.
    let qwenLocalProvider: QwenASRProvider
    let cloudProvider: CloudASRProvider

    private let adapters: [ASRServiceProtocol: any ASRServiceAdapter]

    init(adapters: [any ASRServiceAdapter]) throws {
        var registered: [ASRServiceProtocol: any ASRServiceAdapter] = [:]
        for adapter in adapters {
            guard registered[adapter.protocolKind] == nil else { throw ASRServiceAdapterError.duplicateProtocol }
            guard adapter.protocolKind != .dashScopeRealtime else { throw ASRServiceAdapterError.unsupportedProtocol }
            registered[adapter.protocolKind] = adapter
        }
        self.adapters = registered
        self.qwenLocalProvider = QwenASRProvider()
        self.cloudProvider = CloudASRProvider()
    }

    func makeLocalServiceBinding(profile: LocalASRServiceProfile, credential: String?, credentialGeneration: UUID?) throws -> ASRBackendBinding {
        guard let adapter = adapters[profile.protocolKind] else { throw ASRServiceAdapterError.unsupportedProtocol }
        let provider = try adapter.makeProvider(profile: profile, credential: credential)
        let descriptor = ASRBackendDescriptor(id: .init(rawValue: "service:" + profile.id.uuidString), revision: profile.revision,
            displayName: profile.name, modelID: profile.protocolKind == .whisperCpp ? nil : profile.modelID,
            location: .loopbackService, requiresInternet: false, capabilities: provider.capabilities, maxUploadBytes: nil)
        return .init(descriptor: descriptor, provider: provider, nativeLease: nil, credentialGeneration: credentialGeneration)
    }

    func realtimeCapabilities(for protocolKind: CloudASRProtocolKind) -> ASRCapabilities? {
        protocolKind == .dashScopeRealtime ? DashScopeRealtimeASR.capabilities : nil
    }

    func makeRealtimeSession(configuration: RealtimeASRConfiguration,
                             transport: any WebSocketTransport = URLSessionWebSocketTransport(),
                             startTimeout: TimeInterval = 3,
                             finalTimeout: TimeInterval = 20) -> RealtimeASRSessionHandle {
        let session = DashScopeRealtimeASR(configuration: configuration, transport: transport,
                                          startTimeout: startTimeout, finalTimeout: finalTimeout)
        return RealtimeASRSessionHandle(session: session, ingress: session.ingress,
                                        capabilities: DashScopeRealtimeASR.capabilities)
    }

    func provider(forID id: String) -> ASRProvider? {
        switch id {
        case ASRProviderID.qwenLocal: return qwenLocalProvider
        case ASRProviderID.cloud: return cloudProvider
        default: return nil
        }
    }
}

typealias RealtimeSessionFactory = @Sendable (RealtimeASRConfiguration) -> RealtimeASRSessionHandle
let liveRealtimeSessionFactory: RealtimeSessionFactory = {
    ASRProviderRegistry.shared.makeRealtimeSession(configuration: $0)
}
