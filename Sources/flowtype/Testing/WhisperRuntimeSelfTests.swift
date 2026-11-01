import Foundation
import Tokenizers
import Hub
import WhisperKit
import CoreML
import os

/// Synthetic backend probes the product's queue/forwarding; never loads Core ML or audio files.
enum WhisperRuntimeSelfTests {
    static func run(_ r: SelfTest.Reporter) async {
        await runTokenizer(r)
        let identity = LocalModelIdentity(id: "fixture", displayName: "Whisper fixture", engine: "whisperCoreML", repoID: nil, directory: URL(fileURLWithPath: "/fixture"))
        let backend = WhisperProbeBackend()
        let provider = WhisperASRProvider(identity: identity, backend: backend)
        do {
            let result = try await provider.transcribe(ASRRequest(samples: [Float](repeating: 0, count: 16_000 * 61), sampleRate: 16000, language: "zh", context: ASRContext(phrases: ["热词"], foreground: nil), timeout: 60))
            r.eq(result.text, "首段 中段 尾段", "Whisper retains all segments in order")
            let input = await backend.lastInput
            r.eq(input?.count, 976_000, "Whisper forwards audio beyond 30 seconds without truncation")
            r.eq(input?.language, "zh", "Whisper forwards non-English language")
            r.eq(input?.prompt, "热词", "Whisper forwards context prompt")
            r.eq(result.providerID, ASRProviderID.local, "Whisper uses local routing slot")
            r.eq(provider.capabilities.requiresNetwork, false, "Whisper is offline")
        } catch { r.check(false, "Whisper forwarding: \(error)") }
        let empty = WhisperASRProvider(identity: identity, backend: WhisperProbeBackend(segments: []))
        do {
            let output = try await empty.transcribe(request())
            r.eq(output.text, "", "Whisper empty results are safe")
        } catch { r.check(false, "Whisper empty results") }
        // A suspended inference ignores cancellation, matching underlying compute that cannot stop.
        let suspended = WhisperProbeBackend(suspended: true)
        let serial = WhisperASRProvider(identity: identity, backend: suspended)
        let first = Task { try await serial.transcribe(request()) }
        guard await suspended.waitForStarts(1) else {
            r.check(false, "Whisper first inference starts within deadline"); first.cancel(); await suspended.release(); return
        }
        first.cancel()
        do { _ = try await withAsyncDeadline(seconds: 3) { try await first.value }; r.check(false, "Whisper in-flight cancellation") }
        catch { r.check(error is CancellationError, "Whisper in-flight cancellation returns promptly") }
        let cancelled = Task { try await serial.transcribe(request()) }
        for _ in 0..<50 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await withAsyncDeadline(seconds: 3) { try await cancelled.value }; r.check(false, "Whisper queued cancellation") }
        catch { r.check(error is CancellationError, "Whisper queued cancellation returns promptly") }
        let next = Task { try await serial.transcribe(request()) }
        for _ in 0..<50 { await Task.yield() }
        r.eq(await suspended.starts, 1, "Whisper new session waits for old cancelled compute")
        await suspended.release()
        guard await suspended.waitForStarts(2) else {
            r.check(false, "Whisper next inference starts within deadline"); next.cancel(); await suspended.release(); return
        }
        await suspended.release()
        do {
            let output = try await withAsyncDeadline(seconds: 3) { try await next.value }
            r.eq(output.text, "首段 中段 尾段", "Whisper late completion cannot overwrite next session")
        } catch { r.check(false, "Whisper next session resumes") }
        r.eq(await suspended.maxConcurrent, 1, "Whisper actual access serialized across suspension/cancellation")
        r.eq(await suspended.starts, 2, "Whisper cancelled queued work never enters backend")
    }

    private static func runTokenizer(_ r: SelfTest.Reporter) async {
        var missingMerges = fixtureTokenizerData()
        var incompleteModel = missingMerges["model"] as! [String: Any]
        incompleteModel.removeValue(forKey: "merges")
        missingMerges["model"] = incompleteModel
        do {
            try OfflineWhisperKit.validateTokenizerMetadata(missingMerges as! [String: Any])
            r.check(false, "Whisper rejects missing merges before upstream fatalError")
        } catch { r.check(true, "Whisper rejects missing merges before upstream fatalError") }
        do {
            let segments = WhisperKitBackend.textSegments([
                TranscriptionResult(text: "unused aggregate", segments: [.init(text: "首段"), .init(text: "中段")], language: "zh", timings: TranscriptionTimings()),
                TranscriptionResult(text: "尾段", segments: [], language: "zh", timings: TranscriptionTimings())
            ])
            r.eq(segments, ["首段", "中段", "尾段"], "Whisper flattens every framework result and ordered segment")
            r.eq(WhisperKitBackend.textSegments([]), [], "Whisper framework empty array is safe")
            let tokenizer = try LocalWhisperTokenizer(tokenizer: fixtureTokenizer())
            let graph = try WhisperRuntimeMetadata(logitsSize: 51865, encoderSize: 768, decoderSize: 768)
            try tokenizer.validate(for: graph)
            r.eq(graph.variant, "small", "Whisper non-tiny graph identity")
            r.check(graph.isMultilingual, "Whisper non-English graph supports language hints")
            r.eq(try WhisperRuntimeMetadata(logitsSize: 51864, encoderSize: 512, decoderSize: 512).variant, "base.en", "Whisper English graph identity")
            r.eq(try WhisperRuntimeMetadata(logitsSize: 51866, encoderSize: 1280, decoderSize: 1280).variant, "large-v3", "Whisper v3 vocabulary identity")
            for dimensions in [(51865, 777, 777), (51866, 384, 384), (51864, 1280, 1280), (51865, 512, 768), (50000, 512, 512)] {
                do {
                    _ = try WhisperRuntimeMetadata(logitsSize: dimensions.0, encoderSize: dimensions.1, decoderSize: dimensions.2)
                    r.check(false, "Whisper rejects incompatible graph dimensions")
                } catch { r.check(true, "Whisper rejects incompatible graph dimensions") }
            }
            do {
                try tokenizer.validate(for: WhisperRuntimeMetadata(logitsSize: 51864, encoderSize: 768, decoderSize: 768))
                r.check(false, "Whisper rejects English/multilingual vocabulary mismatch")
            } catch { r.check(true, "Whisper rejects English/multilingual vocabulary mismatch") }
            do {
                _ = try LocalWhisperTokenizer(tokenizer: fixtureTokenizer(omit: "<|nospeech|>"))
                r.check(false, "Whisper rejects missing special token instead of guessing")
            } catch { r.check(true, "Whisper rejects missing special token instead of guessing") }
            let unicode = tokenizer.splitToWordTokens(tokenIds: [32, 160, 121, 254, 172, 253, 247, 224])
            r.eq(unicode.words.joined(), "A你🙂", "Whisper split handles byte-split CJK/emoji after ASCII")
            r.eq(unicode.wordTokens.flatMap { $0 }, [32, 160, 121, 254, 172, 253, 247, 224], "Whisper word splitting retains every token")
            let replacement = tokenizer.splitToWordTokens(tokenIds: [171, 123, 121, 32])
            r.eq(replacement.words.joined(), "�A", "Whisper split preserves literal replacement character")
            r.eq(replacement.wordTokens.flatMap { $0 }, [171, 123, 121, 32], "Whisper replacement split retains tokens")
        } catch { r.check(false, "Whisper tokenizer fixture: \(error)") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-whisper-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = URLProtocol.registerClass(WhisperNetworkTrap.self)
        defer { URLProtocol.unregisterClass(WhisperNetworkTrap.self) }
        WhisperNetworkTrap.count.withLock { $0 = 0 }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for corrupt in [false, true] {
                if corrupt {
                    try Data("{broken".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
                    try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
                }
                let kit = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                    audioEncoder: WhisperFixtureEncoder(), textDecoder: WhisperFixtureDecoder(),
                    verbose: false, prewarm: false, load: false, download: false))
                do {
                    // Real override must reject local failure without calling upstream fallback.
                    try await kit.loadTokenizerIfNeeded()
                    r.check(false, "Whisper missing/corrupt tokenizer fails closed")
                } catch { r.check(true, "Whisper missing/corrupt tokenizer fails closed") }
                do {
                    _ = try await OfflineWhisperKit.localTokenizer(at: root)
                    r.check(false, "Whisper local parse failure is terminal")
                } catch { r.check(true, "Whisper local parse failure is terminal") }
            }
            r.eq(WhisperNetworkTrap.count.withLock { $0 }, 0, "Whisper tokenizer failure sends zero network requests")
            let model = ImportedASRModel(name: "Selected", directory: root, engine: .whisperCoreML,
                variant: "unverified", sizeBytes: 1, tokenizerDirectory: root.appendingPathComponent("selected-tokenizer"), fileFingerprint: "fixture")
            try writeTokenizer(to: root)
            let decoder = WhisperFixtureDecoder()
            let loaded = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                audioEncoder: WhisperFixtureEncoder(), textDecoder: decoder,
                verbose: false, prewarm: false, load: false, download: false))
            try await loaded.loadTokenizerIfNeeded()
            r.eq(loaded.detectedVariant, "small", "Whisper real override records verified non-tiny graph")
            r.check(decoder.isModelMultilingual, "Whisper real override sets multilingual inference mode")
            r.check(loaded.tokenizer != nil, "Whisper real override installs selected local tokenizer")
            r.eq(WhisperNetworkTrap.count.withLock { $0 }, 0, "Whisper local success also sends zero network requests")
            var extra = fixtureTokenizerData()
            extra["added_tokens"] = [["id": 100000, "content": "outside-graph", "special": true]]
            try JSONSerialization.data(withJSONObject: extra).write(to: root.appendingPathComponent("tokenizer.json"))
            do {
                try await loaded.loadTokenizerIfNeeded()
                r.check(false, "Whisper rejects sparse added token beyond graph vocabulary")
            } catch { r.check(true, "Whisper rejects sparse added token beyond graph vocabulary") }
            let verified = try WhisperRuntimeMetadata(logitsSize: 51865, encoderSize: 768, decoderSize: 768)
            let capture = WhisperOptionCapture()
            let provider = try await WhisperASRProvider.load(model: model) { options in
                await capture.set(options)
                return WhisperProbeBackend(metadata: verified)
            }
            let options = await capture.options
            r.eq(options?.modelDirectory, root, "Whisper loads selected model directory")
            r.eq(options?.tokenizerDirectory, model.tokenizerDirectory, "Whisper never substitutes global tokenizer cache")
            r.eq(options?.download, false, "Whisper disables model downloads")
            r.eq(options?.load, false, "Whisper defers model loading until explicit offline load")
            r.eq(provider.verifiedMetadata, verified, "Whisper provider hands verified graph metadata to lease factory")
            r.check(provider.displayName.contains("small"), "Whisper display uses verified graph variant")
            r.check(provider.displayName.contains("Whisper"), "Whisper imported identity is explicit")
            do {
                _ = try await provider.transcribe(ASRRequest(samples: [0], sampleRate: 44100, language: nil, context: nil, timeout: 1))
                r.check(false, "Whisper rejects wrong sample rate")
            } catch { r.check(true, "Whisper rejects wrong sample rate") }
        } catch { r.check(false, "Whisper offline load fixture: \(error)") }
    }

    private static func fixtureTokenizer(omit: String? = nil) throws -> any Tokenizer {
        try PreTrainedTokenizer(tokenizerConfig: Config(["tokenizer_class": "WhisperTokenizer"] as [NSString: Any]),
                                tokenizerData: Config(fixtureTokenizerData(omit: omit)))
    }

    private static func writeTokenizer(to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: fixtureTokenizerData()).write(to: directory.appendingPathComponent("tokenizer.json"))
        try JSONSerialization.data(withJSONObject: ["tokenizer_class": "WhisperTokenizer"]).write(to: directory.appendingPathComponent("tokenizer_config.json"))
    }

    private static func fixtureTokenizerData(omit: String? = nil) -> [NSString: Any] {
        var vocab: [NSString: Any] = [:]
        for id in 0..<51865 { vocab[NSString(string: "unused\(id)")] = id }
        func token(_ value: String, _ id: Int) {
            vocab.removeValue(forKey: NSString(string: "unused\(id)"))
            if value != omit { vocab[NSString(string: value)] = id }
        }
        // Canonical GPT-2 byte alphabet covers arbitrary UTF-8 prompt text.
        let rawBytes = Array(33...126) + Array(161...172) + Array(174...255)
        for (id, scalar) in (rawBytes + Array(256..<(256 + 256 - rawBytes.count))).enumerated() {
            token(String(Unicode.Scalar(scalar)!), id)
        }
        for (value, id) in ["<|endoftext|>":50257, "<|startoftranscript|>":50258,
            "<|translate|>":50358, "<|transcribe|>":50359, "<|startofprev|>":50361,
            "<|nospeech|>":50362, "<|notimestamps|>":50363] { token(value, id) }
        let languages = ["en"] + Set(Constants.languages.values).subtracting(["en", "yue"]).sorted()
        for (i, language) in languages.enumerated() { token("<|\(language)|>", 50259 + i) }
        for i in 0...1500 { token(String(format: "<|%.2f|>", Double(i) * 0.02), 50364 + i) }
        return ["model": ["type": "BPE", "vocab": vocab, "merges": []],
                "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false],
                "decoder": ["type": "ByteLevel"]]
    }

    private static func request() -> ASRRequest {
        ASRRequest(samples: [0], sampleRate: 16000, language: nil, context: nil, timeout: 5)
    }
}

