# C3 — Unified imported local-engine lifecycle

Base: `9f0c92e`. Implemented Task 3 from its brief and the approved M2-C spec in the existing worktree. No subagents, GUI/relaunch, model download, cache deletion, Python, network experiment, real user configuration/keys/audio fixtures, push, merge, or history reset.

## Behavior and C4 handoff

The existing `QwenModelState` class remains the single coordinator (legacy class name retained). `ModelProvisionTarget.imported(ImportedASRModel)` enters the same `ProvisionGate`, operation/attempt ownership checks, cancellation and draining path as presets. There is no separate imported-runtime queue or automatic fallback. The default candidate loader calls `LocalASRRuntimeFactory.load(_:)`, which remains strictly offline for both runtimes.

- `useImportedModel(_:) async throws`: intended C4 “load and use” action after a static preview. Reinspects the supplied directory under the provision gate, refreshes the descriptor (including fingerprint and reservation), preserves the staged display name, resolves the existing canonical library UUID **before runtime construction**, assesses current resources, then loads. Callers must not save selection or library fields independently. Direct `.imported` requests through `perform` cannot bypass these steps.
- `importOfflineModel(at:) async throws`: existing folder entry point now inspects a generic supported ASR directory, then uses the same transaction. An invalid static import retains `pendingImportDirectory` so retry cannot become a preset request. Initial inspection/staging does not write config.
- `removeImportedModel(id:)`: removes the library record and clears active reference/legacy aliases as appropriate. Does not unload the active lease or any capture-retained lease. Matching recovery target/pending directory is cleared, including canonical aliases, so retry cannot resurrect removed intent. Busy operations reject removal.
- `selectPreset(_:automatic:) async`: settings preset selection and “use 0.6B” now request a transaction instead of first overwriting settings. Failure/cancellation retains prior imported selection. Success clears imported active reference and both legacy paths while preserving the library. `automatic: true` keeps the automatic-selection preference; a named manual preset persists its ID.
- `hardwareAssessment` publishes the admission result; `importFailureDetail` exposes actionable inspection/resource explanation; `pendingImportDirectory` identifies a static import failure before a descriptor exists. `operationID` remains the UI busy/disable boundary. `activeLease` always describes the usable model independently of candidate status/target.
- Injected `inspect`, `assessHardware`, and `saveConfiguration` closures support deterministic isolated tests. Production `.shared` wires the central save to `ConfigurationStore.shared.save`; isolated coordinator constructors default to no persistence unless a save closure is supplied. Existing `commit` callback remains a lease notification, not a second selection writer.

Successful owned loading performs one synchronous main-actor configuration transaction, reading the **latest** configuration to preserve unrelated settings edited while loading. It upserts the fresh descriptor, persists the active UUID, and clears selected preset/legacy aliases. Qwen imports also synchronize `customLocalModelPath`; Whisper clears it. Runtime-verified Whisper metadata replaces static `unverified` only in this successful transaction. Cancelled/failed candidates never write library/selection/verified metadata. The new lease is then published without an intervening suspension.

Startup resolves active imported UUID first, without inspecting/trying unrelated rows or an installed/recommended preset. Missing active UUID is a local failure. With no imported active reference, explicit legacy paths are staged/inspected and migrate only on runtime success. Existing preset/onboarding/explicit-choice behavior remains. Internal `.offline(ResolvedModel)` now represents installed-preset compatibility and retries as `.offline`, not as a new custom import.

`ModelRecoveryActions` no longer performs a post-await save after import. Settings reads the observed central store and calls the coordinator for selection, eliminating the independent stale save and early preset-selection mutation. C4 should continue these bindings rather than holding and later saving a whole configuration snapshot. Current generic status card now understands imported/pending-directory targets and uses resource details; full library/preview UI remains C4 scope.

