import Foundation

/// provider 实例容器。路由决策不在这里 —— 见 `ASRRouter`（Task A4）。
final class ASRProviderRegistry: @unchecked Sendable {
    static let shared = ASRProviderRegistry()

    let qwenLocalProvider: QwenASRProvider
    let cloudProvider: CloudASRProvider
    /// 仅用于录音中的实时预览与「全部候选失败」时的文本兜底，不是路由候选。
    let applePreviewProvider: AppleSpeechProvider

    private init() {
        self.qwenLocalProvider = QwenASRProvider()
        self.cloudProvider = CloudASRProvider()
        self.applePreviewProvider = AppleSpeechProvider()
    }

    var routingCandidates: [ASRProvider] { [qwenLocalProvider, cloudProvider] }
    var previewProvider: AppleSpeechProvider { applePreviewProvider }

    func provider(forID id: String) -> ASRProvider? {
        switch id {
        case "qwen-local": return qwenLocalProvider
        case "cloud-asr": return cloudProvider
        default: return nil
        }
    }
}
