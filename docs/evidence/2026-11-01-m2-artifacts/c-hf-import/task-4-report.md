# C4 — Imported ASR model library, inspection preview and honest acceptance closeout

Base **63db2e9**, existing linked worktree. Implemented the authoritative Task 4 brief and approved spec. No subagents, GUI/relaunch, release build, downloads/cache deletion, real configuration/keys/audio fixtures, Python/scripts, push/merge/history reset, or ignored scratch deletion. Controller owns fresh task review and final whole-M2 review from 878725c through final HEAD.

## Behavior and APIs

- Added required `ImportedASRModelPresentation.make(model:assessment:isActive:)`: UUID, display name, actual Qwen MLX / Whisper Core ML family and variant/quantization, true local source path, formatted disk bytes, active-lease status, hardware explanation and available actions. Unknown Whisper graph variant is “规模待加载验证”; unknown peak/residency remains explicit. Static compatibility never means ready. Shared availability text is used by status/onboarding, including honest defer-setup state.
- Added focused `ImportedASRModelActions`, owning **only** static preview state. `stage(directory:replacing:)` reserves an inspection UUID synchronously; production inspection uses a detached task with cancellation forwarding, reads the existing bounded inspector off-main, and ignores cancelled/obsolete completions. `stageExisting(id:)` resolves a fresh row by UUID. `cancelInspection()` invalidates ownership without config writes. `loadPreview()` delegates exclusively to `QwenModelState.useImportedModel`; there is no new runtime lifecycle or post-await config save. C3 still reinspects under its global gate, resolves canonical UUID, assesses hardware and commits only owned success.
- Relocation preserves the row UUID/name and stages the new directory. Preview does not alter selection/path. Failed load leaves prior config/usable lease; successful coordinator load updates the row/path/active ID in its existing transaction. Conflicts with another row's canonical directory are checked at inspection completion and again immediately before load; removed/reordered rows cannot redirect an action or resurrect a removed preview. New import deduplicated to an existing row also tracks that row's ownership.
- `remove(id:)` removes the durable record via the coordinator only, not files or loaded/captured leases. All runtime work respects coordinator busy state. A preview has its own token so a late load completion/cancellation after sheet dismissal cannot alter new/dismissed preview state.
- Added `ImportedASRModelList` and its reusable sheet: independent import button → directory selection → progress/cancellable static check → detected details/hardware advice → explicit “加载并使用”; supports multiple rows, inspection/switch, relocation, removal and specific failure messages. Missing paths visibly offer relocation. Model controls use UUIDs, never array indices. Settings embeds the list; status and onboarding open the same list sheet.
- Both 0.6B and 1.7B preset downloads and recovery remain. Preset selection is now an explicit action menu (avoids falsely displaying “automatic” while an imported row is active); installed preset “使用” uses C3's success-only transaction. Busy state disables preset deletion. Actual status derives from the usable lease, independent of a candidate's failure.
- Help links cover both Qwen MLX presets and `argmaxinc/whisperkit-coreml`. Copy explains supported 0.6B/1.7B, 4/8-bit group64 and compatible Core ML, local-only/no upload/no weight copy, no Python/repo scripts/automatic conversion/network completion, and raw PyTorch incompatibility. Settings offline availability is conditional on successful load. No M3–M5 scope changed.

## TDD and verification

Commands below ran sequentially at repository root; all log paths share `.superpowers/sdd/2026-11-01-m2-c-hf-import/` prefix.

1. Initial compile iteration: `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-red-build.log 2>&1`, exit **1**. Placing the new main-actor regression before existing nonisolated test groups triggered Swift 6 Reporter region-isolation diagnostics. Moved it beside the existing main-actor lifecycle/UI tests; no production change for this iteration.
2. Behavioral RED: `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-red-build-2.log 2>&1`, exit **0**, 28.70s. Then `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-red.log 2>&1`, exit **1**, **2264 passed, 1 failed**. Failure: `import UI: folder selection must inspect without constructing a runtime — got 1, want 0`. It exercised the old picker action `ModelRecoveryActions.importOfflineModel`; selecting a directory immediately loaded, violating staged preview requirements.
3. Implementation compile: `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-build-1.log 2>&1`, exit **0**, 33.24s. Self-review then tightened cross-row relocation ownership and target path display before the full suite.
4. First full GREEN: sequential `swift build` (30.54s) then `swift run FlowType --self-test` (product build 4.62s), both exit **0**, **2304 passed, 0 failed**. Originally written to final log paths, retained as `task-4-build-green-1.log` and `task-4-self-test-green-1.log` before the subsequent changed-source check.
5. Final self-review added preview-token ownership around post-await UI messages/dismissal and the regression for closing/cancelling a suspended load. Final sequential build and suite results are appended below. This late hardening regression was added before the final check, not separately claimed as an observed RED.

Tests use production presentation/actions/shared coordinator and isolated ConfigurationStore; only inspection/model compute are injected. They assert zero runtime/config writes for static preview, real family/source/active identity, unknown peak advice, incompatible action disabling, both preset catalog entries, supported source/help, unsupported concrete reason, defer-onboarding honesty, UUID reorder/deletion and directory collision, failed/successful relocation, successful-only update, removal leaving synthetic file and lease alive, obsolete cancelled inspection, and closed-preview late callback ownership. Synthetic fixture files are under a unique temporary directory and removed; no real model loaded. Existing C3 capture/history/config transaction tests remain in the full suite.

