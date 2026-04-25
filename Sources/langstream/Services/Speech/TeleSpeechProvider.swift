import Foundation

final class TeleSpeechProvider: SiliconFlowSpeechProvider {
    init(configuration: Configuration = .shared) {
        super.init(
            name: "TeleSpeech",
            model: configuration.asrPrimaryModel,
            prompt: "请识别标准中文普通话，去除重复字词和语气词，保持语句通顺自然。",
            configuration: configuration
        )
    }
}
