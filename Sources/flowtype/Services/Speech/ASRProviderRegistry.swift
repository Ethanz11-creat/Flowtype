import Foundation

/// provider 实例容器。路由决策不在这里 —— 见 `ASRRouter`（Task A4）。
final class ASRProviderRegistry: @unchecked Sendable {
    static let shared = ASRProviderRegistry()

    let qwenLocalProvider: QwenASRProvider
    let cloudProvider: CloudASRProvider

    private init() {
        self.qwenLocalProvider = QwenASRProvider()
        self.cloudProvider = CloudASRProvider()
    }

    func realtimeCapabilities(for protocolKind: CloudASRProtocolKind) -> ASRCapabilities? {
        protocolKind == .dashScopeRealtime ? DashScopeRealtimeASR.capabilities : nil
    }

    func makeRealtimeSession(configuration: RealtimeASRConfiguration,
                             transport: any WebSocketTransport = URLSessionWebSocketTransport(),
                             startTimeout: TimeInterval = 10,
                             finalTimeout: TimeInterval = 10) -> RealtimeASRSessionHandle {
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
