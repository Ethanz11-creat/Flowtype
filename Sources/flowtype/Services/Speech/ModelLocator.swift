import Foundation

/// Finds and validates an on-disk copy of the Qwen3-ASR model, with NO network. Bounded to the
/// two well-known cache dirs + a user-specified folder — never a whole-machine scan.
enum ModelLocator {
    static let modelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static let minWeightsBytes: Int64 = 600 * 1024 * 1024   // ~600MB floor (real file is ~675MB)

    /// A copy is complete iff: config.json + a *.safetensors ≥ floor (symlinks resolved) + tokenizer.
    static func validateComplete(_ dir: URL, minBytes: Int64 = minWeightsBytes) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        let hasTokenizer = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
            || (fm.fileExists(atPath: dir.appendingPathComponent("tokenizer_config.json").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path))
        guard hasTokenizer else { return false }
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        for st in items where st.pathExtension == "safetensors" {
            let real = st.resolvingSymlinksInPath()
            if let size = (try? fm.attributesOfItem(atPath: real.path)[.size]) as? Int64, size >= minBytes {
                return true
            }
        }
        return false
    }

    /// The two well-known cache dirs (speech-swift's own + the hf-download hub snapshot).
    static func knownCacheDirs() -> [URL] {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let home = fm.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        if let caches {
            dirs.append(caches.appendingPathComponent("qwen3-speech/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit", isDirectory: true))
            dirs.append(caches.appendingPathComponent("qwen3-speech/aufklarer_Qwen3-ASR-0.6B-MLX-4bit", isDirectory: true))
        }
        if let snap = hfHubSnapshotDir(home: home) { dirs.append(snap) }
        return dirs
    }

    /// ~/.cache/huggingface/hub/models--aufklarer--Qwen3-ASR-0.6B-MLX-4bit/snapshots/<rev>/ (rev from refs/main).
    static func hfHubSnapshotDir(home: URL) -> URL? {
        let repo = home.appendingPathComponent(".cache/huggingface/hub/models--aufklarer--Qwen3-ASR-0.6B-MLX-4bit", isDirectory: true)
        let ref = repo.appendingPathComponent("refs/main")
        guard let rev = try? String(contentsOf: ref, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !rev.isEmpty else { return nil }
        return repo.appendingPathComponent("snapshots/\(rev)", isDirectory: true)
    }

    /// First complete copy: the user-specified folder, then the known caches. Nil if none.
    static func firstCompleteLocalCopy(configured: URL?) -> URL? {
        var dirs: [URL] = []
        if let configured { dirs.append(configured) }
        dirs.append(contentsOf: knownCacheDirs())
        return dirs.first(where: { validateComplete($0) })
    }
}
