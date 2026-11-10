# Task B5 — native candidate validation and lifecycle

Base: `c326218`. Status: DONE_WITH_CONCERNS (approved downstream assembly/preset-download/full-fixture handoffs below). Commit: `ba47bb4` — `feat: validate native ASR candidates before activation` (15 explicit files). Task source: `task-B5-brief.md`; implementation contract and constraints read first. No subagents, dependency changes, downloads, real model inference, microphone, user config/credentials, push, release or full code gate.

## Implemented interfaces and ownership

- Added `@MainActor NativeASRActivationCoordinator(state:)`, exposing exact `activate(modelID: UUID, sample: ASRValidationSample) async throws -> LocalASRLease` and `unloadCurrentAfterDrain() async throws`. It composes QwenModelState and stores no active lease, operation, candidate task or second state machine. Every modelID is the imported model UUID, never installation/job UUID.
- QwenModelState remains sole activeLease owner. Existing operation reservation/task, global HF/source gate, inspection, preflight/load, trial, posttrial checks, transactional configuration write and runtime commit form one lifecycle. Busy activation throws; uncancellable candidate work and native compute drain retain ownership before another candidate can allocate.
- New private `execute` returns an operation-local Result to activate/import/useImported; public void `perform` remains source compatible. This prevents a later operation from overwriting an earlier awaiting caller's completion. Only the result is retained by its caller; it is not another active owner.
- `ModelProvisionRequest` adds optional `validationSample` and `restoringValidatedRuntime` defaulting nil/false. Normal legacy folder import, useImported, preset/manual and automatic selection all require a nonempty offline trial before selection changes. A throwing injected `sampleProvider` supplies legacy-entry audio; absence is explicitly validationRequired, never a production bypass.
- `LocalASRLease` adds `engineVersion` and `@Sendable () async -> Void` drain. Its immutable identity/provider remains retained by ASRRouteSnapshot/bindings across replacement or failure. Equality remains lease UUID. Existing minimumResidentBytes is retained for dual-model admission.
- `LocalASRRuntimeFactory.engineVersion(for:)` is the compatibility stamp. Exact current values: `speech-swift/0.0.15;swift-transformers/1.1.9;FlowType-Qwen/1` and `WhisperKit/0.18.0;swift-transformers/1.1.9;FlowType-Whisper/1`. Bump the FlowType adapter component when loader/decoder compatibility changes. The existing factory's immediate preallocation strict reinspection stays intact.
- Trial uses only supplied canonical 16kHz mono Float32 PCM, language/context nil and timeout 20. An injected `now` and separate cancellation-aware `validationSleep` implement a 20-second deadline; tests advance a fake clock without waiting 20 real seconds. The watchdog cancels native work at the boundary, while ownership remains held through real native drain. Empty/whitespace text, runtime error, timeout, cancellation, changed fingerprint/engine/tokenizer/compatibility model/version, changed operation or relevant selection/library fail before commit. No saved transcript or credential text.
- Immutable selection/library snapshots are captured at operation reservation, before waiting for the shared gate. Selection is checked on acquiring the gate; selection plus relevant imported/installed rows are checked inside the actual loader task immediately before allocation and again before commit. Posttrial inspection executes away from MainActor. Unrelated latest edits survive because commit reads current configuration synchronously.
- `ASRNativeValidationRecord` existing B4 schema is produced only after successful trial and recheck, with fileFingerprint, combined dependency/adapter engineVersion, canonical PCM sample SHA, timestamp, bounded observed trial latency. Existing installed row receives validation; a legacy/adopted row gets an external record with a distinct installation UUID. Managed ownership is never inferred from a path.
- Added throwing synchronous `ConfigurationStore.commitNativeASRActivation(_:)`; it persists the combined configuration before publishing current. QwenModelState shared uses it; commit failures retain previous owner and selection. Existing void save remains for unrelated removal/settings behavior. Validated native selection uses the existing central Configuration APIs, preserving migration markers for automatic legacy resolution and explicit-selection clearing behavior.
- Startup is offline restore only: existing validation plus fresh fingerprint/version are required before allocation. It never requests a sample, trials, reads mic or downloads. Resolved authoritative `native:preset:` and `native:import:` references precede legacy fields. An actual automatic fallback to 0.6B restores 0.6B even if 1.7B is also installed/preferred; unknown/unavailable explicit preset fails without guessing. Nil/unresolved selection retains legacy resolution, but missing historical validation remains validationRequired. Restore preserves native:preset lease identity and original automatic/manual intent.
- Explicit unload first cancels/drains this owner's pending operation, then reserves the same source gate. A final synchronous injected `canUnload` check and owner clear occur without actor suspension between them. Denied unload retains old lease. Approved unload truthfully sets activeLease nil/status notLoaded; subsequent candidate failure stays unready. Existing captured immutable lease remains usable. `canUnload` defaults false until B6/C4 registry assembly proves no recording/capture.

