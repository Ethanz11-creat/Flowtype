# Production Model Provisioning — Design Spec

**Date:** 2026-06-03
**Status:** Approved (owner sign-off 2026-06-03)
**Topic:** Make Qwen3-ASR model loading production-grade — never silently stall, and reuse a model the user already has (auto-detected or a folder they pick).

---

## 1. Problem (ground-truthed against the speech-swift checkout)

Model: `aufklarer/Qwen3-ASR-0.6B-MLX-4bit`, ~680 MB, loaded by speech-swift `Qwen3ASRModel.fromPretrained`.

- **No mirror → stalls in China.** speech-swift resolves URLs against `huggingface.co`; the only override is the `HF_ENDPOINT` env var, which the `.app` GUI process never has. So downloads hit huggingface.co (blocked/throttled behind the GFW).
- **No stall timeout → silent infinite hang (the real "下载不动").** The download `URLSession` resets its 60 s timeout on *every received byte*. A trickle connection never times out and never throws, so `snapshot()` suspends forever; the existing retry only fires on a *throw*, so it never runs. The UI pins at "下载中 X%" with no Retry.
- **Won't reuse a manual download.** speech-swift caches under `~/Library/Caches/qwen3-speech/` and does **not** read the `~/.cache/huggingface/hub/...` cache that `hf download` writes. Its "installed?" check is just "any `*.safetensors` exists", so a half file counts as complete.
- **The model is usually already on disk** (verified: `~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit/model.safetensors`, 708 MB, complete). The daily annoyance is an *occasional per-launch network revalidation* that hangs — not a from-scratch download.

`fromPretrained` already accepts `cacheDir: URL?` and `offlineMode: Bool`; FlowType just never passes them. **Everything below is implementable in FlowType with no speech-swift fork.**

## 2. Decisions (locked with owner)

| Decision | Choice |
|---|---|
| Download source default | **Auto: use hf-mirror.com when the system region/locale is China**, else huggingface.co. Manual 官方 / 镜像 / 自定义 switch in Settings. |
| Bundle model in .app/DMG | **No** — keep external, provisioned on demand (DMG stays small for GitHub release). |
| Reuse local model | **Both** auto-detect existing caches **and** a first-class "选择已下载的模型文件夹" folder picker. |
| Core principle | **Offline-first**: if a complete local copy exists (configured, picked, or detected), load it with `offlineMode: true` and touch the network **zero** times — this fixes both the reuse ask and the per-launch stall. |
| speech-swift fork | **Not now.** A true per-request URLSession timeout + first-class `endpoint:` are the only fork-worthy items; deferred. |

## 3. The load ladder (what `loadModel` does)

Never an indefinite silent spinner. The status card is an explicit state machine.

```
0. SPECIFIED FOLDER  — Configuration.localModelPath (set via the「指定模型文件夹」picker).
     THE primary reuse mechanism. validateComplete? → load with cacheDir=<that folder>,
       offlineMode:true → READY ✓  (resolve symlinks when validating, e.g. an hf-download cache)
     incomplete → surface "已选文件夹不完整" + fall through

1. OFFLINE-FIRST from two KNOWN cache dirs (NO network, NO folder ops — the daily path):
     a. ~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit/  (speech-swift's own — what it uses today)
     b. ~/.cache/huggingface/hub/models--aufklarer--Qwen3-ASR-0.6B-MLX-4bit/snapshots/<rev>/  (hf download; resolve symlinks → blobs)
     first that validateComplete → offlineMode:true (cacheDir = that copy) → READY ✓
     (This is why the model already loads in 7–30 s today; forcing offlineMode:true here is
      what kills the occasional per-launch network-revalidation stall AND guarantees no re-download.)
     (Bounded to these two well-known cache dirs — NOT a whole-machine scan. Anything elsewhere
      is handled by the user pointing the folder picker at it, step 0.)

2. NETWORK DOWNLOAD (only if no usable local copy)
     setenv HF_ENDPOINT per the chosen source (CN auto → hf-mirror.com)
     fromPretrained(progressHandler:) wrapped in a FlowType WATCHDOG:
       • progress → % + MB/s + ETA (total ≈680 MB)
       • STALL WATCHDOG: no byte delta for 30 s → cancel the Task, then retry
       • retry ≤3× backoff+jitter (5/15/45 s); relaunch/HTTP-Range resume makes restarts cheap
     success → validateComplete → READY ✓

3. ALL AUTO PATHS FAILED → terminal card (never spin):
     "下载停滞/失败：<原因>"
       [重试]                          (resumes)
       [切换下载源: 官方 / 镜像 / 自定义]
       [选择已下载的模型文件夹]          ← NSOpenPanel(directory) → validate → persist localModelPath
       documented one-liner (copyable):
         HF_ENDPOINT=https://hf-mirror.com hf download aufklarer/Qwen3-ASR-0.6B-MLX-4bit \
           --local-dir "~/Library/Caches/qwen3-speech/aufklarer_Qwen3-ASR-0.6B-MLX-4bit"
```