No `swift test`, unchanged-source repeat suite, or GUI test was run. Final build emits the inherited `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning; no new compile warning observed. Earlier C2 forced-cast warning and broader inherited warnings remain documented for final triage, not claimed fixed.

## Files

Created:
- `Sources/flowtype/Settings/ImportedASRModelPresentation.swift` (49 lines).
- `Sources/flowtype/Settings/ImportedASRModelActions.swift` (focused preview/actions, approximately 120 lines).
- `Sources/flowtype/Settings/ImportedASRModelList.swift` (126 lines, list and small sheet wrapper).
- `Sources/flowtype/Testing/ImportedModelUISelfTests.swift` (focused pure/action regression fixtures).
- `docs/evidence/2026-11-01-m2-rulings.md`.

Modified: `Settings/{LocalModelPicker,ASRModelStatusCard,QwenModelStatusCard,OnboardingView,SettingsPage+ASR}.swift`, `Testing/SelfTest.swift`; remaining-work audit; M2/live-validation evidence; all three 2026-11-01 M2 plan documents and spec documents. Existing large onboarding/self-test files receive small additions; no unexpected large-file growth or unrelated restructuring. Existing coordinator/runtime files are untouched.

## Documentation, decisions and sources

- Refreshed exhaustive A → B → C Ruling archive from each current `progress.md`, preserving every Ruling line verbatim and in order, including C3 conservative reservation policy. Reasons/costs remain; the historical extra-baseline entry lacked an explicit cost, so a clearly labeled archival note states its additional sequential-check time without rewriting its original text. Refreshed ignored `rulings-closeout-draft.md` too; scratch retained.
- Spec intros/audit now distinguish **approved/implemented** from **actual acceptance Pending**. Historical baselines/checkpoints are labeled. Plan completed source steps are checked from reports; B3 mixed GUI step and C4 mixed actual acceptance/final controller review steps remain open, with partial completion explained. No final gate is claimed passed before controller review.
- Evidence reconciles A eb840f8 1619/0, B 6fc1973 2034/0, C1 a36df21 2113/0, C2 9f0c92e 2179/0 and C3 63db2e9 2263/0. Earlier A3/B3 results remain historical, not presented as final counts.
- Actual C1 Qwen 1.7B 4-bit static probe and C2 public tiny tokenizer-only PASS are explicitly narrow. Latest controller static recheck at **2026-11-01T19:49:34Z**, exact C3 four inspector sources with recorded hashes, PASS: size **2225411512**, fingerprint **135f5b023e282e0c860d7b10a893487c5274dd012af5a203293d353eed3b1f22**, packed-U32 reservation **860225536 bytes**. Read artifacts `actual-17-static-c3-probe.log` / `actual-17-static-c3-source-hashes.txt`, build log separately retained. No GPU/runtime/inference/peak-memory claim.

## Self-review and honest remaining acceptance

Reviewed owned operations, latest UUID lookup, new/duplicate/relocated previews, conflict after preview, removed-row resurrection, no pre-success persistence, off-main bounded inspection, real active engine, preset selection, help/source coverage and diff scope. Fixed relocation conflict checks and post-await preview ownership before commit. `git diff --check` is clean (cached check below).

**Actual acceptance remains Pending.** Controller's fresh CUA inventory has no matching native FlowType/TextEdit/Finder/System Settings/Activity Monitor windows; browser host also unavailable. Earlier `getApp` returned `cgWindowNotFound`. Old PID 10836 maps to M1 source 2588d56. B-only 6fc1973 bundle was built but not launched, not current C4 evidence. Worker performed no GUI, restart or release build; controller will serialize final build/CUA after source stability. This is a desktop/tool limitation, not approval rejection.

Each Qwen scale/quantization and Whisper variant/hardware still needs real offline load, synthetic short phrase actual landing, long-window head/tail, cancellation, preset switch and failed-directory recovery. Missing full Whisper models or services/devices are Pending, never Pass. V1–V5 stay mandatory mainline with explicit credentials/network/device and Owner physical actions. M3–M5 unchanged.

Final reviewer still owns four inherited/deferred minor triages named in controller handoff: A native redirect callback fixture, C1 safetensors `__metadata__` value typing, C2 forced dictionary cast warning, B credential-only bounded health recovery. No unrelated fixes undertaken. No other blocking concern identified in this self-review.

## Final sequential verification / commit

- `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-build-final.log 2>&1`: exit **0**, `Build complete! (23.57s)`.
- Then `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-4-self-test-final.log 2>&1`: exit **0**, **2306 passed, 0 failed**, product build 4.56s.
- No source edits after this suite. Documentation/report completion does not alter tested source. No redundant unchanged-source rerun.
- `git diff --cached --check`: clean; verified **18 exact Ruling entries** against current A/B/C ledgers.
- Commit **73d5e74 — feat: manage imported ASR models and document M2 validation**; 20 scoped files, 714 insertions / 210 deletions. Report remains in ignored handoff directory as required. Final status **DONE**; fresh controller review/actual acceptance Pending.