## Necessary native drain integration (controller-approved)

ASRProvider caller cancellation can precede native compute completion. Waiting only on transcribe Task.value was insufficient. Narrow additions:

- QwenASRProvider.drainInference awaits a continuation queued behind work on its existing serial inferenceQueue; it never blocks MainActor. Model loading remains on its existing path; the barrier covers native inference, not an invented second queue.
- WhisperASRProvider.drainInference awaits the existing WhisperInferenceQueue tail task. Recording cancellation behavior is unchanged; it still releases the caller continuation promptly, while the native queue retains its existing permit.
- Both compiled engine adapters and the legacy production Qwen loader stamp the lease drain closure. Validation always awaits it after trial outcome/cancellation/timeout before checking ownership and releasing the lifecycle. Fixture leases default to a no-op unless their stub has a real outliving worker.
- B6 usage tokens must live through the native drain closure, not merely caller continuation completion. Captured recording leases continue to retain provider/prepared resources; no duplicate usage registry was added here.

## TDD evidence

Every command below ran sequentially with no tracked edits during running builds/tests. Logs are in this ignored task workspace. Relevant exact outputs follow.

### API RED

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-red-build.log 2>&1
```

Exit 1. Tests were written first against required activation/lease/persistence seams; expected errors included `cannot find 'NativeASRActivationCoordinator' in scope`, `extra argument 'engineVersion' in call`, and extra missing QwenModelState initializer arguments.

First implementation build and new focused test run:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-api-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-initial-focused.log 2>&1
```

Both exit 0: `Build complete! (52.92s)`; `=== HF install self-test: 487 passed, 0 failed ===`.

Initial scoped regression RED exposed preexisting load-only fixtures, not production permission to bypass validation:

```sh
.build/debug/FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-initial-m2.log 2>&1
.build/debug/FlowType --self-test --m3-asr-regression-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-initial-m3.log 2>&1
```

Both exit 1: `=== M2 fix self-test: 272 passed, 4 failed ===`; `=== M3 ASR regression self-test: 249 passed, 45 failed ===`. Examples: actual fallback lease nil instead of 0.6B; old folder recovery reported validationRequired. Migrated only relevant fixtures to explicit synthetic sample, successful offline stub, synthetic inspector and persistence seams; startup fixtures seed matching synthetic historical evidence. Assertions were preserved.

An intermediate `B5-regression-build.log` exit 1 found fixture-only mistakes: broad replacement passed a stub to legacy `loadModel(provider: QwenASRProvider?)`, and clock continuation needed explicit Void generic. Corrected calls and continuation type. No production bypass added.

### Real native drain RED/GREEN

The real Whisper backend fixture ignores cancellation until its continuation is released. Its caller uses the actual WhisperASRProvider and existing inference queue. Before implementing the queue-tail drain await:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-drain-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-drain-red-focused.log 2>&1
```

Build exit 0 `Build complete! (32.00s)`; focused exit 1:

```text
  ✗ FAIL: B5 native Whisper compute outlives cancelled caller but retains lifecycle
  ✗ FAIL: B5 real Whisper queue drain prevents second allocation — got 2, want 1