**`validateComplete(dir)`** (pure, testable): `config.json` present **and** a weights file (`*.safetensors`) whose size ≥ ~600 MB floor (ideally matches `model.safetensors.index.json` `metadata.total_size`) **and** tokenizer present (`tokenizer.json` **or** `tokenizer_config.json` + `vocab.json` + `merges.txt`). Resolve symlinks before sizing.

## 4. Architecture / files

**New:**
- `Sources/flowtype/Services/Speech/ModelLocator.swift` — pure-ish: `validateComplete(URL) -> Bool` (resolves symlinks) + `knownCacheDirs() -> [URL]` (the two well-known caches: speech-swift's + the HF hub snapshot) + `firstCompleteLocalCopy() -> URL?`. No whole-machine scan. `validateComplete` unit-testable with a temp dir.
- `Sources/flowtype/Services/Speech/DownloadSource.swift` — `enum DownloadSource { case auto, official, mirror, custom(String) }` + `endpoint(isChina:) -> String?` (pure) + a region check. Unit-testable.
- `Sources/flowtype/Services/Speech/ModelProvisioner.swift` — orchestrates the ladder + the stall watchdog (wraps `fromPretrained` in a cancellable `Task`, monitors progress deltas), emits `QwenModelState`.

**Modified:**
- `Core/Configuration.swift` — add `localModelPath: String?` and `downloadSource: DownloadSource` (backward-compat decode → nil / .auto; encode; CodingKeys).
- `Services/Speech/QwenASRProvider.swift:56-69` — `loadModel` accepts/uses `cacheDir` + `offlineMode` (driven by the provisioner).
- `Services/Speech/QwenModelState.swift` — richer states: `.downloading(progress, speedMBs, etaSec)`, `.stalled`, `.error(reason, retryable)`, plus `.ready`/`.notLoaded`.
- `App/FlowTypeApp.swift:~38` — `setenv("HF_ENDPOINT", …)` from `downloadSource` **before** the launch load Task.
- `Settings/QwenModelStatusCard.swift` — 下载源 picker; **「选择已下载的模型文件夹」** button (NSOpenPanel → validate → persist); %/speed/ETA; Retry; terminal card + copyable command; "在 Finder 中显示模型" + size readout.

**Reference only (no edits unless we later fork):** `.build/checkouts/speech-swift/Sources/AudioCommon/HuggingFaceDownloader.swift`.

## 5. Testing

- **Self-test (`--self-test`)**: `DownloadSource.endpoint(isChina:)` (auto→mirror in CN, official/mirror/custom mapping); `ModelLocator.validateComplete` against a constructed temp dir (complete → true; missing config / undersized weights / missing tokenizer → false); `Configuration` round-trip + legacy-missing-keys → defaults.
- **Manual on-device matrix** (the real gate): (a) with the model already present → loads instantly, **zero network** (confirm via no stall even with Wi-Fi off); (b) delete local copy, fresh download via mirror shows %/speed/ETA and completes; (c) simulate a stall (e.g. block hf during download) → watchdog cancels at 30 s → Retry works; (d) point the folder picker at the `~/.cache/huggingface/...` copy → validates + loads; (e) point it at an incomplete folder → clear "不完整" message, no crash; (f) source switch 官方↔镜像 takes effect.

## 6. Open risks (verify on device)

- **Stall watchdog cancellation**: confirm cancelling the `fromPretrained` Task mid-download actually stops it and a retry resumes (swift-transformers cancels via `withTaskCancellationHandler`, but verify end-to-end).
- **HF symlink cache (path c)**: copying flat files out of the symlinked `snapshots/<rev>/` must resolve symlinks to real blobs.
- **`HF_ENDPOINT` timing**: must be `setenv` before the *first* `fromPretrained`; changing source after first load needs a reload.
- **Region auto-detect**: `Locale`/region "is China" heuristic — provide the manual override so a wrong guess is never a dead end.

## 7. Non-goals (v1)

- No speech-swift fork (no true URLSession timeout / `endpoint:` param) — FlowType-side watchdog + env mirror instead.
- No bundling the model in the app.
- No multi-model management UI (single ASR model).