private actor WhisperProbeBackend: OfflineWhisperBackend {
    struct Input: Sendable { let count: Int; let language: String?; let prompt: String? }
    nonisolated let verifiedMetadata: WhisperRuntimeMetadata?
    private let segments: [String]
    private let suspended: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var current = 0
    var maxConcurrent = 0
    var starts = 0
    var lastInput: Input?
    init(segments: [String] = ["首段", "中段", "尾段"], suspended: Bool = false, metadata: WhisperRuntimeMetadata? = nil) {
        self.segments = segments; self.suspended = suspended; self.verifiedMetadata = metadata
    }
    func transcribe(samples: [Float], language: String?, prompt: String?) async throws -> [String] {
        starts += 1; current += 1; maxConcurrent = max(current, maxConcurrent)
        lastInput = Input(count: samples.count, language: language, prompt: prompt)
        if suspended { await withCheckedContinuation { continuation = $0 } }
        current -= 1
        return segments
    }
    func waitForStarts(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while starts < count && ContinuousClock.now < deadline { await Task.yield() }
        return starts >= count
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor WhisperOptionCapture {
    var options: WhisperOfflineLoadOptions?
    func set(_ value: WhisperOfflineLoadOptions) { options = value }
}

private final class WhisperNetworkTrap: URLProtocol, @unchecked Sendable {
    static let count = OSAllocatedUnfairLock(initialState: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private struct WhisperFixtureEncoder: AudioEncoding {
    var embedSize: Int? { 768 }
    func encodeFeatures(_ features: any FeatureExtractorOutputType) async throws -> (any AudioEncoderOutputType)? {
        throw OfflineWhisperError.incompatibleGraph
    }
}

private final class WhisperFixtureDecoder: TextDecoding {
    var tokenizer: (any WhisperTokenizer)?
    var prefillData: (any WhisperMLModel)?
    var isModelMultilingual = false
    var supportsWordTimestamps: Bool { false }
    var logitsSize: Int? { 51865 }
    var logitsFilters: [any LogitsFiltering]?
    var kvCacheEmbedDim: Int? { nil }
    var kvCacheMaxSequenceLength: Int? { nil }
    var windowSize: Int? { nil }
    var embedSize: Int? { 768 }
    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? { throw OfflineWhisperError.incompatibleGraph }
    func prefillDecoderInputs(_ decoderInputs: any DecodingInputsType, withOptions options: DecodingOptions?) async throws -> any DecodingInputsType { throw OfflineWhisperError.incompatibleGraph }
    func prefillKVCache(withTask task: MLMultiArray, andLanguage language: MLMultiArray) async throws -> DecodingCache? { throw OfflineWhisperError.incompatibleGraph }
    func decodeText(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                    sampler tokenSampler: TokenSampling, options decoderOptions: DecodingOptions,
                    callback: ((TranscriptionProgress) -> Bool?)?) async throws -> DecodingResult { throw OfflineWhisperError.incompatibleGraph }
    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                        sampler tokenSampler: TokenSampling, options: DecodingOptions,
                        temperature: FloatType) async throws -> DecodingResult { throw OfflineWhisperError.incompatibleGraph }
}
