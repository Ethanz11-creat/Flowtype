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

    func provider(forID id: String) -> ASRProvider? {
        switch id {
        case ASRProviderID.qwenLocal: return qwenLocalProvider
        case ASRProviderID.cloud: return cloudProvider
        default: return nil
        }
    }
}