=== HF install self-test: 531 passed, 2 failed ===
```

After the drain hook was implemented:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-green-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-green-focused.log 2>&1
.build/debug/FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-green-m2.log 2>&1
.build/debug/FlowType --self-test --m3-asr-regression-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-green-m3.log 2>&1
```

All exit 0: `Build complete! (32.68s)`; HF `533 passed, 0 failed`; M2 `276 passed, 0 failed`; M3 ASR `292 passed, 0 failed`.

### Reservation generation / operation-local completion RED

Self-review identified stale selection captured only after waiting for the global gate, and mutable shared error overwritten by a later operation before an earlier caller resumed. Deterministic tests use two owners competing for the source gate and a Combine reservation-release observer that starts a later blocked load before the first caller resumes.

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-ownership-red2-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-ownership-red-focused.log 2>&1
```

Build exit 0 `Build complete! (29.69s)`; focused exit 1:

```text
  ✗ FAIL: B5 selection changed while queued rejects old activation
  ✗ FAIL: B5 reservation captures selection before waiting for source gate [configuration differed]
  ✗ FAIL: B5 queued stale activation never becomes active [candidate published]
  ✗ FAIL: B5 later operation cannot overwrite previous caller's completion — got nil, want Optional(FlowType.NativeASRActivationError.emptyResult)
=== HF install self-test: 535 passed, 4 failed ===
```

The omitted two bracketed value dumps are full synthetic Configuration/lease descriptions in the log; they contain no user data. Intermediate `B5-ownership-red-build.log` exit 1 was Swift's actor-isolated default-argument inference in a test lazy initializer; changed only the test LoadGate from actor to lock-backed Sendable continuation gate.

After fixes: `B5-final-build.log` exit 0 `Build complete! (40.70s)`; `B5-final-focused.log` exit 0 HF `539 passed, 0 failed`; `B5-final-m2.log` exit 0 M2 `276 passed, 0 failed`.

### Authoritative preset startup RED

The isolated fixture creates two tiny metadata directories and sparse synthetic weight-size placeholders under RuntimePaths.temporaryDirectory; it uses the real ModelLocator with injected paths/empty cache list, while a deterministic legacy preference requests 1.7B only when no selection is provided. Only actual selected 0.6B carries synthetic validation.

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-preset-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-preset-red-focused.log 2>&1
```

Build exit 0 `Build complete! (32.54s)`; focused exit 1:

```text
  ✗ FAIL: B5 startup restores actual validated automatic fallback with both presets installed — got [], want ["qwen3-0.6b-4bit"]
  ✗ FAIL: B5 startup keeps native:preset identity — got nil, want Optional("qwen3-0.6b-4bit")
  ✗ FAIL: B5 unavailable authoritative preset reports recovery — got Optional(FlowType.ModelProvisionError.loadFailed(summary: nil)), want Optional(FlowType.ModelProvisionError.incompleteLocal(summary: nil))
  ✗ FAIL: B5 unavailable authoritative preset reports recovery — got Optional(FlowType.ModelProvisionError.loadFailed(summary: nil)), want Optional(FlowType.ModelProvisionError.incompleteLocal(summary: nil))
  ✗ FAIL: B5 unknown authoritative preset never falls through to automatic locator — got 1, want 0
=== HF install self-test: 545 passed, 5 failed ===
```

After fix: `B5-final2-build.log` exit 0 `Build complete! (30.33s)`; `B5-final2-focused.log` exit 0 HF `550 passed, 0 failed`; `B5-final2-m2.log` exit 0 M2 `276 passed, 0 failed`.

### Generation immediately before allocation RED

Consolidated await-boundary review found that initial static inspection can suspend after reservation checks. A blocking synchronous injected inspector permits selection/library removal on MainActor before returning; neither case should allocate a doomed candidate.

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-preallocation-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-preallocation-red-focused.log 2>&1
```

Build exit 0 `Build complete! (32.23s)`; focused exit 1:

```text
  ✗ FAIL: B5 selection changed during inspection rejects before allocation — got 1, want 0
  ✗ FAIL: B5 library changed during inspection rejects before allocation — got 1, want 0
