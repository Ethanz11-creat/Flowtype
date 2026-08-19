import Foundation

@available(*, deprecated, message: "Use ASRProviderRegistry instead")
final class SpeechRouter: @unchecked Sendable {
    static let shared = SpeechRouter()

    let qwenProvider: QwenASRProvider
    let fallbackProvider: AppleSpeechProvider

    private init() {
        self.qwenProvider = ASRProviderRegistry.shared.qwenLocalProvider
        self.fallbackProvider = ASRProviderRegistry.shared.applePreviewProvider
    }
}
