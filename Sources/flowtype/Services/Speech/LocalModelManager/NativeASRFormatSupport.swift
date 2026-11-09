import Foundation

/// Metadata can identify a candidate only; tensor, graph and runtime verification remain mandatory.
enum NativeASRFormatSupport {
    static func assessMetadata(config: Data?, paths: [String]) throws -> LocalASREngine {
        try LocalASRRuntimeRegistry.standard.engine(config: config, paths: paths)
    }

    struct QwenMetadata {
        let bits: Int64
        let hidden: Int64
        let large: Bool
        let audioWidth: Int64
        let audioLayers: Int
        let intermediate: Int64
    }

    /// One strict architecture contract for metadata previews and complete on-disk inspection.
    static func qwenMetadata(_ config: [String: Any]) throws -> QwenMetadata {
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
        return .init(bits: bits, hidden: hidden, large: large, audioWidth: a, audioLayers: layers, intermediate: f)
    }
}
