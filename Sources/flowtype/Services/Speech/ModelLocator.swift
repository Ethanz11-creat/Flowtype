import Foundation

struct ResolvedModel: Equatable {
    let directory: URL
    let modelId: String
}

enum ModelLocator {
    static let defaultMinWeightsBytes: Int64 = 600 * 1024 * 1024

    static func validateComplete(_ dir: URL, minBytes: Int64 = defaultMinWeightsBytes) -> Bool {
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

    static func knownCacheDirs() -> [URL] {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let home = fm.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        if let caches {
            dirs.append(caches.appendingPathComponent("qwen3-speech/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit", isDirectory: true))
            dirs.append(caches.appendingPathComponent("qwen3-speech/aufklarer_Qwen3-ASR-0.6B-MLX-4bit", isDirectory: true))
            dirs.append(caches.appendingPathComponent("qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit", isDirectory: true))
            dirs.append(caches.appendingPathComponent("qwen3-speech/aufklarer_Qwen3-ASR-1.7B-MLX-4bit", isDirectory: true))
        }
        if let snap06B = hfHubSnapshotDir(home: home, repo: "Qwen3-ASR-0.6B-MLX-4bit") { dirs.append(snap06B) }
        if let snap17B = hfHubSnapshotDir(home: home, repo: "Qwen3-ASR-1.7B-MLX-4bit") { dirs.append(snap17B) }
        return dirs
    }

    static func hfHubSnapshotDir(home: URL, repo: String) -> URL? {
        let folder = repo.replacingOccurrences(of: "/", with: "--")
        let repoDir = home.appendingPathComponent(".cache/huggingface/hub/models--aufklarer--\(folder)", isDirectory: true)
        let ref = repoDir.appendingPathComponent("refs/main")
        guard let rev = try? String(contentsOf: ref, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !rev.isEmpty else { return nil }
        return repoDir.appendingPathComponent("snapshots/\(rev)", isDirectory: true)
    }

    static func firstCompleteLocalCopy(configured: URL?) -> URL? {
        var dirs: [URL] = []
        if let configured { dirs.append(configured) }
        dirs.append(contentsOf: knownCacheDirs())
        return dirs.first(where: { validateComplete($0) })
    }

    /// When user has explicitly selected a model (selectedLocalModelID != nil):
    ///   - Search: custom path → selected preset dir → known caches (legacy)
    ///   - Do NOT silently fall back to other presets (user chose 1.7B, don't give them 0.6B)
    /// When no explicit selection (auto mode):
    ///   - Search: custom path → all preset dirs (recommended first) → known caches
    static func candidateDirectories(configured: URL?, selectedPreset: ModelPreset?, autoMode: Bool) -> [URL] {
        var dirs: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            if !seen.contains(path) {
                seen.insert(path)
                dirs.append(url)
            }
        }

        if let configured { add(configured) }

        if autoMode {
            let recommended = ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())
            add(recommended.localDirectory())
            for preset in ModelPreset.allPresets {
                if preset.id == recommended.id { continue }
                add(preset.localDirectory())
            }
        } else if let selectedPreset {
            add(selectedPreset.localDirectory())
        }

        for cacheDir in knownCacheDirs() { add(cacheDir) }

        return dirs
    }

    /// Resolves the active model directory and matching modelId from Configuration.
    /// Uses preset-specific size thresholds for validation to avoid accepting a 0.6B download as 1.7B.
    static func resolveActiveModel(config: Configuration) -> ResolvedModel? {
        let configured: URL?
        if let custom = config.customLocalModelPath, !custom.isEmpty {
            configured = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else if let legacy = config.localModelPath, !legacy.isEmpty {
            configured = URL(fileURLWithPath: (legacy as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            configured = nil
        }

        let selectedPreset = ModelPreset.preset(forID: config.selectedLocalModelID)
        let autoMode = (selectedPreset == nil)

        // Check custom path with default threshold (unknown size)
        if let configured {
            if validateComplete(configured) {
                let recommended = ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())
                let modelId = selectedPreset?.repoId ?? recommended.repoId
                return ResolvedModel(directory: configured, modelId: modelId)
            }
        }

        // Check preset directories with preset-specific thresholds
        let presetsToCheck: [ModelPreset]
        if let selected = selectedPreset {
            presetsToCheck = [selected]
        } else {
            let recommended = ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())
            var list: [ModelPreset] = [recommended]
            for p in ModelPreset.allPresets where p.id != recommended.id {
                list.append(p)
            }
            presetsToCheck = list
        }

        for preset in presetsToCheck {
            let dir = preset.localDirectory()
            let minBytes = minValidBytes(for: preset)
            if validateComplete(dir, minBytes: minBytes) {
                return ResolvedModel(directory: dir, modelId: preset.repoId)
            }
        }

        // Legacy cache dirs — check for any valid preset
        for cacheDir in knownCacheDirs() {
            for preset in ModelPreset.allPresets {
                if validateComplete(cacheDir, minBytes: minValidBytes(for: preset)) {
                    return ResolvedModel(directory: cacheDir, modelId: preset.repoId)
                }
            }
        }

        return nil
    }

    /// Convenience: returns just the directory (for callers that don't need modelId).
    static func resolveActiveModelDirectory(config: Configuration) -> URL? {
        resolveActiveModel(config: config)?.directory
    }

    static func isPresetDownloaded(_ preset: ModelPreset) -> Bool {
        return validateComplete(preset.localDirectory(), minBytes: minValidBytes(for: preset))
    }

    static func minValidBytes(for preset: ModelPreset) -> Int64 {
        let floor = preset.expectedSizeBytes * 8 / 10
        return max(floor, defaultMinWeightsBytes)
    }
}
