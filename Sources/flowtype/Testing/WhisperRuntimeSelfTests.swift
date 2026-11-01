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
            try OfflineWhisperKit.validateTokenizerMetadata(Dictionary(uniqueKeysWithValues: missingMerges.map { ($0.key as String, $0.value) }))
            r.check(false, "Whisper rejects missing merges before upstream fatalError")
        } catch { r.check(true, "Whisper rejects missing merges before upstream fatalError") }
        do {
            let segments = WhisperKitBackend.textSegments([
                TranscriptionResult(text: "unused aggregate", segments: [.init(text: "首段"), .init(text: "中段")], language: "zh", timings: TranscriptionTimings()),
                TranscriptionResult(text: "尾段", segments: [], language: "zh", timings: TranscriptionTimings())
            ])
            r.eq(segments, ["首段", "中段", "尾段"], "Whisper flattens every framework result and ordered segment")
            r.eq(WhisperKitBackend.textSegments([]), [], "Whisper framework empty array is safe")
            do {
                let hf = try LocalWhisperTokenizer(tokenizer: fixtureTokenizer(noSpeechToken: "<|nocaptions|>"))
                try hf.validate(for: WhisperRuntimeMetadata(logitsSize: 51865, encoderSize: 384, decoderSize: 384))
                r.eq(hf.specialTokens.noSpeechToken, 50362, "Whisper standard no-captions spelling supplies exact no-speech token")
            } catch { r.check(false, "Whisper standard no-captions spelling must load: \(error)") }
            var conflict = fixtureTokenizerData(noSpeechToken: "<|nocaptions|>")
            var conflictModel = conflict["model"] as! [String: Any]
            var conflictVocab = conflictModel["vocab"] as! [NSString: Any]
            conflictVocab.removeValue(forKey: "unused50360")
            conflictVocab["<|nospeech|>"] = 50360
            conflictModel["vocab"] = conflictVocab
            conflict["model"] = conflictModel
            do {
                let raw = try PreTrainedTokenizer(tokenizerConfig: Config(["tokenizer_class": "WhisperTokenizer", "unk_token": "<|endoftext|>"] as [NSString: Any]), tokenizerData: Config(conflict))
                _ = try LocalWhisperTokenizer(tokenizer: raw)
                r.check(false, "Whisper rejects conflicting no-speech alias IDs")
            } catch { r.check(true, "Whisper rejects conflicting no-speech alias IDs") }
            let tokenizer = try LocalWhisperTokenizer(tokenizer: fixtureTokenizer())
            r.eq(tokenizer.allLanguageTokens.count, 99, "Whisper unknown fallback is excluded from language inventory")
            r.check(!tokenizer.allLanguageTokens.contains(tokenizer.specialTokens.endToken), "Whisper end token is never a language")
            r.eq(tokenizer.convertTokenToId("<|yue|>"), nil, "Whisper absent Cantonese is not an unknown/end token")
            r.eq(tokenizer.convertTokenToId("<|en|>"), 50259, "Whisper existing English language token retained")
            if let chinese = tokenizer.convertTokenToId("<|zh|>") {
                r.eq(tokenizer.convertIdToToken(chinese), "<|zh|>", "Whisper existing Chinese language round-trips")
            } else { r.check(false, "Whisper Chinese language exists") }
            for hint in ["yue", "Cantonese"] {
                do {
                    _ = try WhisperKitBackend.languageCode(hint, tokenizer: tokenizer, isMultilingual: true)
                    r.check(false, "Whisper rejects absent Cantonese hint instead of using end token")
                } catch OfflineWhisperError.unsupportedLanguage {
                    r.check(true, "Whisper rejects absent Cantonese hint instead of using end token")
                }
            }
            r.eq(try WhisperKitBackend.languageCode("Chinese", tokenizer: tokenizer, isMultilingual: true), "zh", "Whisper supported Chinese hint still resolves")
            r.eq(try WhisperKitBackend.languageCode("en", tokenizer: tokenizer, isMultilingual: true), "en", "Whisper supported English hint still resolves")
            r.eq(try WhisperKitBackend.languageCode("auto", tokenizer: tokenizer, isMultilingual: true), nil, "Whisper automatic language remains automatic")
            for (logits, size) in [(51864, 512), (51866, 1280)] {
                let alternate = try LocalWhisperTokenizer(tokenizer: fixtureTokenizer(logitsSize: logits))
                let metadata = try WhisperRuntimeMetadata(logitsSize: logits, encoderSize: size, decoderSize: size)
                try alternate.validate(for: metadata)
                r.eq(alternate.allLanguageTokens.count, logits == 51866 ? 100 : 99, "Whisper English/v3 inventory accepts standard unknown token")
                if logits == 51866 {
                    r.eq(try WhisperKitBackend.languageCode("Cantonese", tokenizer: alternate, isMultilingual: true), "yue", "Whisper v3 Cantonese remains supported")
                } else {
                    r.eq(try WhisperKitBackend.languageCode("English", tokenizer: alternate, isMultilingual: false), "en", "Whisper English-only hint remains supported")
                    do {
                        _ = try WhisperKitBackend.languageCode("zh", tokenizer: alternate, isMultilingual: false)
                        r.check(false, "Whisper English-only graph rejects non-English hint")
                    } catch OfflineWhisperError.unsupportedLanguage { r.check(true, "Whisper English-only graph rejects non-English hint") }
                }
            }
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
                    featureExtractor: WhisperFixtureMel(), audioEncoder: WhisperFixtureEncoder(), textDecoder: WhisperFixtureDecoder(),
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
            await graphContracts(root, r)
            let decoder = WhisperFixtureDecoder()
            let loaded = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                featureExtractor: WhisperFixtureMel(), audioEncoder: WhisperFixtureEncoder(), textDecoder: decoder,
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

    private static func graphContracts(_ root: URL, _ r: SelfTest.Reporter) async {
        typealias G = WhisperGraphDescription
        typealias F = G.Feature
        var failures: [(String, G, G, G, G?)] = []
        func bad(_ name: String, _ edit: (inout G, inout G, inout G, inout G?) -> Void) {
            var mel = WhisperGraphFixtures.mel, encoder = WhisperGraphFixtures.encoder, decoder = WhisperGraphFixtures.decoder
            var prefill: G? = nil
            edit(&mel, &encoder, &decoder, &prefill)
            failures.append((name, mel, encoder, decoder, prefill))
        }
        bad("flexible unsafe output extents") { _, _, d, _ in d.outputs["logits"]?.hasFixedShape = false }
        bad("rank-one logits") { _, _, d, _ in d.outputs["logits"]?.shape = [51865] }
        bad("rank-one encoder output") { _, e, _, _ in e.outputs["encoder_output_embeds"]?.shape = [768] }
        bad("missing mel output") { m, _, _, _ in m.outputs.removeValue(forKey: "melspectrogram_features") }
        bad("wrong mel feature type") { m, _, _, _ in m.outputs["melspectrogram_features"]?.isMultiArray = false }
        bad("wrong audio type") { m, _, _, _ in m.inputs["audio"]?.dataType = .int32 }
        bad("wrong audio rank") { m, _, _, _ in m.inputs["audio"]?.shape = [1,480000] }
        bad("mel encoder interface mismatch") { _, e, _, _ in e.inputs["melspectrogram_features"]?.shape = [1,128,1,3000] }
        bad("encoder decoder interface mismatch") { _, _, d, _ in d.inputs["encoder_output_embeds"]?.shape = [1,768,1,1499] }
        bad("cache wrong rank") { _, _, d, _ in d.inputs["key_cache"]?.shape = [1,9216] }
        bad("cache value dimension mismatch") { _, _, d, _ in d.inputs["value_cache"]?.shape = [1,768,1,224] }
        bad("cache update size mismatch") { _, _, d, _ in d.outputs["key_cache_updates"]?.shape = [1,768,1,1] }
        bad("cache update wrong dtype") { _, _, d, _ in d.outputs["value_cache_updates"]?.dataType = .float32 }
        bad("mask length mismatch") { _, _, d, _ in d.inputs["kv_cache_update_mask"]?.shape = [1,223] }
        bad("Float16 update mask incompatible with production Int32 input") { _, _, d, _ in d.inputs["kv_cache_update_mask"]?.dataType = .float16 }
        bad("unverified mask numeric type") { _, _, d, _ in d.inputs["kv_cache_update_mask"]?.dataType = .double }
        bad("optional required output") { _, _, d, _ in d.outputs["key_cache_updates"]?.isOptional = true }
        bad("context shorter than runtime loop") { _, _, d, _ in d.inputs["key_cache"]?.shape = [1,9216,1,16] }
        bad("missing required decoder input") { _, _, d, _ in d.inputs.removeValue(forKey: "input_ids") }
        bad("unknown required decoder input") { _, _, d, _ in d.inputs["unprovided"] = F(shape: [1], dataType: .int32) }
        bad("alignment length mismatch") { _, _, d, _ in d.outputs["alignment_heads_weights"] = F(shape: [1,100], dataType: .float16) }
        bad("prefill incompatible cache") { _, _, _, p in p = WhisperGraphFixtures.prefill; p?.outputs["key_cache_prefill"]?.shape = [1,768,1,3] }
        bad("prefill missing value output") { _, _, _, p in p = WhisperGraphFixtures.prefill; p?.outputs.removeValue(forKey: "value_cache_prefill") }
        bad("prefill task wrong type") { _, _, _, p in p = WhisperGraphFixtures.prefill; p?.inputs["task"]?.dataType = .float16 }
        bad("prefill wrong sequence") { _, _, _, p in p = WhisperGraphFixtures.prefill; p?.outputs["value_cache_prefill"]?.shape = [1,9216,1,224] }
        for (name, mel, encoder, decoder, prefill) in failures {
            do {
                let text = WhisperFixtureDecoder(graph: decoder)
                if let prefill { text.prefillData = WhisperFixturePrefill(graph: prefill) }
                let kit = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                    featureExtractor: WhisperFixtureMel(graph: mel), audioEncoder: WhisperFixtureEncoder(graph: encoder), textDecoder: text,
                    verbose: false, prewarm: false, load: false, download: false))
                do {
                    try await kit.loadTokenizerIfNeeded()
                    r.check(false, "Whisper rejects raw graph: \(name)")
                } catch { r.check(true, "Whisper rejects raw graph: \(name)") }
                r.eq(text.dimensionReads, 0, "Whisper validates raw graph before unsafe dimension helpers: \(name)")
                r.eq(kit.detectedMetadata, nil, "Whisper invalid graph cannot publish verified readiness: \(name)")
            } catch { r.check(false, "Whisper graph fixture construction: \(error)") }
        }
        for (logits, size, layers, variant) in [(51864,384,4,"tiny.en"), (51864,512,6,"base.en"),
            (51864,768,12,"small.en"), (51864,1024,24,"medium.en"), (51865,384,4,"tiny"),
            (51865,512,6,"base"), (51865,768,12,"small"), (51865,1024,24,"medium"),
            (51865,1280,32,"large-v1/v2"), (51866,1280,32,"large-v3"), (51866,1280,4,"large-v3"),
            (51865,768,2,"small")] {
            var mel = WhisperGraphFixtures.mel, encoder = WhisperGraphFixtures.encoder, decoder = WhisperGraphFixtures.decoder
            mel.outputs["melspectrogram_features"]?.shape[1] = logits == 51866 ? 128 : 80
            encoder.inputs["melspectrogram_features"] = mel.outputs["melspectrogram_features"]
            encoder.outputs["encoder_output_embeds"]?.shape[1] = size
            decoder.inputs["encoder_output_embeds"] = encoder.outputs["encoder_output_embeds"]
            decoder.outputs["logits"]?.shape[2] = logits
            for name in ["key_cache", "value_cache"] { decoder.inputs[name]?.shape = [1,size * layers,1,448] }
            for name in ["kv_cache_update_mask", "decoder_key_padding_mask"] { decoder.inputs[name]?.shape = [1,448] }
            for name in ["key_cache_updates", "value_cache_updates"] { decoder.outputs[name]?.shape[1] = size * layers }
            decoder.outputs["alignment_heads_weights"] = F(shape: [1,1500], dataType: .float16)
            decoder.inputs["optional_unused"] = F(shape: [1], dataType: .int32, isOptional: true)
            decoder.inputs["input_ids"]?.isOptional = true // always supplied by the runtime
            decoder.inputs["kv_cache_update_mask"]?.dataType = .int32
            // Inputs may advertise flexibility: the runtime always supplies these fixed
            // default shapes. Outputs must not advertise incompatible dimensions.
            decoder.inputs["key_cache"]?.hasFixedShape = false
            do {
                let metadata = try WhisperGraphContract.validate(mel: mel, encoder: encoder, decoder: decoder, prefill: nil)
                r.eq(metadata.variant, variant, "Whisper raw supported family/layers \(size)/\(layers)/\(logits)")
            } catch { r.check(false, "Whisper raw supported family/layers \(size)/\(layers)/\(logits): \(error)") }
        }
        do { try WhisperGraphContract.validateRuntimeABI(floatStride: 2); r.check(true, "Whisper Float16 ABI accepted") }
        catch { r.check(false, "Whisper Float16 ABI accepted") }
        do { try WhisperGraphContract.validateRuntimeABI(floatStride: 4); r.check(false, "Whisper incompatible Intel cache copy ABI rejected") }
        catch { r.check(true, "Whisper incompatible Intel cache copy ABI rejected") }
        do {
            let text = WhisperFixtureDecoder()
            text.prefillData = WhisperFixturePrefill(graph: WhisperGraphFixtures.prefill)
            let kit = try await OfflineWhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                featureExtractor: WhisperFixtureMel(), audioEncoder: WhisperFixtureEncoder(), textDecoder: text,
                verbose: false, prewarm: false, load: false, download: false))
            try await kit.loadTokenizerIfNeeded()
            r.eq(kit.detectedVariant, "small", "Whisper complete raw interfaces and optional prefill accepted")
        } catch { r.check(false, "Whisper complete graph fixture: \(error)") }
    }

    private static func fixtureTokenizer(omit: String? = nil, logitsSize: Int = 51865, noSpeechToken: String = "<|nospeech|>") throws -> any Tokenizer {
        try PreTrainedTokenizer(tokenizerConfig: Config(["tokenizer_class": "WhisperTokenizer", "unk_token": "<|endoftext|>"] as [NSString: Any]),
                                tokenizerData: Config(fixtureTokenizerData(omit: omit, logitsSize: logitsSize, noSpeechToken: noSpeechToken)))
    }

    private static func writeTokenizer(to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: fixtureTokenizerData()).write(to: directory.appendingPathComponent("tokenizer.json"))
        try JSONSerialization.data(withJSONObject: ["tokenizer_class": "WhisperTokenizer", "unk_token": "<|endoftext|>"]).write(to: directory.appendingPathComponent("tokenizer_config.json"))
    }

    private static func fixtureTokenizerData(omit: String? = nil, logitsSize: Int = 51865, noSpeechToken: String = "<|nospeech|>") -> [NSString: Any] {
        var vocab: [NSString: Any] = [:]
        for id in 0..<logitsSize { vocab[NSString(string: "unused\(id)")] = id }
        func token(_ value: String, _ id: Int) {
            vocab.removeValue(forKey: NSString(string: "unused\(id)"))
            if value != omit { vocab[NSString(string: value)] = id }
        }
        // Canonical GPT-2 byte alphabet covers arbitrary UTF-8 prompt text.
        let rawBytes = Array(33...126) + Array(161...172) + Array(174...255)
        for (id, scalar) in (rawBytes + Array(256..<(256 + 256 - rawBytes.count))).enumerated() {
            token(String(Unicode.Scalar(scalar)!), id)
        }
        let end = logitsSize == 51864 ? 50256 : 50257
        let translate = logitsSize - 1507
        for (value, id) in ["<|endoftext|>":end, "<|startoftranscript|>":end + 1,
            "<|translate|>":translate, "<|transcribe|>":translate + 1, "<|startofprev|>":translate + 3,
            noSpeechToken:translate + 4, "<|notimestamps|>":translate + 5] { token(value, id) }
        let languages = ["en"] + Set(Constants.languages.values).subtracting(["en", "yue"]).sorted()
        for (i, language) in languages.enumerated() { token("<|\(language)|>", end + 2 + i) }
        if logitsSize == 51866 { token("<|yue|>", 50358) }
        for i in 0...1500 { token(String(format: "<|%.2f|>", Double(i) * 0.02), translate + 6 + i) }
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

private struct WhisperFixtureEncoder: AudioEncoding, WhisperGraphDescribing {
    var graph = WhisperGraphFixtures.encoder
    var rawGraphDescription: WhisperGraphDescription? { graph }
    var embedSize: Int? { 768 }
    func encodeFeatures(_ features: any FeatureExtractorOutputType) async throws -> (any AudioEncoderOutputType)? {
        throw OfflineWhisperError.incompatibleGraph
    }
}

private final class WhisperFixtureDecoder: TextDecoding, WhisperGraphDescribing {
    var graph: WhisperGraphDescription
    var rawGraphDescription: WhisperGraphDescription? { graph }
    init(graph: WhisperGraphDescription = WhisperGraphFixtures.decoder) { self.graph = graph }
    var tokenizer: (any WhisperTokenizer)?
    var prefillData: (any WhisperMLModel)?
    var isModelMultilingual = false
    var supportsWordTimestamps: Bool { false }
    var dimensionReads = 0
    var logitsSize: Int? { dimensionReads += 1; return 51865 }
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

enum WhisperGraphFixtures {
    typealias F = WhisperGraphDescription.Feature
    static let mel = WhisperGraphDescription(inputs: ["audio": F(shape: [480000], dataType: .float32)],
        outputs: ["melspectrogram_features": F(shape: [1,80,1,3000], dataType: .float16)])
    static let encoder = WhisperGraphDescription(inputs: ["melspectrogram_features": F(shape: [1,80,1,3000], dataType: .float16)],
        outputs: ["encoder_output_embeds": F(shape: [1,768,1,1500], dataType: .float16)])
    static let decoder = WhisperGraphDescription(inputs: [
        "input_ids": F(shape: [1], dataType: .int32), "cache_length": F(shape: [1], dataType: .int32),
        "key_cache": F(shape: [1,9216,1,224], dataType: .float16), "value_cache": F(shape: [1,9216,1,224], dataType: .float16),
        "kv_cache_update_mask": F(shape: [1,224], dataType: .int32), "decoder_key_padding_mask": F(shape: [1,224], dataType: .float16),
        "encoder_output_embeds": F(shape: [1,768,1,1500], dataType: .float16)
    ], outputs: ["logits": F(shape: [1,1,51865], dataType: .float16),
        "key_cache_updates": F(shape: [1,9216,1,1], dataType: .float16), "value_cache_updates": F(shape: [1,9216,1,1], dataType: .float16)])
    static let prefill = WhisperGraphDescription(inputs: ["task": F(shape: [1], dataType: .int32), "language": F(shape: [1], dataType: .int32)],
        outputs: ["key_cache_prefill": F(shape: [1,9216,1,3], dataType: .float16), "value_cache_prefill": F(shape: [1,9216,1,3], dataType: .float16)])
}
private struct WhisperFixtureMel: FeatureExtracting, WhisperGraphDescribing {
    var graph = WhisperGraphFixtures.mel
    var rawGraphDescription: WhisperGraphDescription? { graph }
    var melCount: Int? { 80 }
    var windowSamples: Int? { 480000 }
    func logMelSpectrogram(fromAudio inputAudio: any AudioProcessorOutputType) async throws -> (any FeatureExtractorOutputType)? {
        throw OfflineWhisperError.incompatibleGraph
    }
}
private final class WhisperFixturePrefill: WhisperMLModel, WhisperGraphDescribing {
    var model: MLModel?
    var graph: WhisperGraphDescription
    var rawGraphDescription: WhisperGraphDescription? { graph }
    init(graph: WhisperGraphDescription) { self.graph = graph }
}