=== HF install self-test: 552 passed, 2 failed ===
```

Fixed by passing the immutable operation generation into provision/attempt and rechecking selection/relevant model+record inside the actual loader Task immediately before calling load. This covers shared-gate wait, detached inspection, preflight and retry sleeps without another owner or snapshot mutable state.

## Final freeze GREEN

Final commands ran sequentially after consolidated self-review, with no tracked edits during or after the freeze:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-freeze-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-freeze-focused.log 2>&1
.build/debug/FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-freeze-m2.log 2>&1
.build/debug/FlowType --self-test --m3-asr-regression-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-freeze-m3.log 2>&1
git diff --check
```

All exit 0. Exact final output:

```text
Build complete! (37.98s)
=== HF install self-test: 554 passed, 0 failed ===
=== M2 fix self-test: 276 passed, 0 failed ===
=== M3 ASR regression self-test: 292 passed, 0 failed ===
```

Diff whitespace check emitted no output. Final freeze build/test logs have no warning/error/FAIL lines. Earlier broad recompilation emitted preexisting AudioRecorder/AudioDevice warnings, left untouched. No full code/artifact/release gates ran, as instructed. No production/test changes followed these gates; only this ignored report and commit metadata changed.

## Self-review

Read the complete production diff, scoped fixture changes and coordinator error messages. Consolidated all await boundaries: operation result wait, global source acquire, initial/posttrial inspection, preflight/backoff, candidate load, trial, watchdog and native drain, explicit unload. OperationID/cancellation checks suppress late ownership; generation checks precede allocation and commit; file/version checks follow trial; no suspend occurs between latest config merge, durable write and owner swap. Retained capture providers are never invalidated on replacement/removal. Corrected the demonstrated drain, reservation-generation, completion-result and authoritative-startup defects above with RED/GREEN evidence.

Existing QwenModelState was already a large lifecycle/UI coordinator; it is now roughly 760 lines. Kept the planned file responsibility and avoided unrelated refactoring or a second activation state machine. Independent review belongs to the controller. No full suite compatibility claim is made.

## Files changed

- Sources/flowtype/Core/ConfigurationStore.swift
- Sources/flowtype/Services/Speech/LocalModelManager/LocalASRRuntimeFactory.swift
- Sources/flowtype/Services/Speech/LocalModelManager/QwenMLXEngineAdapter.swift
- Sources/flowtype/Services/Speech/LocalModelManager/WhisperCoreMLEngineAdapter.swift
- Sources/flowtype/Services/Speech/ModelInstallation/NativeASRActivationCoordinator.swift
- Sources/flowtype/Services/Speech/ModelProvisioning/LocalASRLease.swift
- Sources/flowtype/Services/Speech/ModelProvisioning/ModelProvisionRequest.swift
- Sources/flowtype/Services/Speech/QwenASRProvider.swift
- Sources/flowtype/Services/Speech/QwenModelState.swift
- Sources/flowtype/Services/Speech/WhisperASRProvider.swift
- Sources/flowtype/Testing/HFInstallSelfTests.swift
- Sources/flowtype/Testing/NativeActivationSelfTests.swift
- Sources/flowtype/Testing/ImportedLifecycleSelfTests.swift
- Sources/flowtype/Testing/ModelProvisionSelfTests.swift
- Sources/flowtype/Testing/WholeM2FixSelfTests.swift

## Required B6 / C1 / C2 / C4 handoffs and limits

