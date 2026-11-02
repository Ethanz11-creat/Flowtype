import Foundation
enum Fixture {
    static func json(_ object: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url) }
    static func editJSON(_ dir: URL, _ name: String, _ edit: (inout [String: Any]) -> Void) throws {
        let url = dir.appendingPathComponent(name)
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&value); try json(value, url)
    }
    static func rawHeader(_ header: String, _ dir: URL, payloadBytes: Int = 0) throws {
        let body = Data(header.utf8); var n = UInt64(body.count).littleEndian
        var data = withUnsafeBytes(of: &n) { Data($0) }; data.append(body)
        data.append(Data(repeating:0, count:payloadBytes))
        try data.write(to: dir.appendingPathComponent("model.safetensors"))
    }
    static func qwenFixture(_ dir: URL, large: Bool = false, bits: Int = 4) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json(["model_type": "qwen3_asr", "quantization": ["bits": bits, "group_size": 64], "thinker_config": ["audio_config": ["d_model": large ? 1024 : 896, "encoder_layers": large ? 24 : 18, "encoder_attention_heads": large ? 16 : 14, "encoder_ffn_dim": large ? 4096 : 3584, "num_mel_bins": 128, "output_dim": large ? 2048 : 1024, "downsample_hidden_size": 480], "text_config": ["hidden_size": large ? 2048 : 1024, "num_hidden_layers": 28, "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 128, "intermediate_size": large ? 6144 : 3072, "vocab_size": 151936, "tie_word_embeddings": true]]], dir.appendingPathComponent("config.json"))
        try json(Self.tokenizerFixture.vocab, dir.appendingPathComponent("vocab.json"))
        try json(["added_tokens_decoder": [:]], dir.appendingPathComponent("tokenizer_config.json"))
        try Data(Self.tokenizerFixture.merges.utf8).write(to: dir.appendingPathComponent("merges.txt"))
        try weights(tensors(large: large, bits: bits), to: dir.appendingPathComponent("model.safetensors"))
    }
    // Complete synthetic byte BPE, independent of any installed/public model metadata.
    static let tokenizerFixture: (vocab: [String: Int], merges: String) = {
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

    static func convertedConfig(_ dir: URL, large: Bool, bits: Int) throws {
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
    static func tensors(large: Bool = false, bits: Int = 4) -> [String: (String, [Int])] {
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
    static func weights(_ tensors: [String: (String, [Int])], to url: URL, metadata: [String: Any]? = ["format": "mlx"]) throws {
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
}
@main struct Probe { static func main() throws {
let root = URL(fileURLWithPath: "/tmp/flowtype-m2-independent-review-20261102/timing-model")
try Fixture.qwenFixture(root)
for _ in 0..<2 { let start = Date(); let model = try ASRModelInspector.inspect(directory: root); print("inspection-seconds=\(Date().timeIntervalSince(start)) engine=\(model.engine) bytes=\(model.sizeBytes)") }
} }
