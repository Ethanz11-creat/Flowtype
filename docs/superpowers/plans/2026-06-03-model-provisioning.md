# Production Model Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make Qwen3-ASR loading production-grade: load an existing local copy offline (never re-download / never stall), let users point at a model folder, and on a genuine first run download via a mirror with a stall watchdog + clear states.

**Architecture:** A pure `ModelLocator` (validate + find a complete local copy) and a pure `DownloadSource` (endpoint mapping) feed `QwenModelState`'s load ladder: specified folder → known caches (offline) → mirror download (watchdog + retry) → terminal error card. `QwenASRProvider.loadModel` forwards `cacheDir`/`offlineMode` to `Qwen3ASRModel.fromPretrained` (already supports them — no speech-swift fork).

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, speech-swift (`Qwen3ASRModel.fromPretrained(modelId:cacheDir:offlineMode:progressHandler:)`).

**Spec:** `docs/superpowers/specs/2026-06-03-model-provisioning-design.md`

**Verify:** `swift build` green; `swift run FlowType --self-test` (currently 80/0) grows with new pure tests; real gate = on-device matrix (Task 9). Ignore stale SourceKit "Cannot find X".

---

## File Structure
- **Create** `Sources/flowtype/Services/Speech/DownloadSource.swift` — pure source→endpoint.
- **Create** `Sources/flowtype/Services/Speech/ModelLocator.swift` — pure validate + locate.
- **Modify** `Sources/flowtype/Core/Configuration.swift` — `localModelPath`, `downloadSource`.
- **Modify** `Sources/flowtype/Services/Speech/QwenASRProvider.swift` — `cacheDir`/`offlineMode` params.
- **Modify** `Sources/flowtype/Services/Speech/QwenModelState.swift` — richer states + load ladder + watchdog.
- **Modify** `Sources/flowtype/App/FlowTypeApp.swift` — set `HF_ENDPOINT` at launch.
- **Modify** `Sources/flowtype/Settings/QwenModelStatusCard.swift` — source picker, folder picker, %/speed/ETA, retry, terminal card.
- **Modify** `Sources/flowtype/Testing/SelfTest.swift` — tests for the pure pieces.

---

## Task 1: DownloadSource (pure) + self-test

**Create** `Sources/flowtype/Services/Speech/DownloadSource.swift`:
```swift
import Foundation

/// Which Hugging Face endpoint to download the model from. `auto` uses the mirror in China.
enum DownloadSource: Codable, Equatable {
    case auto
    case official
    case mirror
    case custom(String)

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .official: return "官方"
        case .mirror: return "镜像"
        case .custom: return "自定义"
        }
    }

    static let mirrorEndpoint = "https://hf-mirror.com"

    /// The HF endpoint to set as HF_ENDPOINT, or nil to use the default (official huggingface.co).
    func endpoint(isChina: Bool) -> String? {
        switch self {
        case .auto:            return isChina ? Self.mirrorEndpoint : nil
        case .official:        return nil
        case .mirror:          return Self.mirrorEndpoint
        case .custom(let url):
            let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    /// Rough "is this machine in China" heuristic (region only; user can always override).
    static func systemIsLikelyChina() -> Bool {
        if #available(macOS 13, *) { return Locale.current.region?.identifier == "CN" }
        return (Locale.current.regionCode ?? "") == "CN"
    }
}
```

- [ ] **Step 1: Create the file.**
- [ ] **Step 2: Add self-test** in `SelfTest.swift` (method + register after `testAppearanceConfig(r)`):
```swift
    static func testDownloadSource(_ r: Reporter) {
        r.eq(DownloadSource.auto.endpoint(isChina: true), "https://hf-mirror.com", "src: auto+CN → mirror")
        r.eq(DownloadSource.auto.endpoint(isChina: false), nil, "src: auto+非CN → 官方(nil)")
        r.eq(DownloadSource.official.endpoint(isChina: true), nil, "src: official → nil")
        r.eq(DownloadSource.mirror.endpoint(isChina: false), "https://hf-mirror.com", "src: mirror → mirror")
        r.eq(DownloadSource.custom("https://x.example").endpoint(isChina: false), "https://x.example", "src: custom → custom")
        r.eq(DownloadSource.custom("   ").endpoint(isChina: false), nil, "src: blank custom → nil")
    }
```
Register: `testDownloadSource(r)   // model download source → endpoint` after `testAppearanceConfig(r)`.
- [ ] **Step 3:** `swift run FlowType --self-test` → `86 passed, 0 failed`.
- [ ] **Step 4: Commit** `feat(model): DownloadSource endpoint mapping (mirror in China)`.

