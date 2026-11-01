# M2 validation evidence — 2026-11-01 / closeout 2026-11-02

以下 A3 / B3 记录为历史检查点，其计数不代表最终 M2。当前状态、C4 历史检查点与全 M2 修复证据见文末；最终全范围源码门禁已通过（3a34a51，2430/0）；真实环境验收仍 Pending。

## Historical M2-A Task 3 source identity

- Base commit: `964b616af43987361e55f025d675fb4c695ad25a`.
- Validated `Sources/flowtype` tree SHA: `8c73e9b6e5c2a926e61a87c42ed04723d7747d50`. This Git tree identifies the exact Swift source used by the final sequential build/self-test; evidence/report prose does not change that source tree.
- Initial Task 3 commit: `c74daaf58dbbbc45e59946bdee8ea05a19111d2a`. Review-fix validation is against the subsequent commit titled `fix: persist recovered model imports and clear cancelled fallback`, containing this updated evidence file.

## Offline fixture verification

Final commands, executed sequentially in the existing `flowtype-local` worktree:

```sh
swift build
swift run FlowType --self-test
```

Logs: `.superpowers/sdd/2026-11-01-m2-a-model-recovery/logs/task-3-fix1-green-build.log` and `task-3-fix1-green-self-test.log`.

Fixture coverage includes capture-start lease retention across a replacement (all 3,207 samples reach the old provider; only the next capture uses the new provider), retained usable lease readiness after candidate failure, truthful 1.7B repository/command/source/destination, custom endpoint identity, offline folder import and invalid-folder retention, manual 0.6B override path clearing, deferred onboarding readiness, Apple-basic gating, terminal downloader ownership, terminal stalls, and future engine history labels. Existing coordinator retry, cancellation/draining, local-first bootstrap, and metadata fixtures also run in the full self-test. Final result: `swift build` exit 0 (26.95s); `swift run FlowType --self-test` exit 0, **1,559 passed, 0 failed**. The build retains the pre-existing `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning; no new warnings were introduced.

## Public metadata-only probe (controller)

Probe UTC: `2026-11-01T16:17:00Z`; compiled against base `964b616af43987361e55f025d675fb4c695ad25a` with the product `ModelMetadataPreflight`, `DownloadSource`, and error types. No model weights were downloaded. Log: `.superpowers/sdd/2026-11-01-m2-a-model-recovery/metadata-probe.log`.

| Source | Repository | Observed metadata result |
| --- | --- | --- |
| hf-mirror.com | aufklarer/Qwen3-ASR-0.6B-MLX-4bit | metadataInvalid, HTTP 308 |
| hf-mirror.com | aufklarer/Qwen3-ASR-1.7B-MLX-4bit | metadataInvalid, HTTP 308 |
| huggingface.co | aufklarer/Qwen3-ASR-0.6B-MLX-4bit | PASS, HTTP 200 after allowed same-origin relative redirects |
| huggingface.co | aufklarer/Qwen3-ASR-1.7B-MLX-4bit | PASS, HTTP 200 after allowed same-origin relative redirects |

This establishes metadata behavior only. It does not establish weight-download, model-load, GPU-inference, or GUI success. The standalone compiler's legacy `regionCode` deprecation came from its deployment target; the package targets macOS 15.

## Pending actual acceptance

V1–V5 remain **Pending**; offline fixtures do not replace them. Actual model download, switching download sources, choosing a real directory, model loading/inference, automatic downgrade, recording during a real replacement, recovery UI rendering/copying/actions, and onboarding GUI cases were not run by the worker. GUI verification belongs to the controller and must use CUA. No user configuration, keys, audio, or models were used as fixtures, and no existing models or caches were removed.

## Task 3 review fix round 1

Both Important findings were reproduced through the actual shared UI action/coordinator path before fixes: RED sequential build passed; self-test reported 1,553 passed and 6 failed. Four failures covered successful folder B retry leaving folder A/legacy/preset configuration and restart selection unchanged; two covered cancelling an automatic fallback while retaining an old 0.6B lease and falsely displaying “已退回 0.6B”. Logs: `logs/task-3-fix1-red-build.log` and `logs/task-3-fix1-red-self-test.log` in the SDD evidence directory.

Both folder pickers and card Retry now call ModelRecoveryActions. Offline retry uses the same verified import and successful ConfigurationStore.save action as initial import; failed/cancelled retries preserve folder A and its available lease. Cancellation clears the attempted fallback flag, so retaining an old 0.6B lease cannot imply a successful downgrade. The regression uses an isolated real ConfigurationStore and checks a re-created store after saving, with only model I/O replaced. GREEN result: sequential build exit 0; self-test exit 0, 1,559 passed and zero failed. No actual GUI/model cases or V1–V5 were promoted from Pending.

## Historical M2-B Task 3 — cloud setup and revision-owned checks

- Base commit: `042706e9ad698688ee8d493db9388c6e3a33d061`.
- Validated `Sources/flowtype` tree SHA: `92ab669df4373da9113a83c29b1f7ee91482715d`. The evidence/report prose does not change this source tree.
- Final sequential commands: `swift build` exit **0** (29.61s), then `swift run FlowType --self-test` exit **0**, **1,957 passed, 0 failed** (product build 4.57s).
- Logs: `.superpowers/sdd/2026-11-01-m2-b-cloud-providers/task-3-build.log`, `task-3-green.log`; full worker report: `task-3-report.md` in the same directory.

The new fixtures exercise the actual settings action/tracker and actual `CloudASRProvider`, with only HTTP transport replaced by an ephemeral URLProtocol fixture. They cover per-profile revision ownership; URL/model/Key/name/vendor/protocol/activation/all custom-field edits; deletion and shifted UUID bindings; late success/failure and cancellation; duplicate clicks while an obsolete request remains in flight; synchronous click ownership before queued work starts; zero upload when an edit precedes queued work; pure configuration checks with zero HTTP calls; honest WSS local-only state; rejection of invalid endpoint/blank model/blank Key by readiness; and immutable recording URL/model/Key after UI edits. These fixtures use synthetic hosts, credentials and samples, not real user configuration or audio.

TDD RED first established the missing tracker API. Self-review then reproduced a separate queued-click race through the real async action: **1,954 passed, 1 failed**, with an edited profile incorrectly marked connected. The synchronous shared button action now reserves revision/busy ownership before queuing transport. Final regression coverage is included in the GREEN result above. Only the pre-existing `AppLogger.swift:27` warning remains.

**GUI Pending:** vendor selection/defaults, URL editing, advanced fields and zero-network configuration checks await controller CUA on the newly built revision. The worker did not use GUI automation; the already running old PID 10836 is not evidence for this source revision.

**V1 Pending:** actual SiliconFlow and OpenAI model/field acceptance, each under normal network, weak network, offline and cancellation conditions. No authorized live configuration was used, no paid vendor request was made, and fixture success does not establish live support. Actual WSS handshake/recognition also remains Pending; the settings check explicitly performs local validation only, with real connection verification at recording. Existing V2–V5 Pending status is unchanged.

## Current M2 A → B → C checkpoints (2026-11-02)

| Checkpoint | Source / fixture evidence | Actual acceptance boundary |
| --- | --- | --- |
| A final stage | eb840f8; sequential build + self-test **1619/0**, stage-fix-report.md and progress.md in A workspace; scoped review clean | Download/recovery GUI and real-model switching not established |
| B final stage | 6fc1973; sequential build + self-test **2034/0**, B stage-fix-report.md and progress.md; scoped review clean | Actual SiliconFlow/OpenAI/WSS service variants Pending |
| C1 inspection/library | a36df21; **2113/0**, review/fix clean | Actual existing Qwen 1.7B MLX 4-bit static probe 4 PASS at 2026-11-01T18:40:27Z; size 2225411512 bytes; fingerprint 135f5b023e282e0c860d7b10a893487c5274dd012af5a203293d353eed3b1f22; no load/GPU/inference claim |
| C2 Whisper runtime | 9f0c92e; **2179/0**, task-2-report.md; exact WhisperKit 0.18.0, transformers 1.1.9 | Public HF tiny tokenizer metadata GET 2026-11-01T19:03:10Z HTTP 200; product adapter tokenizer-only harness PASS, 99 languages, exact yue=nil, zh=50260. No model graph/GPU/inference claim |
| C3 lifecycle/resources | 63db2e9; sequential build 22.43s + self-test **2263/0**, task-3-report.md / task-3-self-test-final.log | Synthetic providers establish ownership/config/capture/history behavior, not real-model correctness |
| C4 library/preview | 73d5e74; base 63db2e9; 2306/0 historical checkpoint below | GUI, full-model inference and final controller whole-M2 review Pending |

C workspaces and logs are under `.superpowers/sdd/2026-11-01-m2-c-hf-import/`; A/B evidence directories use the corresponding plan names. Actual C1 static log is `actual-17-static-probe-4.log`. These local handoffs are retained, not erased by C4.

Latest narrow actual static check: controller compiled the exact four inspector files at C3 source **63db2e9** and recorded hashes (`actual-17-static-c3-source-hashes.txt`). At **2026-11-01T19:49:34Z**, the existing Qwen **1.7B MLX 4-bit** directory passed static inspection again: size **2225411512**, unchanged fingerprint **135f5b023e282e0c860d7b10a893487c5274dd012af5a203293d353eed3b1f22**, conservative packed-U32 reservation **860225536 bytes**. Logs: `actual-17-static-c3-build.log` / `actual-17-static-c3-probe.log`. This reads local metadata only, with no shared build, runtime/GPU/model inference, networking or configuration changes; reservation is policy, not measured residency or peak.

### C4 implementation and evidence


`ImportedASRModelPresentation.make(model:assessment:isActive:)` provides real engine/variant/quantization, local path, disk size, active-lease status and hardware advice. `ImportedASRModelActions` owns cancellable off-main inspection previews and UUID actions only; `QwenModelState` remains the sole loader and success-only configuration writer. A preview never saves a path or active UUID. Existing/moved paths are inspected, then explicitly loaded; directory ownership is rechecked against current library state. Removing records leaves files and active/captured leases intact. Both download presets, recovery actions and explicit preset transactions remain available.

Settings/status/onboarding expose the same library and truthful engine/readiness descriptions. Help links cover both Qwen MLX presets and WhisperKit-compatible Core ML. Original PyTorch weights, scripts, Python installation, automatic conversion, model upload/copy and online file completion remain unsupported. Disk size is never claimed as peak memory; unknown residency/peak stays explicit.

Behavioral RED used the existing immediate-load picker action: sequential `swift build` exit 0 (`task-4-red-build-2.log`, 28.70s), then `swift run FlowType --self-test` exit 1 (`task-4-red.log`), **2264 passed / 1 failed**: selecting a folder invoked the runtime once, expected zero. An earlier compile-only iteration (`task-4-red-build.log`) exposed test ordering under Swift 6 isolation; moving the new main-actor fixture into the existing main-actor test group resolved it without production changes. Expanded regressions exercise actual preview actions/shared coordinator using temporary files, isolated UserDefaults and synthetic providers; no real model, user configuration, keys or audio.

First full C4 GREEN after build 30.54s was **2304 passed / 0 failed** (`task-4-build-green-1.log`, `task-4-self-test-green-1.log`). Self-review then added ownership checks for late load completion after preview dismissal, with a regression; the final sequential results below cover that additional change. Final controller scope is 878725c → final HEAD, including plans/specs/ledger; it has **not** passed in advance.

### Remaining actual acceptance and deferred review triage

- GUI Pending: old PID 10836 maps to M1 source 2588d56. The B-only 6fc1973 release bundle was built but not launched, and is not a current C4 binary. Earlier CUA `getApp` failed with `cgWindowNotFound`; fresh controller inventory has no matching native FlowType/TextEdit/Finder/System Settings/Activity Monitor surfaces and browser host is unavailable. No blind UI/shell substitute or restart occurred. Controller will build a final bundle after source stability and retry CUA.
- Full Qwen 0.6B / 1.7B × 4-bit / 8-bit and Whisper graph/quantization/hardware variants remain individually Pending for actual offline import/load, short synthetic dictation landing in a target app, long audio head/tail, cancellation, preset switch and failure recovery. Existing Qwen static success and Whisper tokenizer-only success are narrowly scoped above.
- V1–V5 remain mandatory, with credentials/network/device and Owner physical-action prerequisites in [live validation](2026-11-01-live-validation.md). No missing-credential/device variant is Pass; M3–M5 scope is unchanged.
- Final reviewer retains explicit minor triage: A native redirect delegate callback fixture absent (pure policy + actual metadata probes exist); C1 safetensors `__metadata__` string-to-string validation absent; C2 forced dictionary-cast warning; B credential-only bounded router-health recovery follow-up. These were not silently removed or refactored by C4.
- [Rulings archive](2026-11-01-m2-rulings.md) preserves every current A/B/C `Ruling:` ledger entry verbatim and in order, including C3's conservative reservation-policy decision. Reasons and cost-if-wrong remain with their entries.

### C4 final sequential verification

- `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-build-final.log 2>&1`: exit **0**, **23.57s**.
- Followed by `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-self-test-final.log 2>&1`: exit **0**, **2306 passed / 0 failed** (product build **4.56s**).
- Source revision: the C4 commit containing this evidence, based on **63db2e9**; no source changes after the final suite. `git diff --check` clean. Final incremental build reports inherited AppLogger warning only; other previously documented warnings remain separate.
- This completes C4 source/fixture verification only. Fresh controller task review, whole-M2 final gate, GUI/model/service/device acceptance remain explicitly Pending.

## Historical whole-M2 final fix wave (base 73d5e74)

The whole-M2 review found **three Important** source defects after the C4 checkpoint: ordinary retry changed automatic selection into an explicit fallback preset; Whisper relied on unsafe/incomplete graph dimension helpers; Qwen accepted truncated ordinary vocabularies/merges. This wave fixes all three. **Controller scoped rereview remains Pending**; the earlier review's Needs fixes verdict is not retroactively rewritten as Pass.

- Shared Retry now preserves the original selection target/origin separately from each mutable attempt target, refreshes the source from the current store, and retains automatic fallback and nil selection across persisted restart. Explicit retries stay explicit.
- Raw Core ML interfaces are checked before any pinned WhisperKit dimension helper: names/types/ranks, fixed output constraints, mel/encoder/decoder shapes, caches/masks/updates/alignment and optional prefill. All size families remain covered, including reduced decoder layer counts for distil/turbo; identity remains graph-derived family identity. Fixed Float16 pointer-copy outputs and strict matching intermediate dtypes follow the pinned runtime; arbitrary numeric coercions are not claimed. The pinned 0.18 Intel Float32/Float16 cache ABI mismatch is rejected at early hardware admission and runtime entry, with a specific help message and controller ruling. This is a current-runtime limitation, not a Core ML format limitation.
- Qwen requires full base IDs 0...151642, 256-byte alphabet, complete ordered/referenced BPE merges, and added IDs 151643...151704 with exact critical token IDs. Absent padded model slots remain legal; vocab/config split converted tokenizers remain accepted. Fixtures synthesize the complete vocabulary and merges without copying installed metadata.
- The two bounded minor items are fixed: safetensors `__metadata__` string-to-string type validation and the new forced dictionary bridge warning. Native redirect callback fixture and credential-only router-health reset remain explicit **nonblocking follow-ups**. Existing AppLogger warning is separate.

Behavioral focused RED was **164 passed / 54 failed**, then focused GREEN **267/0**. RED includes actual shared retry/persist/restart, ordinary token/merge truncation and raw graph rejection/readiness assertions. Final self-review further narrowed masks and added required-output regressions. Final sequential build: **exit 0, 30.08s** (`whole-m2-final-build.log`). Final full self-test: **exit 0, 2427 passed / 0 failed** (`whole-m2-final-self-test.log`, product build 4.64s). That GREEN covers the 5be1b4f checkpoint; the narrow mask correction below has separate changed-source verification. `git diff --check` was clean. The focused scope is `swift run FlowType --self-test --m2-fix-only`; all its tests also execute in the full suite. No `swift test`.

**Separate actual static acceptance:** exact four product inspector sources plus existing `inspect-probe-c3.swift` compiled successfully and inspected the authorized existing Qwen 1.7B MLX 4-bit directory at **2026-11-01T20:20:39Z**. Static PASS; **2225411512 bytes**, fingerprint **135f5b023e282e0c860d7b10a893487c5274dd012af5a203293d353eed3b1f22**, conservative packed-U32 reservation **860225536 bytes**, all unchanged. Logs/source hashes: `whole-m2-actual-static-build.log`, `whole-m2-actual-static-probe.log`, `whole-m2-actual-static-source-hashes.txt` in the C workspace. No payload read/GPU/load/inference/network/model/config/key changes. Structural completeness does not establish weight/tokenizer semantic equivalence or transcription quality.

Detailed per-finding changes, exact commands, compile iterations, pinned source/API hashes, self-review and limits: `whole-m2-fix-report.md` in the same workspace. Production helper `WhisperGraphContract.swift` stays focused on raw interfaces/ABI; added tests use the real coordinator/store and replace model compute. No actual Whisper full graph was available; public tiny tokenizer-only evidence stays separate. GUI/current binary, all actual full-model/quantization/hardware/service variants, measured memory/accuracy and mandatory V1–V5 remain **Pending**. Historical checkpoints and scratch evidence are retained.

### Historical scoped-review continuation: exact update-mask type

The same scoped reviewer found one remaining part of graph finding 2: accepting Float16 `kv_cache_update_mask` was unsupported by production evidence. Pinned `TextDecoder.prepareDecoderInputs` always allocates **Int32** (`TextDecoder.swift:275`), and `TextDecoderInput` stores/forwards it unchanged (`Models.swift:1016–1017,1033`). SDK `MLMultiArrayConstraint.dataType` is required; a manual upstream Float16 prediction fixture does not prove conversion in this production path.

Admission is now **Int32-only** for that feature. The canonical positive graph fixture matches production, and the Float16-negative case must fail without verified metadata. Import help and spec explicitly exclude **Float16 update-mask exports** until an adapter or contract-specific actual conversion evidence establishes compatibility; this is not a claim to support all WhisperKit exports. The controller's narrow continuation ruling is archived verbatim; other type/shape policies and all other fixes remain unchanged.

Test-only RED build passed in **29.27s**, then focused RED **274 passed / 2 failed**, exactly the incorrect Float16 acceptance and metadata publication (`whole-m2-mask-red-build.log`, `whole-m2-mask-red-self-test.log`). Final changed-source sequential build passed in **30.35s** (`whole-m2-mask-final-build.log`, inherited AppLogger warning only); full GREEN **exit 0, 2430 passed / 0 failed** (`whole-m2-mask-final-self-test.log`, product build 4.56s). No product/test edits after that GREEN; `git diff --check` clean. Latest source hashes: `whole-m2-mask-final-source-hashes.txt`; detailed continuation appended to `whole-m2-fix-report.md`, all in the C workspace.

Qwen inspector sources are unchanged, so the exact-product actual static PASS above was not redundantly rerun. No actual full graph/inference/GUI acceptance was added. `5be1b4f` release bundle is intermediate, built before these edits; the controller will rebuild after the stable correction commit. Same-reviewer incremental disposition, actual full models, GUI, services/devices and mandatory V1–V5 remain Pending.


## Final source gate and application bundle — 2026-11-02

**Source gate PASS:** final product commit **3a34a518073fc69afa06557bb745e2adc22641c9**, Sources/flowtype tree **ba7ed7b7edb109c3424309bf85599f455b50ffdc**. Fresh whole-M2 review covered 878725c → 73d5e74; the final worker fixed all three Important and two bounded Minor findings. The same independent scoped reviewer verified 73d5e74 → 5be1b4f and the narrow update-mask continuation 5be1b4f → 3a34a51, then returned **Spec PASS / Quality PASS**, no open Critical/Important. Earlier Pending/Needs-fixes entries above are historical checkpoints, not the current code-review status.

Final changed-source commands ran sequentially: `swift build` **exit 0, 30.35s**, followed by `swift run FlowType --self-test` **exit 0, 2430 passed / 0 failed**. The inherited AppLogger warning remains; the new forced dictionary-cast warning was fixed. Product/test sources did not change after this run; subsequent closeout changes are documentation/evidence only, so the suite was not repeated on unchanged code.

`bash scripts/build-app.sh` then completed **exit 0** against stable **3a34a51**. Application: `build/FlowType.app`, arm64, ad-hoc `com.flowtype.app`; executable SHA256 **a8bcdd51e1fa5f4faded9796e078199e1cb88044924fe3a5acda23443a421fd0**, CDHash **534e9339780406d69bc5fe83e4018e3050065778**. This is a development bundle, not a notarized release. Final CUA `getApp` using that exact bundle path returned **-10005 cgWindowNotFound**; no successful updated-window observation, restart, inference or actual delivery is claimed.

Durable [review, logs and build identity archive](2026-11-01-m2-artifacts/README.md) preserves selected plain-text evidence and maps old scratch filenames before temporary SDD workspace cleanup. It includes final review/fix reports, source hashes, actual static/tokenizer-only checks, final full-suite logs and bundle identity. The [20 decision entries](2026-11-01-m2-rulings.md) preserve why and the cost if wrong. Historical scratch paths above identify original execution locations; use the archive index for retained evidence.

**Actual acceptance remains mandatory Pending:** full Qwen/Whisper loading and inference (including .mlpackage), per-variant hardware/memory/accuracy, new GUI/current running binary, real cloud service acceptance and V1–V5. Existing Qwen static and public Whisper tokenizer-only PASS are narrower evidence. Current pinned WhisperKit 0.18 runtime rejects Intel's FloatType/cache ABI mismatch and Float16-declared update-mask exports; these are explicit current adapter limits. No existing models, caches, credentials or private audio/transcripts were changed or used as fixtures.

Nonblocking follow-ups remain the native URLSession redirect-delegate callback fixture and credential-only router-health revision/reset (bounded 60-second recovery); neither is an open Critical/Important. Branch/worktree are preserved; no push or merge.