1. **B6 mandatory preset download/allocation split, explicitly approved scope boundary.** Imported candidates already undergo strict inspection and dual-memory admission before allocation. The old preset loader combines explicit download and runtime allocation, so B5 preserves that mechanism and trials before commit; it cannot claim a fresh static dual-budget check before that combined allocation. B6 must delegate preset download to B4, inspect the published candidate, perform old+new memory admission, then call B5/native allocation. Installation alone must remain unselected. Do not treat path shape as managed ownership.
2. **C2/C4 sample and assembly.** Supply licensed bundled samples through `sampleProvider` for legacy UI/retry/preset entrypoints, and pass `ASRValidationSample` directly for new activate. Shared production owner currently has no bundled provider because C2 is later; attempts fail explicitly validationRequired rather than bypassing trial. Startup needs no sample provider and never automatically plays/uploads/trials. C1 should expose NativeASRActivationError/validationFailure and explicit recovery; current generic provisioning status remains compatible but validationFailure carries exact reason.
3. **B6/C4 unload/capture.** Wire `canUnload` to real no-recording/no-capture resources; it deliberately defaults false. The check+clear is synchronous under the same source reservation. B6 usage tokens must cover captured lease, allocation/trial and native drain (Qwen barrier / Whisper tail); cancellation continuation completion alone is insufficient. Capture bindings keep immutable provider/lease today, without a duplicate provisional usage registry.
4. **B6 library cleanup/adoption.** Legacy validated directories get external installed records solely as validation association, preserving existing native:preset identity and automatic intent. B6 deletion/removal must handle those associations, detached B4 records and captured leases; QwenModelState legacy removeImportedModel currently retains its existing removal semantics, not a new deletion/reservation implementation. B6 may associate/adopt records without changing native:preset IDs.
5. **Full-run fixture migration remains before B6 full gate.** Only required HF/M2/M3 gates ran. Known older constructors requiring explicit sample/persistence/synthetic inspector and successful offline output for intended success paths:
   - ImportedModelUISelfTests.swift:27 (`run`, full runner).
   - NativeModelPresentationSelfTests.swift:85,120,176 (NativeClientSelfTests -> native client filter/full runner).
   - LocalSettingsOwnershipSelfTests.swift:18 helper (NativeClientSelfTests -> native client filter/full runner).
   - M2ReviewFixSelfTests.swift:125,151,262,289 (`--m2-review-inspection-only`, `--m2-review-packages-only`, full runner): old preset success/bootstrap fixtures and waiting-owner assertions must adopt validation seams; keep cancellation/inspection/compilation assertions.
   - SelfTest.swift:2022,2082 legacy `loadDownloadedPreset` fixture constructors (full runner). The convenience initializer no longer implies valid recognition; migrate fixture callers to explicit complete injections, never add a production validation bypass.
   - ModelProvisionSelfTests.swift:564 legacy compatibility fixture and `runCoordinator` startup cases (full runner). Shared fixture helper was migrated for scoped M3 presentation/routing, but runCoordinator old startup assumptions now require matching history, offline authoritative selection and explicit recovery expectations. Its direct failure-only initializer at :314 does not require a sample to test preflight/load errors. Existing tests must distinguish safe explicit download from startup no-download.
   - ImportedLifecycleSelfTests.swift:178 budget-rejection-only constructor intentionally remains without sample; it must reject before runtime construction, and scoped M3 proves that. This is not a bypass.
6. Runtime graph/model accuracy, real device memory, downloads, microphone, bundled licensed resource usability, app assembly and signed release remain untested/pending. Fixture evidence cannot mark them Pass. Package.resolved is unchanged.

## B5 fix round 1/5 — I1 final factory admission and I2 automatic selection

Review: `task-B5-review.md`. Base: `ba47bb4`. Fix commit: `df6adf3` — `fix: guard native allocation and automatic selection` (four explicit files). Both Important findings verified against production code before changing it; no review findings deferred. Existing approved B6/C2/C4 boundaries remain as listed above.

### I1 changes and exact interface compatibility