---

## Task 2: Configuration — localModelPath + downloadSource

**Modify** `Sources/flowtype/Core/Configuration.swift`.

- [ ] **Step 1:** After `var appearancePreference: AppearancePreference = .system` add:
```swift
    // Model provisioning
    var localModelPath: String? = nil          // user-specified model folder (offline load)
    var downloadSource: DownloadSource = .auto
```
- [ ] **Step 2:** In `init(from:)` after the `appearancePreference` decode line add:
```swift
        localModelPath = (try? c.decode(String?.self, forKey: .localModelPath)) ?? d.localModelPath
        downloadSource = (try? c.decode(DownloadSource.self, forKey: .downloadSource)) ?? d.downloadSource
```
- [ ] **Step 3:** In `encode(to:)` after the `appearancePreference` encode line add:
```swift
        try container.encode(localModelPath, forKey: .localModelPath)
        try container.encode(downloadSource, forKey: .downloadSource)
```
- [ ] **Step 4:** In `CodingKeys` after `case appearancePreference` add:
```swift
        case localModelPath
        case downloadSource
```
- [ ] **Step 5:** Extend `testAppearanceConfig` (or a new test) with a round-trip: set `cfg.localModelPath = "/tmp/m"`, `cfg.downloadSource = .mirror`, encode→decode, assert both survive; and a legacy `{"asrLanguage":"zh"}` decodes `localModelPath == nil` and `downloadSource == .auto`. (Add 2-3 `r.eq`/`r.check`.)
- [ ] **Step 6:** `swift run FlowType --self-test` green; **Commit** `feat(model): persist localModelPath + downloadSource`.

---

## Task 3: ModelLocator (pure) + self-test

**Create** `Sources/flowtype/Services/Speech/ModelLocator.swift`:
```swift
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
```

- [ ] **Step 1:** Create the file.
- [ ] **Step 2: Self-test** (`testModelLocator`, register after `testDownloadSource`). Build a temp dir, write small fixture files, use a tiny `minBytes` so the test is cheap:
```swift
    static func testModelLocator(_ r: Reporter) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("flowtype-modeltest-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ name: String, _ bytes: Int) {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(count: bytes))
        }
        // incomplete: no files
        r.check(!ModelLocator.validateComplete(dir, minBytes: 100), "locator: empty dir → incomplete")
        write("config.json", 10); write("tokenizer.json", 10); write("model.safetensors", 200)
        r.check(ModelLocator.validateComplete(dir, minBytes: 100), "locator: config+tok+big weights → complete")
        // undersized weights
        r.check(!ModelLocator.validateComplete(dir, minBytes: 1000), "locator: weights below floor → incomplete")
        // missing config
        try? fm.removeItem(at: dir.appendingPathComponent("config.json"))
        r.check(!ModelLocator.validateComplete(dir, minBytes: 100), "locator: missing config → incomplete")
    }
```
- [ ] **Step 3:** self-test green; **Commit** `feat(model): ModelLocator — validate + locate local copy (offline)`.

---

## Task 4: QwenASRProvider — forward cacheDir/offlineMode

**Modify** `Sources/flowtype/Services/Speech/QwenASRProvider.swift` `loadModel` (lines 56-69):
```swift
    func loadModel(
        modelId: String = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
        cacheDir: URL? = nil,
        offlineMode: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        AppLogger.log("[QwenASR] Loading model: \(modelId) offline=\(offlineMode) cacheDir=\(cacheDir?.path ?? "default")")
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            cacheDir: cacheDir,
            offlineMode: offlineMode,
            progressHandler: progressHandler
        )
        queue.sync { model = loaded }
        AppLogger.log("[QwenASR] Model loaded successfully")
    }
```
- [ ] Build → **Commit** `feat(model): plumb cacheDir/offlineMode into QwenASRProvider.loadModel`.

---

## Task 5: QwenModelStatus — richer states

**Modify** `Sources/flowtype/Services/Speech/QwenModelState.swift` enum:
```swift
enum QwenModelStatus: Equatable {
    case notLoaded
    case downloading(progress: Double, speedMBps: Double, etaSeconds: Int)
    case stalled
    case loading
    case ready
    case error(reason: String, retryable: Bool)

    var isLoading: Bool {
        switch self {
        case .downloading, .loading, .stalled: return true
        default: return false
        }
    }
}
```
- [ ] Build (will break QwenModelState.loadModel + QwenModelStatusCard — fixed in Tasks 6 & 8; build at end of Task 6). This task is bundled with Task 6.

