import Foundation

struct ASRModelRecipe: Equatable, Sendable {
    let id: String
    let version: Int
    let displayName: String
    let sources: [HFRepositorySelection]
    let variant: String?
    let engine: LocalASREngine
    /// True only after the actual native validation matrix passes, never from metadata inspection.
    let verified: Bool
}

enum ASRModelRecipes {
    // Research snapshot 2026-11-09. Base tokenizer frozen from one metadata-only read on 2026-11-10:
    // https://huggingface.co/api/models/openai/whisper-base (8598 bytes; no weight request).
    private static func source(_ repo: String, _ commit: String) -> HFRepositorySelection {
        .init(repoID: repo, requestedRevision: commit, subdirectory: nil)
    }
    static let all: [ASRModelRecipe] = [
        .init(id: "qwen3-0.6b-4bit", version: 1, displayName: "Qwen3-ASR 0.6B (4-bit)",
              sources: [source("aufklarer/Qwen3-ASR-0.6B-MLX-4bit", "bc441bd1e4295c1f42d9879f056049a925b6e013")],
              variant: nil, engine: .qwenMLX, verified: false),
        .init(id: "qwen3-1.7b-4bit", version: 1, displayName: "Qwen3-ASR 1.7B (4-bit)",
              sources: [source("aufklarer/Qwen3-ASR-1.7B-MLX-4bit", "d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6")],
              variant: nil, engine: .qwenMLX, verified: false),
        .init(id: "whisper-tiny", version: 1, displayName: "Whisper tiny（多语言）",
              sources: [source("argmaxinc/whisperkit-coreml", "0f63a7800b00dd0226abd051b906c246e1907482"),
                        source("openai/whisper-tiny", "169d4a4341b33bc18d8881c4b69c2e104e1cc0af")],
              variant: "openai_whisper-tiny", engine: .whisperCoreML, verified: false),
        .init(id: "whisper-base", version: 1, displayName: "Whisper base（多语言）",
              sources: [source("argmaxinc/whisperkit-coreml", "0f63a7800b00dd0226abd051b906c246e1907482"),
                        source("openai/whisper-base", "e37978b90ca9030d5170a5c07aadb050351a65bb")],
              variant: "openai_whisper-base", engine: .whisperCoreML, verified: false)
    ]

    static func tokenizerRepoID(forVariant variant: String?) -> String? {
        guard let variant, variant.hasPrefix("openai_whisper-") else { return nil }
        let name = String(variant.dropFirst("openai_".count))
        guard ["whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large", "whisper-large-v2", "whisper-large-v3",
               "whisper-tiny.en", "whisper-base.en", "whisper-small.en", "whisper-medium.en"].contains(name) else { return nil }
        return "openai/" + name
    }

    static func match(repository: HFResolvedRepository, tokenizer: HFResolvedRepository?, prefix: String,
                      engine: LocalASREngine) -> ASRModelRecipe? {
        all.first { recipe in
            guard recipe.engine == engine, let source = recipe.sources.first,
                  repository.selection.repoID == source.repoID, repository.commit == source.requestedRevision,
                  prefix == (recipe.variant ?? "") else { return false }
            if recipe.sources.count == 1 { return true }
            guard let tokenizer else { return false }
            return tokenizer.selection.repoID == recipe.sources[1].repoID && tokenizer.commit == recipe.sources[1].requestedRevision
        }
    }
}