- The owner originally checked generation before calling its loader, but the real factory then awaited a second strict inspection. A changed selection/library or fresh memory rejection during that await could still allocate and trial a doomed candidate. The fix carries the owner callback all the way through the factory to the allocating registry boundary.
- `LocalASRRuntimeFactory.load` is now MainActor for its short orchestration, with added defaulted per-call `inspect: @Sendable (URL) throws -> ImportedASRModel` and `beforeAllocation: @MainActor (ImportedASRModel) throws -> Void`. The actual full inspection still runs through detached `LocalModelInspection`, away from MainActor; model fingerprint/engine/tokenizer/compatibility matching remains mandatory.
- `LocalASRRuntimeRegistry.load` is MainActor and accepts the defaulted beforeAllocation callback. It synchronously resolves the compiled adapter, checks cancellation, invokes the final owner callback, then dispatches its asynchronous allocating load. There is no await between the owner authority/hardware check and allocation dispatch. Native loading/compute implementation is unchanged and asynchronous.
- QwenModelState's production imported route supplies a callback checking operation/cancellation, immutable reservation selection, relevant imported/installed row generation, and freshly resampled hardware admission using the currently retained active lease's memory reservation. All those checks execute in the same owner actor segment as registry dispatch. Initial inspection/admission and final trial/commit checks remain in place.
- New per-instance `loadImported` initializer injection takes `(model, ownerAdmissionCallback) async throws -> LocalASRLease`. Its production default keeps the existing ValidationEffects.modelLoad guard and calls the real factory with the callback. Tests explicitly inject the real factory with only inspector and registry adapter replaced. No global ValidationEffects allow, default self-test native load, microphone or actual model execution was enabled. Existing broad custom `load` fixtures still replace model I/O; their owner initial/final checks remain unchanged. The legacy production load closure no longer contains an unchecked imported factory branch.
- Named-risk caller check: factory direct calls outside QwenModelState are the three existing B2 injected-adapter tests in HFInstallPlannerSelfTests; their already-awaited calls remain source compatible and ran in the HF suite. Registry allocating load is called by the factory only. Metadata engine/inspect registry methods stay synchronous and nonisolated; no metadata/planner behavior changed. Existing native adapters are unchanged, so no dependency/decoder-compatibility version bump is needed.

### I2 changes

- Both preset and offline successful commits now use central `Configuration.selectNativeASRBackend(lease:)` for an explicit successful action, including `.automatic`. That updates an existing native primary/fallback role to the actual candidate and clears the unresolved marker according to the central API, without pinning selectedLocalModelID for automatic intent.
- Direct use of migration-only `resolveLegacyNativeSelection` is restricted to restoringValidatedRuntime with a true pendingLegacyNativeResolution marker. Explicitly cleared native roles remain cleared because the central API refuses to invent a native role; unrelated latest config merge and commit atomicity are unchanged.
- Regressions start with resolved native 1.7B and assert actual loader-returned lease equals active lease, successful 0.6B matches the authoritative role, selectedLocalModelID remains nil, and fresh startup restores that same identity. Cases cover explicit automatic preset, offline automatic transaction, 1.7B failure -> 0.6B fallback, and explicitly cleared native role. The fallback still reports its flag and attempts primary then smaller model.

### RED evidence

Tests were added before interfaces/implementation:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-api-red-build.log 2>&1
```

Exit 1: expected `extra argument 'loadImported' in call`. Then added only injection plumbing while retaining the missing final callback invocation and existing migration-only automatic commit, so the behavioral tests exercised the original defects through real production factory/registry control flow:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-red-focused.log 2>&1
```

Build exit 0 `Build complete! (46.38s)`; focused exit 1 `=== HF install self-test: 605 passed, 19 failed ===`. Exact relevant output:

