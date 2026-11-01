import Foundation

/// Synthetic metadata and sparse payloads only; never loads MLX/Core ML or user models.
enum LocalModelImportSelfTests {
    static func runInspection(_ r: SelfTest.Reporter) {
        InspectionNetworkProbe.reset()
        _ = URLProtocol.registerClass(InspectionNetworkProbe.self)
        defer {
            URLProtocol.unregisterClass(InspectionNetworkProbe.self)
            r.eq(InspectionNetworkProbe.calls, 0, "import: inspection performs no URL loading")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try repeatedFileIdentity(root, r)
            for (large, bits) in [(false, 4), (false, 8), (true, 4), (true, 8)] {
                let dir = root.appendingPathComponent("unrelated-\(large)-\(bits)")
                try qwenFixture(dir, large: large, bits: bits)
                let model = try ASRModelInspector.inspect(directory: dir)
                r.eq(model.engine, .qwenMLX, "import: metadata determines engine")
                r.eq(model.variant, large ? "1.7B" : "0.6B", "import: tensor/config scale")
                r.eq(model.bits, bits, "import: packing determines bit width")
                r.check((model.minimumResidentBytes ?? 0) > 0 && model.minimumResidentBytes! < UInt64(model.sizeBytes),
                        "import: admission reservation counts packed weights only, not directory size")
                let renamed = root.appendingPathComponent("renamed-\(large)-\(bits)")
                try FileManager.default.moveItem(at: dir, to: renamed)
                let again = try ASRModelInspector.inspect(directory: renamed)
                r.eq(again.variant, model.variant, "import: rename cannot change scale")
                let converted = root.appendingPathComponent("converted-\(large)-\(bits)")
                try qwenFixture(converted, large:large, bits:bits)
                try convertedConfig(converted, large:large, bits:bits)
                var exported = tensors(large:large,bits:bits)
                exported["lm_head.weight"] = ("F16",[151936,large ? 2048:1024])
                try weights(exported,to:converted.appendingPathComponent("model.safetensors"))
                let convertedModel = try ASRModelInspector.inspect(directory:converted)
                r.eq(convertedModel.variant,large ? "1.7B" : "0.6B","import: converted MLX config identifies scale")
                r.eq(convertedModel.bits,bits,"import: converted minmax config identifies bits")
                r.eq(convertedModel.minimumResidentBytes, model.minimumResidentBytes,
                     "import: redundant float output head never inflates packed-weight reservation")
            }
            let dir = root.appendingPathComponent("invalid")
            func rejected(_ label: String, _ mutate: () throws -> Void) throws {
                try? FileManager.default.removeItem(at: dir)
                try qwenFixture(dir)
                try mutate()
                do { _ = try ASRModelInspector.inspect(directory: dir); r.check(false, "import: reject \(label)") }
                catch { r.check(error is ASRModelInspectionError, "import: actionable error for \(label)") }
            }
            try rejected("unknown family") { try editJSON(dir, "config.json") { $0["model_type"] = "llama" } }
            try rejected("wrong group") { try editJSON(dir, "config.json") { $0["quantization"] = ["bits": 4, "group_size": 128] } }
            try rejected("conflicting quantization metadata") { try editJSON(dir,"config.json") { $0["quantization_config"] = ["bits":8,"group_size":64] } }
            try rejected("converted wrong size label") { try convertedConfig(dir,large:false,bits:4); try editJSON(dir,"config.json") { $0["model_size"] = "1.7B" } }
            try rejected("converted wrong packing") { try convertedConfig(dir,large:false,bits:8) }
            try rejected("converted unsupported method") { try convertedConfig(dir,large:false,bits:4); try editJSON(dir,"config.json") { $0["quantization_config"] = ["bits":4,"group_size":64,"quant_method":"gptq"] } }
            try rejected("invalid RoPE number") { try editJSON(dir,"config.json") { var t = $0["thinker_config"] as! [String:Any]; var text = t["text_config"] as! [String:Any]; text["rope_theta"] = "invalid"; t["text_config"] = text; $0["thinker_config"] = t } }
            try rejected("config tensor conflict") { try editJSON(dir, "config.json") { var t = $0["thinker_config"] as! [String: Any]; var text = t["text_config"] as! [String: Any]; text["hidden_size"] = 2048; t["text_config"] = text; $0["thinker_config"] = t } }
            try rejected("wrong optional output head shape") { var ts = tensors(); ts["lm_head.weight"] = ("F16",[151936,2048]); try weights(ts,to:dir.appendingPathComponent("model.safetensors")) }
            try rejected("non-floating optional output head") { var ts = tensors(); ts["lm_head.weight"] = ("U32",[151936,1024]); try weights(ts,to:dir.appendingPathComponent("model.safetensors")) }
            try rejected("untied output head config") { try convertedConfig(dir,large:false,bits:4); try editJSON(dir,"config.json") { var t = $0["text_decoder"] as! [String:Any]; t["tie_word_embeddings"] = false; $0["text_decoder"] = t } }
            try rejected("arbitrary extra tensor") { var ts = tensors(); ts["unknown.weight"] = ("F16",[1]); try weights(ts,to:dir.appendingPathComponent("model.safetensors")) }
            try rejected("missing deep layer tensor") { var ts = tensors(); ts.removeValue(forKey: "model.layers.27.mlp.down_proj.biases"); try weights(ts, to: dir.appendingPathComponent("model.safetensors")) }
            try rejected("truncated ordinary vocabulary") { try editJSON(dir, "vocab.json") { $0.removeValue(forKey: "!!") } }
            try rejected("base row hidden in added tokens") { try editJSON(dir, "vocab.json") { $0.removeValue(forKey: "!!") }; try editJSON(dir, "tokenizer_config.json") { $0["added_tokens_decoder"] = [String(Self.tokenizerFixture.vocab["!!"]!): ["content": "!!"]] } }
            try rejected("missing non-prompt added token") { try editJSON(dir, "vocab.json") { $0.removeValue(forKey: "<reserved151700>") } }
            try rejected("merge reordered before operands") { var lines = Self.tokenizerFixture.merges.components(separatedBy: "\n"); lines.swapAt(1, 2); try Data(lines.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent("merges.txt")) }
            try rejected("missing byte alphabet entry") { try editJSON(dir, "vocab.json") { $0.removeValue(forKey: "!") } }
            try rejected("truncated merge list") { try Data("#version: 0.2\n! !\n".utf8).write(to: dir.appendingPathComponent("merges.txt")) }
            try rejected("unknown merge operand") { try Data((Self.tokenizerFixture.merges + "not-in-vocab !\n").utf8).write(to: dir.appendingPathComponent("merges.txt")) }
            try rejected("malformed merge line") { try Data((Self.tokenizerFixture.merges + "! ! !\n").utf8).write(to: dir.appendingPathComponent("merges.txt")) }
            try rejected("duplicate merge") { try Data((Self.tokenizerFixture.merges + "! !\n").utf8).write(to: dir.appendingPathComponent("merges.txt")) }
            try rejected("invalid safetensors metadata type") { try weights(tensors(), to: dir.appendingPathComponent("model.safetensors"), metadata: ["format": 7]) }
            try rejected("missing special token") { try editJSON(dir, "vocab.json") { $0.removeValue(forKey: "<|audio_pad|>") } }
            try rejected("missing ASR text token") { try editJSON(dir, "vocab.json") { $0.removeValue(forKey: "<asr_text>") } }
            try rejected("wrong prompt role ID") { try editJSON(dir, "vocab.json") { $0["system"] = 8949 } }
            try rejected("raw float weights") { var ts = tensors(); ts["model.embed_tokens.weight"] = ("F16", [151936,1024]); try weights(ts, to: dir.appendingPathComponent("model.safetensors")) }
            try rejected("missing shard") { try json(["weight_map": ["x": "missing.safetensors"]], dir.appendingPathComponent("model.safetensors.index.json")) }
            try rejected("index traversal") { try json(["weight_map": ["x": "../outside.safetensors"]], dir.appendingPathComponent("model.safetensors.index.json")) }
            try rejected("duplicate tensor shards") { try weights(["model.norm.weight": ("F16",[1024])], to: dir.appendingPathComponent("extra.safetensors")) }
            try rejected("LFS pointer") { try Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1000000".utf8).write(to: dir.appendingPathComponent("model.safetensors")) }
            try rejected("truncated header") { try Data([255,255,255,255,255,255,255,127]).write(to: dir.appendingPathComponent("model.safetensors")) }
            try rejected("payload offset overflow") { try rawHeader("{\"x\":{\"dtype\":\"F16\",\"shape\":[9223372036854775807,2],\"data_offsets\":[0,1]}}", dir) }
            try rejected("duplicate JSON tensor") { try rawHeader("{\"x\":{},\"x\":{}}", dir) }
            try rejected("oversized metadata") { let h = try FileHandle(forWritingTo: dir.appendingPathComponent("config.json")); try h.truncate(atOffset: 16 * 1024 * 1024 + 1); try h.close() }
            try rejected("index total size inconsistency") { try json(["metadata":["total_size":1],"weight_map": Dictionary(uniqueKeysWithValues: tensors().keys.map { ($0, "model.safetensors") })], dir.appendingPathComponent("model.safetensors.index.json")) }
            try rejected("index wrong shard mapping") { try json(["weight_map": Dictionary(uniqueKeysWithValues: tensors().keys.map { ($0, "wrong.safetensors") })], dir.appendingPathComponent("model.safetensors.index.json")) }
            try rejected("oversized index") { let u = dir.appendingPathComponent("model.safetensors.index.json"); try Data().write(to:u); let h = try FileHandle(forWritingTo:u); try h.truncate(atOffset:16*1024*1024+1); try h.close() }
            try rejected("tensor overlapping offsets") { try rawHeader("{\"a\":{\"dtype\":\"F16\",\"shape\":[1],\"data_offsets\":[0,2]},\"b\":{\"dtype\":\"F16\",\"shape\":[1],\"data_offsets\":[0,2]}}", dir, payloadBytes: 4) }
            try? FileManager.default.removeItem(at: dir)
            try qwenFixture(dir)
            let all = tensors(); let keys = all.keys.sorted(); let half = keys.count / 2
            try FileManager.default.removeItem(at: dir.appendingPathComponent("model.safetensors"))
            try weights(Dictionary(uniqueKeysWithValues: keys.prefix(half).map { ($0, all[$0]!) }), to:dir.appendingPathComponent("one.safetensors"))
            try weights(Dictionary(uniqueKeysWithValues: keys.suffix(keys.count-half).map { ($0, all[$0]!) }), to:dir.appendingPathComponent("two.safetensors"))
            let mapping = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset < half ? "one.safetensors" : "two.safetensors") })
            try json(["weight_map":mapping], dir.appendingPathComponent("model.safetensors.index.json"))
            r.eq(try ASRModelInspector.inspect(directory:dir).variant,"0.6B","import: complete indexed shards accepted")
            try FileManager.default.removeItem(at:dir)
            try qwenFixture(dir)
            let firstFingerprint = try ASRModelInspector.inspect(directory: dir).fileFingerprint
            try editJSON(dir,"tokenizer_config.json") { $0["note"] = "changed" }
            r.check(try ASRModelInspector.inspect(directory: dir).fileFingerprint != firstFingerprint,"import: metadata changes invalidate descriptor fingerprint")
            var legacyConfig = Configuration(); legacyConfig.customLocalModelPath = root.appendingPathComponent("missing-explicit").path
            do { _ = try ModelLocator.inspectLegacyCandidate(config:legacyConfig); r.check(false,"import: unresolved explicit legacy path must fail") } catch { r.check(true,"import: unresolved explicit legacy path must fail") }
            legacyConfig.customLocalModelPath = dir.path
            r.eq(try ModelLocator.inspectLegacyCandidate(config:legacyConfig)?.variant,"0.6B","import: valid legacy path staged")
            r.eq(legacyConfig.importedASRModels,[],"import: staging legacy path never persists migration")
            let blob = root.appendingPathComponent("blob")
            try FileManager.default.moveItem(at: dir.appendingPathComponent("model.safetensors"), to: blob)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("model.safetensors"), withDestinationURL: blob)
            r.eq(try ASRModelInspector.inspect(directory: dir).engine, .qwenMLX, "import: legal HF blob symlink")
            try FileManager.default.removeItem(at: blob)
            do { _ = try ASRModelInspector.inspect(directory: dir); r.check(false, "import: broken link rejected") } catch { r.check(true, "import: broken link rejected") }
            let whisper = root.appendingPathComponent("whisper")
            try whisperFixture(whisper)
            let coreML = try ASRModelInspector.inspect(directory: whisper)
            r.eq(coreML.engine, .whisperCoreML, "import: Core ML uses format-specific inspection")
            r.eq(coreML.variant, "unverified", "import: static Core ML inspection never claims graph identity")
            let sourcePackage = root.appendingPathComponent("source-coreml")
            try FileManager.default.createDirectory(at: sourcePackage, withIntermediateDirectories:true)
            for component in ["MelSpectrogram","AudioEncoder","TextDecoder"] {
                let package = sourcePackage.appendingPathComponent(component + ".mlpackage")
                try FileManager.default.createDirectory(at:package.appendingPathComponent("Data/com.apple.CoreML"),withIntermediateDirectories:true)
                try json(["rootModelIdentifier":"root","itemInfoEntries":["root":["path":"com.apple.CoreML/model.mlmodel"]]],package.appendingPathComponent("Manifest.json"))
                try Data([1,2,3]).write(to:package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
            }
            try FileManager.default.copyItem(at:whisper.appendingPathComponent("tokenizer.json"),to:sourcePackage.appendingPathComponent("tokenizer.json"))
            try FileManager.default.copyItem(at:whisper.appendingPathComponent("tokenizer_config.json"),to:sourcePackage.appendingPathComponent("tokenizer_config.json"))
            r.eq(try ASRModelInspector.inspect(directory:sourcePackage).engine,.whisperCoreML,"import: source Core ML package manifest accepted statically")
            try editJSON(sourcePackage.appendingPathComponent("TextDecoder.mlpackage"),"Manifest.json") { $0["itemInfoEntries"] = ["root":["path":"../escape.mlmodel"]] }
            do { _ = try ASRModelInspector.inspect(directory:sourcePackage); r.check(false,"import: package manifest traversal rejected") } catch { r.check(true,"import: package manifest traversal rejected") }
            let cfg = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
            r.eq(cfg.importedASRModels, [], "import: legacy configuration decode")
            var library = LocalModelLibrary.upserting(coreML, in: cfg)
            r.eq(library.activeImportedASRModelID, nil, "import: inspection/upsert does not activate")
            library.activeImportedASRModelID = coreML.id
            library.customLocalModelPath = whisper.path
            library.localModelPath = whisper.path
            let updated = try ASRModelInspector.inspect(directory: whisper)
            let alias = root.appendingPathComponent("whisper-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: whisper)
            var aliased = updated; aliased.directory = alias
            r.eq(LocalModelLibrary.canonicalizing(aliased, in: library).id, coreML.id,
                 "import: symlink alias resolves durable UUID before runtime creation")
            library = LocalModelLibrary.upserting(updated, in: library)
            r.eq(library.importedASRModels.count, 1, "import: same canonical path deduplicates")
            r.eq(library.importedASRModels.first?.id, coreML.id, "import: rescan preserves library UUID")
            let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(library))
            r.eq(decoded.importedASRModels, library.importedASRModels, "import: library roundtrip")
            library = LocalModelLibrary.removing(id: coreML.id, from: library)
            r.eq(library.activeImportedASRModelID, nil, "import: remove active selection")
            r.eq(library.customLocalModelPath, nil, "import: remove legacy alias to avoid resurrection")
            r.check(FileManager.default.fileExists(atPath: whisper.path), "import: library removal never deletes weights")
            try FileManager.default.removeItem(at: whisper.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin"))
            do { _ = try ASRModelInspector.inspect(directory: whisper); r.check(false, "import: incomplete Core ML rejected") } catch { r.check(true, "import: incomplete Core ML rejected") }
            let multi = root.appendingPathComponent("multiple")
            try whisperFixture(multi.appendingPathComponent("one")); try whisperFixture(multi.appendingPathComponent("two"))
            try json(["model_type":"whisper"], multi.appendingPathComponent("config.json"))
            do { _ = try ASRModelInspector.inspect(directory: multi); r.check(false, "import: root variants rejected") }
            catch let error as ASRModelInspectionError { r.eq(error.code, .chooseSubdirectory, "import: explicit variant choice") }
        } catch { r.check(false, "import fixture: \(error)") }
    }

    /// Mirrors Whisper's metadata read followed by its later package walk, without timing races.
    private static func repeatedFileIdentity(_ root: URL, _ r: SelfTest.Reporter) throws {
        let url = root.appendingPathComponent("model.mil")
        try Data("original graph".utf8).write(to: url)
        let files = LocalInspectionFiles()
        _ = try files.read(url)
        let firstIdentity = try files.identity(url)
        let firstFingerprint = files.fingerprint
        try files.record(url, before: firstIdentity)
        try files.verify()
        r.eq(files.fingerprint, firstFingerprint, "import: unchanged repeated record preserves metadata fingerprint")

        let replacement = root.appendingPathComponent("replacement.mil")
        try Data("replacement graph with different resources".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        let laterIdentity = try files.identity(url)
        do {
            try files.record(url, before: laterIdentity)
            r.check(false, "import: replacement between metadata read and package walk is rejected")
        } catch let error as ASRModelInspectionError {
            r.eq(error.code, .changedDuringInspection, "import: repeated record reports changed file identity")
        }
        r.eq(files.fingerprint, firstFingerprint, "import: rejected replacement cannot overwrite first identity or hash")
        do {
            try files.verify()
            r.check(false, "import: final verification still compares against first observation")
        } catch let error as ASRModelInspectionError {
            r.eq(error.code, .changedDuringInspection, "import: first identity remains authoritative after rejection")
        }
    }

    private static func json(_ object: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url) }
    private static func editJSON(_ dir: URL, _ name: String, _ edit: (inout [String: Any]) -> Void) throws {
        let url = dir.appendingPathComponent(name)
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&value); try json(value, url)
    }
    private static func rawHeader(_ header: String, _ dir: URL, payloadBytes: Int = 0) throws {
        let body = Data(header.utf8); var n = UInt64(body.count).littleEndian
        var data = withUnsafeBytes(of: &n) { Data($0) }; data.append(body)
        data.append(Data(repeating:0, count:payloadBytes))
        try data.write(to: dir.appendingPathComponent("model.safetensors"))
    }
    private static func qwenFixture(_ dir: URL, large: Bool = false, bits: Int = 4) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json(["model_type": "qwen3_asr", "quantization": ["bits": bits, "group_size": 64], "thinker_config": ["audio_config": ["d_model": large ? 1024 : 896, "encoder_layers": large ? 24 : 18, "encoder_attention_heads": large ? 16 : 14, "encoder_ffn_dim": large ? 4096 : 3584, "num_mel_bins": 128, "output_dim": large ? 2048 : 1024, "downsample_hidden_size": 480], "text_config": ["hidden_size": large ? 2048 : 1024, "num_hidden_layers": 28, "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 128, "intermediate_size": large ? 6144 : 3072, "vocab_size": 151936, "tie_word_embeddings": true]]], dir.appendingPathComponent("config.json"))
        try json(Self.tokenizerFixture.vocab, dir.appendingPathComponent("vocab.json"))
        try json(["added_tokens_decoder": [:]], dir.appendingPathComponent("tokenizer_config.json"))
        try Data(Self.tokenizerFixture.merges.utf8).write(to: dir.appendingPathComponent("merges.txt"))
        try weights(tensors(large: large, bits: bits), to: dir.appendingPathComponent("model.safetensors"))
    }
    // Complete synthetic byte BPE, independent of any installed/public model metadata.
    private static let tokenizerFixture: (vocab: [String: Int], merges: String) = {
        let bytes = Array(33...126) + Array(161...172) + Array(174...255)
        let alphabet = (bytes + Array(256..<(512 - bytes.count))).map { String(Unicode.Scalar($0)!) }
        var tokens = alphabet
        var known = Set(tokens)
        var merges = "#version: 0.2\n"
        func append(_ left: String, _ right: String) {
            let token = left + right
            if known.insert(token).inserted { tokens.append(token); merges += left + " " + right + "\n" }
        }
        for word in ["system", "user", "assistant"] {
            var prefix = ""
            for character in word.map(String.init) {
                if !prefix.isEmpty { append(prefix, character) }
                prefix += character
            }
        }
        for left in alphabet { for right in alphabet { append(left, right) } }
        outer: for left in alphabet { for middle in alphabet { for right in alphabet {
            if tokens.count == 151643 { break outer }
            append(left + middle, right)
        } } }
        for (token, id) in [("system", 8948), ("user", 872), ("assistant", 77091)] {
            tokens.swapAt(tokens.firstIndex(of: token)!, id)
        }
        var vocab = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.element, $0.offset) })
        for id in 151643...151704 { vocab["<reserved\(id)>"] = id }
        for (token, id) in ["<|endoftext|>":151643,"<|im_start|>":151644,"<|im_end|>":151645,"<|audio_start|>":151669,"<|audio_end|>":151670,"<|audio_pad|>":151676,"<asr_text>":151704] { vocab.removeValue(forKey: "<reserved\(id)>"); vocab[token] = id }
        return (vocab, merges)
    }()

    private static func convertedConfig(_ dir: URL, large: Bool, bits: Int) throws {
        // Public converter schema; independent synthetic values, never a copied user config.
        var vocab = Self.tokenizerFixture.vocab
        var added: [String: [String: Any]] = [:]
        for (token, id) in Self.tokenizerFixture.vocab where id >= 151643 {
            vocab.removeValue(forKey: token); added[String(id)] = ["content": token]
        }
        try json(vocab, dir.appendingPathComponent("vocab.json"))
        try json(["added_tokens_decoder": added], dir.appendingPathComponent("tokenizer_config.json"))
        try json(["model_type":"qwen3_asr", "model_size":large ? "1.7B":"0.6B",
                  "audio_encoder":["hidden_dim":large ? 1024:896,"num_layers":large ? 24:18,"num_heads":large ? 16:14,"head_dim":64,"ffn_dim":large ? 4096:3584,"num_mel_bins":128],
                  "text_decoder":["hidden_size":large ? 2048:1024,"num_layers":28,"num_heads":16,"num_kv_heads":8,"head_dim":128,"intermediate_size":large ? 6144:3072,"vocab_size":151936,"rope_theta":1000000.0,"rms_norm_eps":0.000001],
                  "quantization_config":["bits":bits,"group_size":64,"quant_method":"minmax"]], dir.appendingPathComponent("config.json"))
    }
    // Independently enumerated from speech-swift 0.0.15 constructors and WeightLoading.swift.
    private static func tensors(large: Bool = false, bits: Int = 4) -> [String: (String, [Int])] {
        var result: [String: (String, [Int])] = [:]
        let a = large ? 1024 : 896, h = large ? 2048 : 1024, f = large ? 6144 : 3072
        func float(_ name: String, _ shape: [Int]) { result[name] = ("F16", shape) }
        func linear(_ name: String, _ input: Int, _ output: Int, _ bias: Bool = true) { float(name + ".weight", [output,input]); if bias { float(name + ".bias", [output]) } }
        func norm(_ name: String, _ width: Int) { float(name + ".weight", [width]); float(name + ".bias", [width]) }
        func quant(_ name: String, _ input: Int, _ output: Int) { result[name + ".weight"] = ("U32",[output,input * bits / 32]); float(name + ".scales", [output,input / 64]); float(name + ".biases", [output,input / 64]) }
        for i in 1...3 { float("audio_tower.conv2d\(i).weight", [480,3,3,i == 1 ? 1 : 480]); float("audio_tower.conv2d\(i).bias", [480]) }
        linear("audio_tower.conv_out",7680,a,false); norm("audio_tower.ln_post",a)
        linear("audio_tower.proj1",a,a); linear("audio_tower.proj2",a,h)
        for i in 0..<(large ? 24 : 18) {
            let p = "audio_tower.layers.\(i)"
            for n in ["q_proj","k_proj","v_proj","out_proj"] { linear(p + ".self_attn." + n,a,a) }
            norm(p + ".self_attn_layer_norm",a); norm(p + ".final_layer_norm",a)
            linear(p + ".fc1",a,a*4); linear(p + ".fc2",a*4,a)
        }
        quant("model.embed_tokens",h,151936); float("model.norm.weight",[h])
        for i in 0..<28 {
            let p = "model.layers.\(i)"
            quant(p + ".self_attn.q_proj",h,2048); quant(p + ".self_attn.k_proj",h,1024); quant(p + ".self_attn.v_proj",h,1024); quant(p + ".self_attn.o_proj",2048,h)
            float(p + ".self_attn.q_norm.weight",[128]); float(p + ".self_attn.k_norm.weight",[128])
            float(p + ".input_layernorm.weight",[h]); float(p + ".post_attention_layernorm.weight",[h])
            quant(p + ".mlp.gate_proj",h,f); quant(p + ".mlp.up_proj",h,f); quant(p + ".mlp.down_proj",f,h)
        }
        return result
    }
    private static func weights(_ tensors: [String: (String, [Int])], to url: URL, metadata: [String: Any]? = ["format": "mlx"]) throws {
        var header: [String: Any] = [:]; var offset: UInt64 = 0
        for name in tensors.keys.sorted() {
            let (type,shape) = tensors[name]!; let end = offset + UInt64(shape.reduce(1, *) * (type == "U32" ? 4 : 2))
            header[name] = ["dtype":type,"shape":shape,"data_offsets":[offset,end]]; offset = end
        }
        if let metadata { header["__metadata__"] = metadata }
        let body = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]); var count = UInt64(body.count).littleEndian
        var data = withUnsafeBytes(of: &count) { Data($0) }; data.append(body); try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(data.count) + offset) // sparse, no weight allocation/read
    }
    private static func whisperFixture(_ dir: URL) throws {
        for name in ["MelSpectrogram","AudioEncoder","TextDecoder"] {
            let package = dir.appendingPathComponent(name + ".mlmodelc")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data([1]).write(to: package.appendingPathComponent("coremldata.bin"))
            try Data("program(1.0) {}".utf8).write(to: package.appendingPathComponent("model.mil"))
        }
        try json(["model": ["type":"BPE", "vocab": ["a":0]], "added_tokens":[]], dir.appendingPathComponent("tokenizer.json"))
        try json(["tokenizer_class":"WhisperTokenizer"], dir.appendingPathComponent("tokenizer_config.json"))
    }
}

/// Observes accidental URL-loading requests at the Foundation boundary and blocks them.
private final class InspectionNetworkProbe: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); defer { lock.unlock() }; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        lock.lock(); count += 1; lock.unlock(); return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