Capture semantics required no replacement architecture: `ASRRouter.captureStartRoute` already copies the immutable active lease, `ASRStage` already selects that provider, `ReadinessSnapshotBuilder` prioritizes a usable lease over candidate error, and `SessionController.backendLabel` already uses captured identity. New tests run those production boundaries for actual Qwen→Whisper fixture transitions. The compatible local routing slot stays `qwen-local`; actual identity engines are `qwenMLX` / `whisperCoreML`. Startup logs now report local ASR and the lease engine. No global context or routing-policy edits occur during switching.

## Resource assessment and approved additive API

Added `LocalModelHardwareAssessment.assess(model:physicalMemory:availableMemory:activeModelBytes:)` plus an overload with injected `isAppleSilicon`. Result has `compatibility` (`compatible`, `warning`, `incompatible`), `explanation`, `recommendedMinimumMemory`, and `minimumResidentBytes`.

- MLX is blocked on non-Apple-Silicon architecture; Core ML is assessed separately and does not inherit this restriction.
- Qwen 4-bit 0.6B/1.7B retain 4/8 GiB product recommendations. Being below a recommendation alone produces a warning, not an assertion of impossible runtime. 8-bit and Whisper peaks remain unmeasured. All presently supported successful admission assessments remain warnings because peak requirements are unmeasured; `compatible` is reserved for a future evidenced assessment.
- Per controller ruling, `ImportedASRModel.minimumResidentBytes: UInt64?` and `LocalASRLease.minimumResidentBytes: UInt64?` are additive/backward-compatible fields. The name represents a **conservative reservation policy**, not measured OS residency or a mathematical minimum under mmap/paging. C1 inspection sums validated packed U32 quantized tensor payload bytes with checked arithmetic, excluding float weights, metadata, tokenizer, and optional redundant float output head. The Qwen runtime factory carries the fresh value onto the lease. Old nil fields get refreshed by reinspection; Whisper and old preset leases may remain unknown.
- Reject when the candidate reservation exceeds current available-memory estimate, or candidate plus known active reservation exceeds physical RAM. Combined arithmetic is overflow-safe. The current usable lease is retained; messages explain the reservation policy and suggest freeing memory or a smaller model. Unknown active residency is not treated as a known zero. Disk size is never used to assert a peak or reserve every file byte.
- Production available memory is a Mach `host_statistics64` free + inactive page estimate; Darwin headers document speculative pages as already included in free_count, so they are not counted twice. Query failure yields nil. Inactive pages may require paging and the estimate does not promise allocation success. CPU architecture and all resource quantities are injectable in tests.

## TDD and verification evidence

All log paths below are under `.superpowers/sdd/2026-11-01-m2-c-hf-import/`; commands ran at the repository root with the full log paths as shown.

1. Behavioral RED before implementation:
   - `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-3-red-build.log 2>&1`, exit 0.
   - `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-3-red.log 2>&1`, exit 1: **2179 passed, 3 failed**.
   - Expected failures: `imported restart must never preflight a preset — got 2, want 0`; `imported restart restores only active item strictly offline — got [false, false], want [true]`; `failed imported restore must never fall back to preset`. The old coordinator ignored the configured active imported row and used its automatic Qwen preset path.
2. Implementation compile iteration: `swift build > .../task-3-build-1.log 2>&1`, exit 1. macOS rejects `os_proc_available_memory()` and its type; replaced it with the documented Mach estimate. No runtime/network test was attempted from this compile failure.
3. Successful intermediate builds: `swift build > .../task-3-build-2.log 2>&1` (27.00s), `task-3-build-3.log` (33.60s), `task-3-build-4.log`, and `task-3-build-5.log` (22.36s), all exit 0. These accompanied implementation/self-review edits; no repeated full suite per edit.
4. First expanded full GREEN: after build-5, `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-3-self-test-1.log 2>&1`, exit 0: **2261 passed, 0 failed** (product build 4.50s).
5. Self-review identified internal installed-preset `.offline` retry being passed through the generic folder-import entry point by an old `ModelRecoveryActions` branch. Removed that branch and added a regression asserting two `.offline` attempts without library migration. Final sequential build/self-test are recorded below.

