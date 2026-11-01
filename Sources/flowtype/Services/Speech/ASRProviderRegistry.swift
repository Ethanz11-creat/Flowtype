import Foundation

/// provider 实例容器。路由决策不在这里 —— 见 `ASRRouter`（Task A4）。
final class ASRProviderRegistry: @unchecked Sendable {
    static let shared = ASRProviderRegistry()

    private let localLock = NSLock()
    private var localProvider: QwenASRProvider
    var qwenLocalProvider: QwenASRProvider { localLock.withLock { localProvider } }

    // Interim bridge until routing takes immutable LocalASRLease snapshots.
    func adoptLocalProvider(_ provider: QwenASRProvider) { localLock.withLock { localProvider = provider } }
    let cloudProvider: CloudASRProvider

    private init() {
        self.localProvider = QwenASRProvider()
        self.cloudProvider = CloudASRProvider()
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
