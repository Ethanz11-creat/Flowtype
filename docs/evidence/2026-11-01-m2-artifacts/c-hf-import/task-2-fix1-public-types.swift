import Foundation
@preconcurrency import WhisperKit
import Tokenizers

enum OfflineWhisperError: Error, LocalizedError {
    case invalidLocalDirectory, incompatibleGraph, incompatibleTokenizer, tokenizerUnavailable
    case invalidSampleRate, unsupportedLanguage
    var errorDescription: String? {
        switch self {
        case .invalidLocalDirectory: "请选择完整的本机 Whisper 模型和分词器目录。"
        case .incompatibleGraph: "Whisper 模型维度不受支持或编码器与解码器不匹配。"
        case .incompatibleTokenizer: "本机 Whisper 分词器与模型词表不匹配。"
        case .tokenizerUnavailable: "本机 Whisper 分词器缺失或损坏；不会联网补齐。"
        case .invalidSampleRate: "Whisper 需要 16kHz 单声道音频。"
        case .unsupportedLanguage: "此 Whisper 模型不支持所选语言。"
        }
    }
}

/// Graph-derived identity only. Dimensions cannot distinguish v1/v2 or v3/turbo;
/// family labels deliberately avoid pretending to verify a particular checkpoint.
struct WhisperRuntimeMetadata: Sendable, Equatable, Codable {
    let variant: String
    let logitsSize: Int
    let encoderSize: Int
    let isMultilingual: Bool

    init(logitsSize: Int, encoderSize: Int, decoderSize: Int) throws {
        guard encoderSize == decoderSize else { throw OfflineWhisperError.incompatibleGraph }
        let sizes = [384: "tiny", 512: "base", 768: "small", 1024: "medium"]
        switch (logitsSize, encoderSize) {
        case (51864, _):
            guard let size = sizes[encoderSize] else { throw OfflineWhisperError.incompatibleGraph }
            variant = size + ".en"
        case (51865, 1280): variant = "large-v1/v2"
        case (51865, _):
            guard let size = sizes[encoderSize] else { throw OfflineWhisperError.incompatibleGraph }
            variant = size
        case (51866, 1280): variant = "large-v3"
        default: throw OfflineWhisperError.incompatibleGraph
        }
        self.logitsSize = logitsSize
        self.encoderSize = encoderSize
        isMultilingual = logitsSize != 51864
    }
}