---

## Task 6: QwenModelState — load ladder + mirror + watchdog

**Modify** `Sources/flowtype/Services/Speech/QwenModelState.swift` — replace `loadModel(provider:)`:
```swift
    func loadModel(provider: QwenASRProvider) async {
        guard !status.isLoading else { return }
        if provider.isLoaded { status = .ready; return }

        let cfg = ConfigurationStore.shared.current
        let configured = cfg.localModelPath
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

        // 0 + 1: offline-first — specified folder, then known caches. Zero network.
        if let local = ModelLocator.firstCompleteLocalCopy(configured: configured) {
            status = .loading
            do {
                try await provider.loadModel(cacheDir: local, offlineMode: true)
                status = .ready
                AppLogger.log("[ModelProvision] Loaded offline from \(local.path)")
                return
            } catch {
                AppLogger.log("[ModelProvision] Offline load from \(local.path) failed (\(error)); falling through to download")
            }
        }

        // 2: download via the chosen endpoint, with stall watchdog + retry.
        applyDownloadEndpoint(cfg.downloadSource)
        await downloadWithRetry(provider: provider, maxAttempts: 3)
    }

    private func applyDownloadEndpoint(_ source: DownloadSource) {
        if let endpoint = source.endpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            setenv("HF_ENDPOINT", endpoint, 1)
            AppLogger.log("[ModelProvision] HF_ENDPOINT=\(endpoint)")
        } else {
            unsetenv("HF_ENDPOINT")
        }
    }

    private func downloadWithRetry(provider: QwenASRProvider, maxAttempts: Int) async {
        let totalBytes = 680.0 * 1024 * 1024
        for attempt in 1...maxAttempts {
            status = .downloading(progress: 0, speedMBps: 0, etaSeconds: 0)
            let progress = ProgressTracker()
            let loadTask = Task { [provider] in
                try await provider.loadModel(offlineMode: false) { @Sendable p, _ in
                    let snap = progress.update(fraction: p, totalBytes: totalBytes)
                    Task { @MainActor in
                        guard QwenModelState.shared.status.isLoading else { return }
                        if p >= 1.0 { QwenModelState.shared.status = .loading }
                        else { QwenModelState.shared.status = .downloading(progress: p, speedMBps: snap.mbps, etaSeconds: snap.eta) }
                    }
                }
            }
            // Watchdog: no progress for 30s → cancel this attempt.
            let watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if progress.secondsSinceLastTick() > 30 {
                        await MainActor.run { self?.status = .stalled }
                        loadTask.cancel()
                        return
                    }
                }
            }
            do {
                try await loadTask.value
                watchdog.cancel()
                status = .ready
                AppLogger.log("[ModelProvision] Downloaded + loaded (attempt \(attempt))")
                return
            } catch {
                watchdog.cancel()
                AppLogger.log("[ModelProvision] Download attempt \(attempt) failed: \(error)")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(Double(attempt * 10)))   // 10s/20s backoff
                } else {
                    status = .error(reason: "下载失败或停滞。可重试，或在设置里指定已下载的模型文件夹。", retryable: true)
                }
            }
        }
    }
```
Add a small progress/speed tracker at file scope:
```swift
/// Thread-safe download progress → speed (MB/s) + ETA + stall detection.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTick = Date()
    private var lastFraction = 0.0
    private var lastBytes = 0.0

    func update(fraction: Double, totalBytes: Double) -> (mbps: Double, eta: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        let bytes = fraction * totalBytes
        var mbps = 0.0
        if dt > 0.25, fraction > lastFraction {
            mbps = (bytes - lastBytes) / dt / (1024 * 1024)
            lastTick = now; lastFraction = fraction; lastBytes = bytes
        } else if fraction > lastFraction {
            lastFraction = fraction; lastBytes = bytes; lastTick = now
        }
        let remaining = max(0, totalBytes - bytes)
        let eta = mbps > 0.01 ? Int(remaining / (mbps * 1024 * 1024)) : 0
        return (mbps, eta)
    }

    func secondsSinceLastTick() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastTick)
    }
}
```
- [ ] Build (Tasks 5+6 together) → `swift build` green, self-test still green → **Commit** `feat(model): offline-first load ladder + mirror + stall watchdog + retry`.