New tests cover restart selection/no networking, legacy missing resource metadata refresh, failed/cancelled/successful Qwen→Whisper transactions, cancel-draining ownership, no config write before success, one central commit, concurrent unrelated settings preservation, duplicate canonical UUID before candidate construction, fingerprint refresh, verified Whisper family persistence and subsequent static-unverified reinspection, real capture/ASRStage provider retention, new-session provider selection, real history identity, readiness with an old usable lease, record removal/capture survival/restart, legacy success-only migration, preset success-only selection, resource rejection before runtime construction, missing active UUID, invalid static import retry, and installed-preset offline retry. Hardware tests include architecture, 4/8 GiB recommendations, 8-bit/unknown peaks, availability unknown, packed-weight reservation rejection, old+new physical budget and overflow. C1 synthetic inspection tests additionally verify optional float output-head exclusion and symlink canonical UUID resolution. A/B old fixture I/O adapts imported descriptors to the old synthetic resolved-model callbacks; its production coordinator/recovery/configuration code remains real.

No `swift test` was run. Fixtures use only synthetic model descriptors/providers, temporary sparse metadata files, synthetic Float audio, and isolated UserDefaults suites. No real model files are loaded by these tests.

## Files and self-review

Created:
- `Sources/flowtype/Services/Speech/LocalModelManager/LocalModelHardwareAssessment.swift`
- `Sources/flowtype/Testing/ImportedLifecycleSelfTests.swift`

Modified:
- `Services/Speech/QwenModelState.swift`: imported lifecycle/transaction/restore/removal/preset selection.
- `Services/Speech/ModelProvisioning/{ModelProvisionRequest,LocalASRLease,ModelRecoveryActions,ModelRecoveryPresentation}.swift`.
- `Services/Speech/LocalModelManager/{ImportedASRModel,ASRModelInspector,LocalASRRuntimeFactory,LocalModelLibrary}.swift`.
- `Settings/{LocalModelPicker,QwenModelStatusCard,SettingsPage+ASR}.swift` and `App/FlowTypeApp.swift`.
- `Testing/{LocalModelImportSelfTests,ModelProvisionSelfTests,SelfTest}.swift`.

Self-review checked the final diff for pre-success config mutations, preset fallback eligibility, UUID assignment timing, stale callback/cancel behavior, resource-estimate arithmetic and wording, legacy alias resurrection, and no local-route identity substitution. It caught speculative-page double counting (fixed using Darwin header contract), removed-row alias recovery (clears the pending canonical directory), and offline-preset retry distinction. `git diff --check` is clean. The existing coordinator is a large file; this change adds focused transaction/inspection methods and one focused hardware helper without restructuring unrelated lifecycle code.

Warnings are not claimed pristine: inherited AppLogger warning remains; a broader implementation rebuild also emitted existing AppleSpeechProvider lock-result, DownloadSource deprecated regionCode, AVFoundation conversion warnings, and the C2 forced-cast warning. No unrelated warning cleanup was performed.

**Actual-runtime acceptance remains Pending:** no full Qwen or Whisper model load/inference, actual offline device execution, model quality, long audio, hardware peak, or GUI acceptance is claimed. Synthetic lifecycle/capture tests establish ownership and configuration behavior, not real-model correctness. C4 owns the full library/detection UI and user-facing source/help coverage.

## Final sequential verification / commit

- `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-3-build-final.log 2>&1`: exit **0**, `Build complete! (22.43s)`. Final incremental build emits the inherited AppLogger warning only.
- Followed sequentially by `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-3-self-test-final.log 2>&1`: exit **0**, `=== self-test: 2263 passed, 0 failed ===` (product build 4.47s).
- `git diff --check` and `git diff --cached --check`: clean.
- Commit **`63db2e9` — `feat: route sessions through selected imported local engine`**. 18 scoped source/test files, 575 insertions / 52 deletions. Report/logs live in the ignored local `.superpowers` handoff directory. No source changes or repeated test run after this unchanged commit.
- Final status: **DONE**. Real-runtime/GUI acceptance remains **Pending** as explicitly scoped; no other blocking concern identified in self-review. Fresh controller review remains required.
