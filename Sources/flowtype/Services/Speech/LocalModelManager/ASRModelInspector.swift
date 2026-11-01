import Foundation

enum ASRModelInspector {
    static func inspect(directory: URL) throws -> ImportedASRModel {
        do {
            guard directory.isFileURL else { throw failure(.unreadable, "请选择本机模型目录。") }
            let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw failure(.unreadable, "模型目录不存在或不可读。")
            }
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if entries.contains(where: { ["mlmodelc", "mlpackage"].contains($0.pathExtension) }) {
                return try WhisperModelInspector.inspect(directory: directory)
            }
            if entries.contains(where: { WhisperModelInspector.hasModelComponents($0) }) {
                throw failure(.chooseSubdirectory, "请选择具体模型子目录，不能直接导入包含模型变体的仓库根目录。")
            }
            return try inspectQwen(directory)
        } catch let error as ASRModelInspectionError { throw error }
        catch { throw failure(.unreadable, "无法读取本机模型文件，请检查文件完整性和权限。") }
    }

    private static func inspectQwen(_ directory: URL) throws -> ImportedASRModel {
        let files = LocalInspectionFiles()
        let config = try files.json(directory.appendingPathComponent("config.json"))
        guard config["model_type"] as? String == "qwen3_asr" else {
            throw failure(.unsupportedFormat, "仅支持 Qwen3-ASR 0.6B/1.7B MLX 4/8-bit group64 或 WhisperKit Core ML 模型包。")
        }
        let audio: [String: Any], text: [String: Any], quantization: [String: Any]
        if let thinker = config["thinker_config"] as? [String: Any],
           let a = thinker["audio_config"] as? [String: Any],
           let t = thinker["text_config"] as? [String: Any],
           let q = config["quantization"] as? [String: Any] {
            guard config["audio_encoder"] == nil, config["text_decoder"] == nil else {
                throw failure(.invalidMetadata, "模型包含冲突的架构配置结构。")
            }
            audio = a; text = t; quantization = q
        } else if let a = config["audio_encoder"] as? [String: Any],
                  let t = config["text_decoder"] as? [String: Any],
                  let q = config["quantization_config"] as? [String: Any] {
            guard config["thinker_config"] == nil, config["quantization"] == nil,
                  q["quant_method"] as? String == "minmax", config["model_size"] is String else {
                throw failure(.unsupportedFormat, "不支持此转换器配置或量化方式。")
            }
            var normalizedAudio = a, normalizedText = t
            for (target, source) in ["d_model":"hidden_dim", "encoder_layers":"num_layers", "encoder_attention_heads":"num_heads", "encoder_ffn_dim":"ffn_dim"] {
                guard let value = a[source], a[target] == nil else { throw failure(.invalidMetadata, "转换器音频配置缺失或冲突：\(source)") }
                normalizedAudio[target] = value
            }
            guard let head = a["head_dim"], try LocalInspectionFiles.integer(head) == 64 else {
                throw failure(.unsupportedFormat, "转换器音频 head_dim 必须为 64。")
            }
            for (target, source) in ["num_hidden_layers":"num_layers", "num_attention_heads":"num_heads", "num_key_value_heads":"num_kv_heads"] {
                guard let value = t[source], t[target] == nil else { throw failure(.invalidMetadata, "转换器文本配置缺失或冲突：\(source)") }
                normalizedText[target] = value
            }
            // The supported converter omits these constructor constants. Every corresponding
            // convolution/projector/embedding tensor is still checked below; no size is guessed.
            if normalizedAudio["output_dim"] == nil { normalizedAudio["output_dim"] = t["hidden_size"] }
            if normalizedAudio["downsample_hidden_size"] == nil { normalizedAudio["downsample_hidden_size"] = 480 }
            if normalizedText["tie_word_embeddings"] == nil { normalizedText["tie_word_embeddings"] = true }
            audio = normalizedAudio; text = normalizedText; quantization = q
        } else { throw failure(.unsupportedFormat, "不支持此 Qwen3-ASR MLX 配置结构。") }
        func number(_ object: [String: Any], _ key: String) throws -> Int64 {
            guard let value = object[key] else { throw failure(.invalidMetadata, "config 缺少 \(key)。") }
            return try LocalInspectionFiles.integer(value)
        }
        let bits = try number(quantization, "bits")
        guard [4,8].contains(bits), try number(quantization, "group_size") == 64 else {
            throw failure(.unsupportedFormat, "仅支持 MLX 4/8-bit、group_size=64 的量化。")
        }
        if let mode = quantization["mode"], mode as? String != "affine" { throw failure(.unsupportedFormat, "仅支持 MLX affine 量化。") }
        if config["quantization"] != nil, let additional = config["quantization_config"] {
            guard let additional = additional as? [String:Any],
                  try number(additional,"bits") == bits, try number(additional,"group_size") == 64 else {
                throw failure(.invalidMetadata, "两套量化元数据不一致。")
            }
            if let method = additional["quant_method"], !["minmax","affine","mlx"].contains(method as? String ?? "") {
                throw failure(.unsupportedFormat, "不支持此量化方式。")
            }
        }
        let hidden = try number(text, "hidden_size")
        guard [1024,2048].contains(hidden) else { throw failure(.unsupportedFormat, "不支持此 Qwen3-ASR 规模。") }
        let large = hidden == 2048
        if let modelSize = config["model_size"] as? String, modelSize != (large ? "1.7B" : "0.6B") {
            throw failure(.invalidMetadata, "model_size 与模型维度冲突。")
        }
        let a: Int64 = large ? 1024 : 896, layers = large ? 24 : 18, f: Int64 = large ? 6144 : 3072
        let textExpected: [String: Int64] = ["hidden_size":hidden,"num_hidden_layers":28,"num_attention_heads":16,"num_key_value_heads":8,"head_dim":128,"intermediate_size":f,"vocab_size":151936]
        let audioExpected: [String: Int64] = ["d_model":a,"encoder_layers":Int64(layers),"encoder_attention_heads":large ? 16 : 14,"encoder_ffn_dim":a*4,"num_mel_bins":128,"output_dim":hidden,"downsample_hidden_size":480]
        for (object, expected) in [(text,textExpected),(audio,audioExpected)] {
            for (key,value) in expected where try number(object,key) != value { throw failure(.unsupportedFormat, "config 与受支持加载器布局不符：\(key)") }
        }
        guard text["tie_word_embeddings"] as? Bool == true else { throw failure(.unsupportedFormat, "当前加载器要求共享词嵌入。") }
        // Reject overrides to architecture constants which this loader does not read from config.
        for (key, expected) in ["max_source_positions":1500,"n_window":50,"n_window_infer":800,"conv_chunksize":500] {
            if audio[key] != nil, try number(audio,key) != Int64(expected) { throw failure(.unsupportedFormat, "不支持此音频配置：\(key)") }
        }
        func optionalConstant(_ object: [String:Any], _ key: String, _ expected: Double) throws {
            guard let raw = object[key] else { return }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == expected else {
                throw failure(.unsupportedFormat, "不支持此配置值：\(key)")
            }
        }
        try optionalConstant(text,"rms_norm_eps",0.000001)
        try optionalConstant(text,"rope_theta",1_000_000)
        try optionalConstant(audio,"layer_norm_eps",0.00001)
        if let value = text["hidden_act"], value as? String != "silu" { throw failure(.unsupportedFormat, "不支持此文本激活函数。") }
        if text["rope_scaling"] != nil && !(text["rope_scaling"] is NSNull) { throw failure(.unsupportedFormat, "当前加载器不支持导入自定义 RoPE scaling。") }
        let manifest = try SafetensorsManifest.read(directory: directory, files: files)
        var required = Set<String>()
        func tensor(_ name: String, _ shape: [Int64], quantized: Bool = false) throws {
            required.insert(name)
            guard let tensor = manifest.tensors[name], tensor.shape == shape,
                  quantized ? tensor.dtype == "U32" : ["F16","BF16","F32"].contains(tensor.dtype) else {
                throw failure(.invalidTensor, "缺少张量或形状/类型不符：\(name)")
            }
        }
        func linear(_ name: String, _ input: Int64, _ output: Int64, bias: Bool = true) throws {
            try tensor(name + ".weight", [output,input]); if bias { try tensor(name + ".bias", [output]) }
        }
        func norm(_ name: String, _ width: Int64) throws {
            try tensor(name + ".weight", [width]); try tensor(name + ".bias", [width])
        }
        func quant(_ name: String, _ input: Int64, _ output: Int64) throws {
            try tensor(name + ".weight", [output,input*bits/32], quantized: true)
            try tensor(name + ".scales", [output,input/64]); try tensor(name + ".biases", [output,input/64])
        }
        // Exact MLX NHWC convolutions consumed without transpose by WeightLoader.loadWeights.
        for i in 1...3 {
            try tensor("audio_tower.conv2d\(i).weight", [480,3,3,i == 1 ? 1 : 480])
            try tensor("audio_tower.conv2d\(i).bias", [480])
        }
        try linear("audio_tower.conv_out",7680,a,bias:false); try norm("audio_tower.ln_post",a)
        try linear("audio_tower.proj1",a,a); try linear("audio_tower.proj2",a,hidden)
        for i in 0..<layers {
            let p = "audio_tower.layers.\(i)"
            for projection in ["q_proj","k_proj","v_proj","out_proj"] { try linear(p + ".self_attn." + projection,a,a) }
            try norm(p + ".self_attn_layer_norm",a); try norm(p + ".final_layer_norm",a)
            try linear(p + ".fc1",a,a*4); try linear(p + ".fc2",a*4,a)
        }
        try quant("model.embed_tokens",hidden,151936); try tensor("model.norm.weight",[hidden])
        for i in 0..<28 {
            let p = "model.layers.\(i)"
            try quant(p + ".self_attn.q_proj",hidden,2048); try quant(p + ".self_attn.k_proj",hidden,1024)
            try quant(p + ".self_attn.v_proj",hidden,1024); try quant(p + ".self_attn.o_proj",2048,hidden)
            try tensor(p + ".self_attn.q_norm.weight",[128]); try tensor(p + ".self_attn.k_norm.weight",[128])
            try tensor(p + ".input_layernorm.weight",[hidden]); try tensor(p + ".post_attention_layernorm.weight",[hidden])
            try quant(p + ".mlp.gate_proj",hidden,f); try quant(p + ".mlp.up_proj",hidden,f); try quant(p + ".mlp.down_proj",f,hidden)
        }
        // Known converter export: the runtime deliberately uses embedTokens.asLinear for
        // tied logits and ignores this redundant float head. Validate its layout, but do
        // not claim its payload equals the quantized embedding (payloads are never read).
        if manifest.tensors["lm_head.weight"] != nil { try tensor("lm_head.weight", [151936,hidden]) }
        guard Set(manifest.tensors.keys) == required else { throw failure(.unsupportedFormat, "权重包含当前加载器不支持的额外张量。") }
        try validateQwenTokenizer(directory, files: files)
        try files.verify()
        var minimumResidentBytes: UInt64 = 0
        for tensor in manifest.tensors.values where tensor.dtype == "U32" {
            var bytes: UInt64 = 4
            for dimension in tensor.shape {
                let next = bytes.multipliedReportingOverflow(by: UInt64(dimension))
                guard !next.overflow else { throw failure(.invalidTensor, "张量内存尺寸溢出。") }
                bytes = next.partialValue
            }
            let next = minimumResidentBytes.addingReportingOverflow(bytes)
            guard !next.overflow else { throw failure(.invalidTensor, "张量内存总量溢出。") }
            minimumResidentBytes = next.partialValue
        }
        return ImportedASRModel(name: directory.lastPathComponent, directory: directory.resolvingSymlinksInPath(), engine: .qwenMLX,
                                variant: large ? "1.7B" : "0.6B", bits: Int(bits), sizeBytes: manifest.sizeBytes,
                                tokenizerDirectory: directory.resolvingSymlinksInPath(), fileFingerprint: files.fingerprint,
                                minimumResidentBytes: minimumResidentBytes)
    }

    private static func validateQwenTokenizer(_ directory: URL, files: LocalInspectionFiles) throws {
        let raw = try files.json(directory.appendingPathComponent("vocab.json"))
        var vocab: [String: Int64] = [:]; var ids: [Int64: String] = [:]
        for (token, value) in raw {
            let id = try LocalInspectionFiles.integer(value)
            guard !token.isEmpty, id >= 0, id < 151936, ids[id] == nil else { throw failure(.invalidMetadata, "词表 token ID 越界或重复。") }
            vocab[token] = id; ids[id] = token
        }
        // Qwen's 151936 embedding rows include padding: only 0..<151643 are
        // ordinary byte-BPE tokens. Added tokens must never conceal missing base rows.
        let baseCount = 151643
        guard (0..<baseCount).allSatisfy({ ids[Int64($0)] != nil }) else {
            throw failure(.incompleteModel, "Qwen 基础词表不完整（需要连续的 0…151642 token ID）。")
        }
        let bytes = Array(33...126) + Array(161...172) + Array(174...255)
        let alphabet = Set((bytes + Array(256..<(512 - bytes.count))).compactMap(Unicode.Scalar.init))
        let base = vocab.filter { $0.value < Int64(baseCount) }
        guard alphabet.allSatisfy({ base[String($0)] != nil }),
              base.keys.allSatisfy({ $0.unicodeScalars.allSatisfy(alphabet.contains) }) else {
            throw failure(.invalidMetadata, "Qwen 基础词表必须包含完整的 byte-BPE 字母表。")
        }
        let config = try files.json(directory.appendingPathComponent("tokenizer_config.json"))
        if let additions = config["added_tokens_decoder"] {
            guard let tokens = additions as? [String: [String: Any]] else { throw failure(.invalidMetadata, "added_tokens_decoder 格式无效。") }
            for (key, value) in tokens {
                guard let id = Int64(key), id >= 0, id < 151936, let token = value["content"] as? String, !token.isEmpty,
                      ids[id] == nil || ids[id] == token, vocab[token] == nil || vocab[token] == id else {
                    throw failure(.invalidMetadata, "附加 token 与词表冲突。")
                }
                vocab[token] = id; ids[id] = token
            }
        }
        // IDs 151643...151704 are added/special tokens. 151705..<151936 are
        // padded model slots, not missing vocabulary; converters may leave them absent.
        guard (151643...151704).allSatisfy({ ids[Int64($0)] != nil }) else {
            throw failure(.incompleteModel, "Qwen 附加 token 集合不完整。")
        }
        for (token, id) in ["<|endoftext|>":151643,"<|im_start|>":151644,"<|im_end|>":151645,"<|audio_start|>":151669,"<|audio_end|>":151670,"<|audio_pad|>":151676,"<asr_text>":151704,"Ċ":198,"system":8948,"user":872,"assistant":77091] {
            guard vocab[token] == Int64(id) else { throw failure(.incompleteModel, "词表缺少加载器需要的特殊 token：\(token)") }
        }
        let merges = try files.read(directory.appendingPathComponent("merges.txt"))
        guard let string = String(data: merges, encoding: .utf8) else {
            throw failure(.invalidMetadata, "BPE merges.txt 必须是 UTF-8 文本。")
        }
        var reachable = Set(alphabet.map(String.init))
        var pairs = Set<String>()
        for (index, line) in string.components(separatedBy: .newlines).enumerated() {
            if line.isEmpty || (index == 0 && line == "#version: 0.2") { continue }
            // '#' itself is a valid byte token; only the version header is a comment.
            let pair = line.components(separatedBy: " ")
            guard pair.count == 2, pair.allSatisfy({ !$0.isEmpty && base[$0] != nil && reachable.contains($0) }),
                  base[pair.joined()] != nil, pairs.insert(line).inserted,
                  reachable.insert(pair.joined()).inserted else {
                throw failure(.invalidMetadata, "BPE 合并规则包含无效引用、重复结果或错误顺序。")
            }
        }
        guard reachable == Set(base.keys), pairs.count == baseCount - alphabet.count else {
            throw failure(.incompleteModel, "BPE 合并规则不完整，不能覆盖全部基础词表。")
        }
    }
}