```text
  ✗ FAIL: B5 fix factory resamples admission after final awaited inspection — got 1, want 2
  ✗ FAIL: B5 fix factory selection rechecks authority at allocating adapter boundary — got 1, want 0
  ✗ FAIL: B5 fix rejected factory selection candidate never trials — got 1, want 0
  ✗ FAIL: B5 fix factory library rechecks authority at allocating adapter boundary — got 1, want 0
  ✗ FAIL: B5 fix rejected factory library candidate never trials — got 1, want 0
  ✗ FAIL: B5 fix factory record rechecks authority at allocating adapter boundary — got 1, want 0
  ✗ FAIL: B5 fix rejected factory record candidate never trials — got 1, want 0
  ✗ FAIL: B5 fix stale factory budget activation rejects
  ✗ FAIL: B5 fix factory budget rechecks authority at allocating adapter boundary — got 1, want 0
  ✗ FAIL: B5 fix rejected factory budget candidate never trials — got 1, want 0
  ✗ FAIL: B5 fix factory resamples admission after final awaited inspection — got 1, want 2
  ✗ FAIL: B5 fix automatic preset authoritative role agrees with actual lease — got Optional(FlowType.ASRBackendID(rawValue: "native:preset:qwen3-1.7b-4bit")), want Optional(FlowType.ASRBackendID(rawValue: "native:preset:qwen3-0.6b-4bit"))
  ✗ FAIL: B5 fix automatic preset restart agrees with selected active identity — got nil, want Optional("qwen3-0.6b-4bit")
  ✗ FAIL: B5 fix automatic offline authoritative role agrees with actual lease — got Optional(FlowType.ASRBackendID(rawValue: "native:preset:qwen3-1.7b-4bit")), want Optional(FlowType.ASRBackendID(rawValue: "native:preset:qwen3-0.6b-4bit"))
  ✗ FAIL: B5 fix automatic offline restart agrees with selected active identity — got nil, want Optional("qwen3-0.6b-4bit")
  ✗ FAIL: B5 fix automatic fallback authoritative role agrees with actual lease — got Optional(FlowType.ASRBackendID(rawValue: "native:preset:qwen3-1.7b-4bit")), want Optional(FlowType.ASRBackendID(rawValue: "native:preset:qwen3-0.6b-4bit"))
  ✗ FAIL: B5 fix automatic fallback restart agrees with selected active identity — got nil, want Optional("qwen3-0.6b-4bit")
```

The other two RED checks dumped synthetic Configuration/lease values showing the budget-changed candidate wrongly persisted and owned runtime; full exact dumps are in the log. No user data was read. The final GREEN count is one lower than RED's total because a wrongly successful rejected candidate executed the additional successful-result/active-result assertion; no assertions were removed.

The new factory regression uses QwenModelState's default imported dispatch, injected real factory, real registry, blocking second inspector and a compiled stub adapter allocation counter. It exercises unchanged success (one allocation and trial), changed selection, removed imported row, removed installed record, fresh budget rejection, and cancellation (zero adapter allocations/trials). The untouched case asserts two hardware samples, so merely rejecting every factory candidate cannot satisfy it. No expensive native provider is loaded.

### Consolidated self-review and freeze

Completed one consolidated review before final expensive gates. Checked all changed await boundaries: owner work starts, factory detached inspection, return to MainActor, registry cancellation/admission callback, allocating adapter dispatch, unchanged trial/native drain and latest-config transaction; callback checks have no suspend before dispatch. Checked both automatic commit branches, initial unresolved migration, resolved existing native roles, explicit cleared role and authoritative startup. Checked other factory/registry callers for actor-isolation compatibility; compiler and HF B2 tests cover them. Checked no effect gate was globally weakened and only four intended files changed. Existing unrelated config-preservation tests remain in HF/M3. No new scope, native runtime/graph tests, full suite, dependency changes or user-state access.

### Fix round 1 final GREEN

Ran sequentially, with no tracked edits while builds/tests ran and no source/test changes after this freeze:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-final-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-final-focused.log 2>&1
.build/debug/FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-final-m2.log 2>&1
.build/debug/FlowType --self-test --m3-asr-regression-only > .superpowers/sdd/2026-11-09-asr-model-center/B5-fix1-final-m3.log 2>&1
git diff --check
```

All exit 0. Exact output:

```text
Build complete! (32.59s)
=== HF install self-test: 623 passed, 0 failed ===
=== M2 fix self-test: 276 passed, 0 failed ===
=== M3 ASR regression self-test: 292 passed, 0 failed ===
```

Final build/focused/M2/M3 logs contain no warning/error/FAIL lines. Whitespace check and Package.resolved diff are empty. No full suite or actual model/runtime/microphone/user-state/service/network/dependency/release work ran. I1 and I2 are both addressed; awaiting controller's fresh scoped rereview of ba47bb4..fixHEAD.

Fix-round files: LocalASRRuntimeFactory.swift, LocalASRRuntimeRegistry.swift, QwenModelState.swift, NativeActivationSelfTests.swift. Original B6/C2/C4 limits and full-run fixture inventory still apply; no new concern or review finding deferred.
