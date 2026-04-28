import Foundation
import AVFoundation

final class SpeechRouter: @unchecked Sendable {
    let primaryProvider = TeleSpeechProvider()
    let fallbackProvider = SenseVoiceProvider()
}
