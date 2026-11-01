import Foundation
import Tokenizers
@main struct PublicTokenizerContractCheck {
    static func main() async throws {
        let root = URL(fileURLWithPath: ".superpowers/sdd/2026-11-01-m2-c-hf-import/task-2-fix1-public-tokenizer")
        let raw = try await AutoTokenizer.from(modelFolder: root)
        let local = try LocalWhisperTokenizer(tokenizer: raw)
        let expected = try WhisperRuntimeMetadata(logitsSize: 51865, encoderSize: 384, decoderSize: 384)
        try local.validate(for: expected)
        precondition(local.allLanguageTokens.count == 99)
        precondition(local.convertTokenToId("<|yue|>") == nil)
        precondition(local.convertTokenToId("<|zh|>") == 50260)
        print("PUBLIC TOKENIZER CONTRACT PASS: 99 languages; raw absent yue=\(String(describing: raw.convertTokenToId("<|yue|>"))); exact yue=nil; zh=50260")
        print("Existing downloaded public tokenizer metadata only; expected graph dimensions supplied; no model graph/weights/GPU/inference.")
    }
}
