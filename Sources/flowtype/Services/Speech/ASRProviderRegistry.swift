import Foundation

final class ASRProviderRegistry: @unchecked Sendable {
    static let shared = ASRProviderRegistry()

    let qwenLocalProvider: QwenASRProvider
    let cloudProvider: CloudASRProvider
    let applePreviewProvider: AppleSpeechProvider

    private init() {
        self.qwenLocalProvider = QwenASRProvider()
        self.cloudProvider = CloudASRProvider()
        self.applePreviewProvider = AppleSpeechProvider()
    }

    @MainActor
    var activeTranscriptionProvider: ASRProvider {
        switch ConfigurationStore.shared.current.asrEngine {
        case .local: return qwenLocalProvider
        case .cloud: return cloudProvider
        }
    }

    func activeTranscriptionProviderAsync() async -> ASRProvider {
        await MainActor.run { activeTranscriptionProvider }
    }

    var previewProvider: AppleSpeechProvider { applePreviewProvider }

    var allProviders: [ASRProvider] { [qwenLocalProvider, cloudProvider, applePreviewProvider] }
}