---

## Task 7: FlowTypeApp — set HF_ENDPOINT at launch

**Modify** `Sources/flowtype/App/FlowTypeApp.swift`, after the `AppearanceController.apply(...)` line in `applicationDidFinishLaunching`:
```swift
        // Point HF at the chosen mirror BEFORE the first model load (the .app inherits no shell env).
        let src = ConfigurationStore.shared.current.downloadSource
        if let endpoint = src.endpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            setenv("HF_ENDPOINT", endpoint, 1)
        }
```
- [ ] Build → **Commit** `feat(model): set HF_ENDPOINT from downloadSource at launch`.

---

## Task 8: QwenModelStatusCard — picker + folder + progress + retry

**Modify** `Sources/flowtype/Settings/QwenModelStatusCard.swift`. Requirements (read the current file, keep its glassCard wrapper + status row, then):
1. **下载源 Picker** (segmented: 自动/官方/镜像) bound to `ConfigurationStore.shared.current.downloadSource`. (Custom URL can be deferred; if included, a TextField shown when 自定义.)
2. **「指定模型文件夹」button** → `NSOpenPanel` (`canChooseDirectories=true, canChooseFiles=false`); on pick, run `ModelLocator.validateComplete(url)`: if complete → set `ConfigurationStore.shared.current.localModelPath = url.path`, reload model; if not → show "所选文件夹不完整（缺少权重/配置/分词器）". Show the current `localModelPath` with a clear button.
3. **Status rendering** for the new enum: `.downloading(p, mbps, eta)` → progress bar + "下载中 NN% · X.X MB/s · 剩余 ~Ts"; `.stalled` → "下载停滞，正在重试…"; `.error(reason, retryable)` → red text + (if retryable) a **重试** button (calls `loadModel(provider:)` again); `.ready`/`.loading`/`.notLoaded` as today (keep the existing 加载/重试 buttons).
4. **Terminal-failure helper**: on `.error`, show a copyable one-liner:
   `HF_ENDPOINT=https://hf-mirror.com hf download aufklarer/Qwen3-ASR-0.6B-MLX-4bit --local-dir "~/Library/Caches/qwen3-speech/aufklarer_Qwen3-ASR-0.6B-MLX-4bit"`
   with a 复制 button (`NSPasteboard`).

Provide the reload entry point: a button action does `Task { await QwenModelState.shared.loadModel(provider: SessionController.shared.qwenProvider) }` (matches the existing `loadButton` pattern in the file).

- [ ] Build → self-test green → **Commit** `feat(model): status card — source picker, folder picker, progress/ETA, retry`.

---

## Task 9: On-device verification (manual)

- [ ] Build `.app`, launch. With the model already present (your machine): confirm it loads **instantly with Wi-Fi OFF** (proves offline-first; no stall).
- [ ] Settings → 「指定模型文件夹」→ point at `~/.cache/huggingface/hub/models--aufklarer--…/snapshots/<rev>` → validates + loads.
- [ ] Point it at an incomplete folder → clear "不完整" message, no crash.
- [ ] (Optional) Move/rename the caches, set source=镜像, relaunch → download shows %/speed/ETA; kill network mid-download → within ~30s shows 停滞 then retries; Retry works.
- [ ] 下载源 自动/官方/镜像 switch persists.
- [ ] Record results in `docs/feature-inventory.md` (a "模型加载" batch); push.

---

## Self-Review
- **Spec coverage:** specified folder (T2 config + T8 picker + T6 ladder step 0); offline-first known caches (T3 + T6 step 1); mirror default CN (T1 + T6 `applyDownloadEndpoint` + T7 launch); watchdog + retry + states (T5 + T6); never-silent-spinner UI + folder picker + command (T8); pure tests (T1, T2, T3). ✓
- **Placeholders:** complete code for T1-T7; T8 is a precise UI spec to apply against the read file (judgment UI, not a placeholder). ✓
- **Type consistency:** `DownloadSource.endpoint(isChina:)`, `ModelLocator.validateComplete(_:minBytes:)`/`firstCompleteLocalCopy(configured:)`, `QwenModelStatus.downloading(progress:speedMBps:etaSeconds:)`/`.stalled`/`.error(reason:retryable:)`, `QwenASRProvider.loadModel(modelId:cacheDir:offlineMode:progressHandler:)`, `Configuration.localModelPath`/`downloadSource` — consistent across tasks. ✓
