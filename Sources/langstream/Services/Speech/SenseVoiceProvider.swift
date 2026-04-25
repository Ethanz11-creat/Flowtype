import Foundation

final class SenseVoiceProvider: SiliconFlowSpeechProvider {
    init(configuration: Configuration = .shared) {
        super.init(
            name: "SenseVoice",
            model: configuration.asrFallbackModel,
            configuration: configuration
        )
    }
}
