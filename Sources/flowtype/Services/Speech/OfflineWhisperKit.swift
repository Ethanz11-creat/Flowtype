import Foundation
@preconcurrency import WhisperKit
import Tokenizers

enum OfflineWhisperError: Error, LocalizedError {
    case invalidLocalDirectory, incompatibleGraph, incompatibleTokenizer, tokenizerUnavailable
    case invalidSampleRate, unsupportedLanguage
    case incompatibleRuntime
    var errorDescription: String? {
        switch self {
        case .invalidLocalDirectory: "请选择完整的本机 Whisper 模型和分词器目录。"
        case .incompatibleGraph: "Whisper 模型维度不受支持或编码器与解码器不匹配。"
        case .incompatibleTokenizer: "本机 Whisper 分词器与模型词表不匹配。"
        case .tokenizerUnavailable: "本机 Whisper 分词器缺失或损坏；不会联网补齐。"
        case .invalidSampleRate: "Whisper 需要 16kHz 单声道音频。"
        case .unsupportedLanguage: "此 Whisper 模型不支持所选语言。"
        case .incompatibleRuntime: "当前 WhisperKit 0.18 运行库的缓存布局不支持 Intel Mac；请使用 Apple Silicon 或其他识别引擎。"
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

/// Never calls super's tokenizer loader: upstream catches local errors and downloads.
final class OfflineWhisperKit: WhisperKit {
    private(set) var detectedMetadata: WhisperRuntimeMetadata?
    var detectedVariant: String? { detectedMetadata?.variant }

    override func loadTokenizerIfNeeded() async throws {
        guard let folder = tokenizerFolder, folder.isFileURL else { throw OfflineWhisperError.invalidLocalDirectory }
        detectedMetadata = nil
        guard let mel = (featureExtractor as? WhisperGraphDescribing)?.rawGraphDescription,
              let encoder = (audioEncoder as? WhisperGraphDescribing)?.rawGraphDescription,
              let decoder = (textDecoder as? WhisperGraphDescribing)?.rawGraphDescription else { throw OfflineWhisperError.incompatibleGraph }
        let prefill = (textDecoder.prefillData as? WhisperGraphDescribing)?.rawGraphDescription
        guard textDecoder.prefillData == nil || prefill != nil else { throw OfflineWhisperError.incompatibleGraph }
        let metadata = try WhisperGraphContract.validate(mel: mel, encoder: encoder, decoder: decoder, prefill: prefill)
        let local = try await Self.localTokenizer(at: folder)
        try local.validate(for: metadata)
        textDecoder.isModelMultilingual = metadata.isMultilingual
        tokenizer = local
        detectedMetadata = metadata
    }

    static func localTokenizer(at directory: URL) async throws -> LocalWhisperTokenizer {
        guard directory.isFileURL else { throw OfflineWhisperError.invalidLocalDirectory }
        do {
            // The modelFolder overload reads only these files, never a repo ID/cache.
            for file in ["tokenizer.json", "tokenizer_config.json"] {
                guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(file).path) else {
                    throw OfflineWhisperError.tokenizerUnavailable
                }
            }
            let files = LocalInspectionFiles()
            let json = try files.json(directory.appendingPathComponent("tokenizer.json"))
            try validateTokenizerMetadata(json)
            let config = try files.json(directory.appendingPathComponent("tokenizer_config.json"))
            guard ["WhisperTokenizer", "WhisperTokenizerFast"].contains(config["tokenizer_class"] as? String ?? "") else {
                throw OfflineWhisperError.incompatibleTokenizer
            }
            let local = try LocalWhisperTokenizer(tokenizer: await AutoTokenizer.from(modelFolder: directory))
            try files.verify()
            return local
        } catch {
            if error is CancellationError { throw error }
            throw OfflineWhisperError.tokenizerUnavailable
        }
    }

    /// Validate before entering dependency constructors that fatalError on malformed metadata.
    static func validateTokenizerMetadata(_ json: [String: Any]) throws {
        guard let model = json["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Any] else { throw OfflineWhisperError.incompatibleTokenizer }
        var tokens: [Int: String] = [:]
        var identifiers: [String: Int] = [:]
        func record(_ token: String, _ value: Any) throws {
            let id = try LocalInspectionFiles.integer(value)
            guard (0..<51866).contains(id), !token.isEmpty else { throw OfflineWhisperError.incompatibleTokenizer }
            let index = Int(id)
            guard tokens[index] == nil || tokens[index] == token,
                  identifiers[token] == nil || identifiers[token] == index else { throw OfflineWhisperError.incompatibleTokenizer }
            tokens[index] = token
            identifiers[token] = index
        }
        for (token, id) in vocab { try record(token, id) }
        if let added = json["added_tokens"] {
            guard let added = added as? [[String: Any]] else { throw OfflineWhisperError.incompatibleTokenizer }
            for token in added {
                guard let content = token["content"] as? String, let id = token["id"] else { throw OfflineWhisperError.incompatibleTokenizer }
                try record(content, id)
            }
        }
        guard [51864, 51865, 51866].contains(tokens.count), Set(tokens.keys) == Set(0..<tokens.count) else {
            throw OfflineWhisperError.incompatibleTokenizer
        }
        guard let merges = model["merges"] as? [Any] else { throw OfflineWhisperError.incompatibleTokenizer }
        for value in merges {
            let pair: [String]
            if let strings = value as? [String] { pair = strings }
            else if let string = value as? String { pair = string.components(separatedBy: " ") }
            else { throw OfflineWhisperError.incompatibleTokenizer }
            guard pair.count == 2, pair.allSatisfy({ !$0.isEmpty && vocab[$0] != nil }),
                  vocab[pair.joined()] != nil else { throw OfflineWhisperError.incompatibleTokenizer }
        }
        // Whisper's byte-level pipeline is the supported format. Reject other pipeline
        // classes before upstream factory switches can trap on corrupt/unknown values.
        guard let pre = json["pre_tokenizer"] as? [String: Any], pre["type"] as? String == "ByteLevel",
              let decoder = json["decoder"] as? [String: Any], decoder["type"] as? String == "ByteLevel",
              json["normalizer"] == nil || json["normalizer"] is NSNull else { throw OfflineWhisperError.incompatibleTokenizer }
        if let post = json["post_processor"], !(post is NSNull) {
            guard let post = post as? [String: Any] else { throw OfflineWhisperError.incompatibleTokenizer }
            switch post["type"] as? String {
            case "ByteLevel": break
            case "TemplateProcessing":
                guard let single = post["single"] as? [[String: Any]],
                      post["pair"] is [[String: Any]] else { throw OfflineWhisperError.incompatibleTokenizer }
                var sequenceCount = 0
                for item in single {
                    if let sequence = item["Sequence"] as? [String: Any], sequence["id"] as? String == "A" {
                        sequenceCount += 1
                    } else if let special = item["SpecialToken"] as? [String: Any],
                              let token = special["id"] as? String, identifiers[token] != nil { /* skipped for prompt encoding */ }
                    else { throw OfflineWhisperError.incompatibleTokenizer }
                }
                guard sequenceCount == 1 else { throw OfflineWhisperError.incompatibleTokenizer }
            default: throw OfflineWhisperError.incompatibleTokenizer
            }
        }
        let rawBytes = Array(33...126) + Array(161...172) + Array(174...255)
        let alphabet = Set((rawBytes + Array(256..<(256 + 256 - rawBytes.count))).compactMap(Unicode.Scalar.init))
        guard alphabet.allSatisfy({ vocab[String($0)] != nil }),
              tokens.values.allSatisfy({ $0.unicodeScalars.allSatisfy(alphabet.contains) }) else {
            throw OfflineWhisperError.incompatibleTokenizer
        }
    }

}

/// The only caller after construction is the provider's exclusive task chain.
/// Actor isolation additionally prevents external synchronous access to framework state;
/// it is not relied on as a mutex across framework awaits.
actor WhisperKitBackend: OfflineWhisperBackend {
    nonisolated let verifiedMetadata: WhisperRuntimeMetadata?
    private let kit: OfflineWhisperKit
    // The backend is retained by active/captured leases and by in-flight inference.
    private let preparedModels: PreparedWhisperModels

    private init(kit: sending OfflineWhisperKit, metadata: WhisperRuntimeMetadata, preparedModels: PreparedWhisperModels) {
        self.kit = kit
        self.preparedModels = preparedModels
        verifiedMetadata = metadata
    }

    static func load(_ options: WhisperOfflineLoadOptions) async throws -> WhisperKitBackend {
        try WhisperGraphContract.validateRuntimeABI()
        // Fail on local tokenizer errors before compiling or allocating model memory.
        _ = try await OfflineWhisperKit.localTokenizer(at: options.tokenizerDirectory)
        let prepared = try await WhisperModelPreparation.prepare(directory: options.modelDirectory)
        let kit = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: prepared.directory.path,
            tokenizerFolder: options.tokenizerDirectory, verbose: false, logLevel: .none,
            prewarm: false, load: options.load, download: options.download))
        try Task.checkCancellation()
        try await kit.loadModels()
        try Task.checkCancellation()
        guard let metadata = kit.detectedMetadata else { throw OfflineWhisperError.incompatibleGraph }
        return WhisperKitBackend(kit: kit, metadata: metadata, preparedModels: prepared)
    }

    func transcribe(samples: [Float], language: String?, prompt: String?) async throws -> [String] {
        guard !samples.isEmpty else { return [] }
        guard let tokenizer = kit.tokenizer else { throw OfflineWhisperError.tokenizerUnavailable }
        let code = try Self.languageCode(language, tokenizer: tokenizer, isMultilingual: verifiedMetadata?.isMultilingual == true)
        let options = DecodingOptions(verbose: false, language: code,
            detectLanguage: code == nil && verifiedMetadata?.isMultilingual == true,
            skipSpecialTokens: true, promptTokens: prompt.map { tokenizer.encode(text: $0) },
            concurrentWorkerCount: 1)
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return Self.textSegments(results)
    }

    nonisolated static func languageCode(_ language: String?, tokenizer: any WhisperTokenizer, isMultilingual: Bool) throws -> String? {
        if let language, !language.isEmpty, language.lowercased() != "auto" {
            let normalized = language.lowercased()
            let code = Constants.languages[normalized] ?? normalized
            let token = "<|\(code)|>"
            guard Constants.languages.values.contains(code), isMultilingual || code == "en",
                  let id = tokenizer.convertTokenToId(token), tokenizer.convertIdToToken(id) == token else {
                throw OfflineWhisperError.unsupportedLanguage
            }
            return code
        }
        return nil
    }

    nonisolated static func textSegments(_ results: [TranscriptionResult]) -> [String] {
        results.flatMap { result in
            result.segments.isEmpty ? [result.text] : result.segments.map(\.text)
        }
    }
}
