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

    static func inspectQwen(_ directory: URL) throws -> ImportedASRModel {
        let files = LocalInspectionFiles()
        let config = try files.json(directory.appendingPathComponent("config.json"))
        let metadata = try NativeASRFormatSupport.qwenMetadata(config)
        let bits = metadata.bits, hidden = metadata.hidden, large = metadata.large
        let a = metadata.audioWidth, layers = metadata.audioLayers, f = metadata.intermediate
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
