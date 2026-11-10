# C1 — unified model-center projections and actions

Status: DONE. Commit: `0f73f363019749197fb70d8d9a797a1c44fcf76b` — `feat: project ASR model center state and actions`. Tree: `dda6bd02ae3d384a129b57786cea1dc5b42d192f`. Base: `dfd7991`. No nested agents, dependencies, real models, user configuration, real credentials/Keychain, microphone, clipboard, permissions, downloads, push, merge, install, release, or full code gate. Synthetic native providers, in-memory credential snapshots, injected recognition closures and an isolated existing B4 byte-transport fixture cover domain behavior. All builds/tests ran sequentially, with no tracked edits while any build/test ran.

## Delivered

- Added application-owned `ASRModelCenterViewModel`, value-only `ASRModelCenterPresentation`, `ASRModelCenterRow` and all required status cases. Rows use stable actual backend IDs. Native readiness reads Qwen's existing unique active owner; installation progress reads B4 snapshots. The model center owns no runtime, provider, downloader, installer task or recognition task.
- Native imported rows with B6's exact nonambiguous `legacyPresetID` association fold into their preset row. No association is inferred from engine or path. Newly acquired managed presets commit and expose their actual `native:import:<UUID>` identity, including when the requested row was a preset. Unknown peak memory and server-managed whisper.cpp model identity are explicit. Loopback service copy states that the service itself may use the internet.
- Service/cloud configuration checks remain installed/untested. Only an explicit successful recognition with unchanged full profile, revision, atomic credential generation and in-process coordinator verified state supplies current readiness. Evidence expires at 60 seconds; the label becomes previous validation. Restarted historical records never enter the live evidence map, and a new process's random generation does not erase their historical label.
- Added default-empty `Configuration.asrServiceValidationRecords` with backward-compatible missing-key decoding. Records contain only backend ID, revision, credential generation and coordinator-emitted date. No text, endpoint or key is persisted. A5 now accepts a defaulted injected clock and its emitted timestamp is retained exactly, never refreshed at presentation time.
- Extended shared `ASRSettingsAction` with explicit primary/fallback selection, cloud fallback consent and deselection. Shared policy, duplicate role, single-native-owner and consent guards run before native allocation and again in the durable transaction. Local-only/cloud-only conflicts never silently change policy. Explicit native deselection synchronizes relevant legacy native intent and clears the migration marker while retaining library rows, files and runtime until B6's guarded removal. Imported UUID deselection compares UUID values, including lowercase spellings.
- New primary selection tests service/cloud first and rechecks captured inputs and original selection/policy before durable selection. Native primary and fallback intents commit actual lease identity, native validation, compatibility fields and selection in B5's one existing throwing persistence transaction before active-owner swap. There is no second UI native save. Failure preserves prior roles and runtime.
- Native Test runs under the same Qwen lifecycle gate, memory admission, strict inspection, 20-second trial, cancellation checks and real native drain, but commits only minimal historical validation. It preserves all roles, legacy intent and old active lease. The operation-local result returns ephemeral text/latency and releases the candidate after drain. Test of an uninstalled preset does not acquire it.
- Native fallback explicitly loads/trials and commits a cold native candidate; it does not require a redundant standalone Test. Service/cloud fallback assignment requires matching live prior Test evidence and never uploads audio implicitly. Two distinct native roles are rejected instead of silently clearing a role.
- Selected removal is refused until explicit deselection. Native removal awaits B5 unload permission/capture drain and then B6's guarded facade; direct model-library/filesystem deletion is absent from the VM. Errors remain model configuration/recovery errors. No arbitrary remaining row becomes primary.
- Registered nonempty `--asr-model-center-only` in central SelfTest and RuntimeEnvironment process isolation; the full self-test runner also registers C1. No C3 rendering changes are included.

## Controller-approved interface amendments

1. Explicit native primary/fallback intent was added to B5 because the old default only updates already-selected native roles; a later UI save would split persistence and runtime ownership.
2. A trial-only operation-local result was added because calling old activate for Test would replace the old owner/role and could not supply a quality preview.
3. `selectFallback` is now async to permit cold native fallback admission/trial/atomic commit. Service/cloud assignment remains recognition-free and consumes previous explicit Test evidence.
4. Routing policy joins B5 selection generation. Mutable next-download default is deliberately excluded: the request captures the actual source, and the authoritative B6 regression requires a later unrelated default edit to survive.
5. `isActive` is the sole cloud-profile field normalized out of validation identity in both A5 and C1. Every other field, including revision/name/endpoint/model/protocol/provider/credential reference, remains compared. Shared primary actions synchronize this legacy display flag; flag-only changes do not erase valid recognition proof.
6. A5's optional injected `now` and the guarded history-only callback below preserve coordinator-emitted dates. These changes add no second service owner.

## Exact C2 / C3 / C4 interfaces

`@MainActor ASRModelCenterViewModel.init(configuration: @escaping () -> Configuration, persist: @escaping (Configuration) throws -> Void, native: QwenModelState, validation: ASRServiceValidationCoordinator, credential: @escaping (ASRBackendID) throws -> ASRCredentialSnapshot, sample: @escaping () throws -> ASRValidationSample, installationSnapshots: @escaping () async -> [ModelInstallSnapshot], now: @escaping () -> Date)`.

The injected `persist` must durably save before publishing or throwing. The injected credential closure returns one atomic value+generation snapshot for the exact backend; production must not separately read value/generation or use legacy plaintext backups. The injected sample is canonical 16 kHz mono PCM from C2's later licensed store. There are no production-global defaults in this initializer.

Published projections: `rows`, mutable UI `selectedID`, `installations`, `notice`, `lastTrialResult: ASRModelTrialResult?`. UI selection does not mean primary role. `ASRModelTrialResult` is Sendable/Equatable with `backendID`, `text`, `latencyMs`; never persist it. A successful native preset activation can produce an imported actual backend ID; C2/C3 must use the returned/projected actual identity rather than assuming the requested preset row remains active.

Actions:

```swift
func selectPrimary(_ id: ASRBackendID) async
func selectFallback(_ id: ASRBackendID?) async // approved amendment: await this
func test(_ id: ASRBackendID) async
func remove(_ id: ASRBackendID, deleteManagedFiles: Bool) async
func deselect(_ id: ASRBackendID)
func setAllowsCloudFallback(_ allowed: Bool)
func changePolicy(_ policy: ASRRoutingPolicy)
func refresh()
func refreshInstallations() async
var currentValidatedServices: [ASRServiceValidationRecord] { get }
@discardableResult func recordValidation(_ record: ASRServiceValidationRecord) -> Bool
```

`recordValidation` is for C4's A5 `onVerified` callback. It checks current backend/revision/atomic generation and the coordinator's exact verified date; stale callbacks return false. It persists history only, never marks ready. A5 may still own/drain its transport slot when this callback runs, so callback code must not start another recognition. Duplicate records do not save again. The model-center's own awaited test separately rechecks its full captured profile and current coordinator state, deduplicates the same history save, then publishes current evidence. If history persistence fails, it does not select the backend or publish live evidence. Route actual model-center UI tests through this same VM/coordinator; do not create parallel readiness truth.

C4 must retain one VM at application scope, inject the existing unique Qwen owner and A/B coordinators, call `refresh` after configuration/credential changes and on the normal readiness clock (so the 60-second label expires), and call `refreshInstallations` as installer snapshots change. The VM's small Combine observation dispatches refresh after Qwen/A5 Published updates; these dispatches own no network/runtime work. C4 feeds only `currentValidatedServices` to A6 readiness and refreshes readiness after domain changes; never feed `Configuration.asrServiceValidationRecords` to readiness after restart. C4 still must wire Qwen's real live-recording unload permission; its default remains false.

Native public interfaces (on both QwenModelState and NativeASRActivationCoordinator):

```swift
enum NativeASRSelectionIntent { case existingRole, primary, fallback, trialOnly }
func activate(modelID: UUID, sample: ASRValidationSample,
              selectionIntent: NativeASRSelectionIntent = .existingRole) async throws -> LocalASRLease
func activate(preset: ModelPreset, sample: ASRValidationSample,
              selectionIntent: NativeASRSelectionIntent = .existingRole) async throws -> LocalASRLease
func test(modelID: UUID, sample: ASRValidationSample) async throws -> ASRModelTrialResult
func test(preset: ModelPreset, sample: ASRValidationSample) async throws -> ASRModelTrialResult
```

`existingRole` preserves all old two-argument activate callers. `primary`/`fallback` are explicit user selection intents. `trialOnly` is carried by internal `ModelProvisionRequest` for Test; public activate rejects that intent because Test has a different return type. `ModelProvisionRequest` adds defaulted `selectionIntent`, and retry preserves the original intent/sample. New explicit selection requests require an already identified imported/preset backend; uninspected directories must be inspected to a model ID before an explicit selection request. Test of presets is offline and resolves only a known B4 recipe association or exact existing preset repository identity.

A5 initializer now accepts `now: @escaping @MainActor () -> Date = { Date() }` before `onVerified`; all existing callers remain source-compatible. C4 should inject the same application clock.

C2 still owns licensed bundled sample/resource acquisition UI and explicit destination/upload/cost notice. Shared production Qwen sampleProvider still fails closed until C2/C4 wire it; this task does not bypass it. C3 owns views, complete error/detail display, keyboard/VoiceOver/real window checks. C4 owns application composition, settings entries and readiness scheduling. Manual real models/services/vendors/sample quality, microphone, signing, artifact and release checks remain Pending.

## TDD and verification evidence

Each command below redirected both streams to the named ignored log. Expected compiler issues during fixture authoring are distinguished from business RED. No full gate was rerun; the prior 27,755/0 evidence remains tied only to `44f8172`.

Initial business RED, after adding the registered nonempty suite and buildable no-op projection/action scaffold:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-red-focused.log 2>&1
```

Build exit 0, `Build complete! (37.74s)`. Focused exit 1, `11 passed, 12 failed`: missing honest installed/status/history projections, failed-selection notice, successful exact-ID selection, explicit consent assignment and explicit removal/deselection. This was a business RED, not an unregistered-filter failure.

Native selection RED after the source-compatible intent scaffold but before B5 transactional intent implementation:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-native-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-native-red-focused.log 2>&1
```

Build exit 0, `44.94s`; focused exit 1, `28 passed, 4 failed`: first-native and service→native stayed on old selection, cloud-only native activation admitted, duplicate native fallback promotion admitted. GREEN `C1-green1-build.log` exit 0 `35.22s`; `C1-green1-focused.log` exit 0 `32 passed, 0 failed`.

Selection-free trial/fallback/history RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-trial-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-trial-red-focused.log 2>&1
```

Build exit 0 `27.19s`; focused exit 1 `53 passed, 5 failed`: native Test replaced absent/old runtime, output was missing, untested fallback admitted, random process generation erased historical label. GREEN `C1-green2-build.log` exit 0 `35.41s`; `C1-green2-focused.log` exit 0 `58 passed, 0 failed`. Additional coverage `C1-extended-build.log` exit 0 `30.74s`, `C1-extended-focused.log` exit 0 `76 passed, 0 failed`.

Removal/callback/legacy-flag RED:

`C1-final1-build.log` exit 0 `32.34s`; `C1-final1-focused.log` exit 1 `88 passed, 1 failed`: B6 removal correctly refused leftover legacy native intent after explicit role deselection and drain. Callback fixture's first compile (`C1-callback-red-build.log`) exit 1 exposed a missing `try` on synthetic sample construction; it was corrected before business RED. `C1-callback-red2-build.log` exit 0 `30.80s`; `C1-callback-red-focused.log` exit 1 `92 passed, 4 failed`: the same removal guard, missing history callback persistence/previous-validation projection, cloud primary legacy active flag false. GREEN `C1-green3-build.log` exit 0 `43.60s`; focused `98/0`, A `1084/0`, B `866/0`.

Consolidated self-review regression RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-review-red-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-review-red-focused.log 2>&1
```

Build exit 0 `30.32s`; focused exit 1 `99 passed, 4 failed`: lowercase imported UUID role+legacy intent survived canonical explicit deselection, and a direct explicit B5 request allocated once before a role conflict. Fixed by UUID-value explicit deselection and shared request-level preallocation guard. No broad global backend ID normalization or B6 removal weakening.

Final freeze exact commands/results appended below.

## Consolidated self-review

Reviewed the full production diff, every new projection/action and fixture, central registration, Configuration coding keys/defaults, all B5 intent and trial await/commit boundaries, A5 callback/clock and normalization, and B6 removal sequencing. Existing default activation behavior stays source-compatible; only explicit model-center primary/fallback intents can create a role. The candidate outcome is operation-local. Trial-only returns no retained candidate lease, preserves old active owner, and persists only after drain and fresh generation checks. Native activation remains one throwing persistence followed synchronously by owner swap. Service selection rechecks full inputs after recognition and again before selection; history does not grant readiness. Native usage errors stay model configuration errors, not Keychain recovery.

The review found and regression-tested explicit UUID deselection and request-level early guards, as above. No unresolved automated correctness concern remains. QwenModelState was already a large lifecycle coordinator; its new branches remain inside that one existing owner instead of splitting state. No unrelated refactor or external effect was introduced. Fresh independent review belongs to the controller.

## Final freeze GREEN

No source edits followed this freeze. Exact sequential commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-freeze-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-freeze-focused.log 2>&1
.build/debug/FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-freeze-backends.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-freeze-hf.log 2>&1
git diff --check
```

All five commands exit 0. Exact final summaries:

```text
Build complete! (29.12s)
=== ASR model center self-test: 103 passed, 0 failed ===
=== ASR backend self-test: 1084 passed, 0 failed ===
=== HF install self-test: 866 passed, 0 failed ===
```

Whitespace check emitted no output. These final four build/test logs contain no warning/error/FAIL lines. Earlier broad rebuilds emitted existing `DownloadSource.regionCode`, AudioRecorder/AudioDevice and B6 fixture captured-variable warnings from unchanged code; they were not hidden or fixed outside scope. Full code/M2/artifact/release gates were not rerun, per controller instruction. No real-model/manual verification is claimed.

## Files changed

- `Sources/flowtype/App/RuntimeEnvironment.swift`
- `Sources/flowtype/Core/Configuration.swift`
- `Sources/flowtype/Services/Speech/Backends/ASRServiceValidationCoordinator.swift`
- `Sources/flowtype/Services/Speech/Backends/ASRSettingsAction.swift`
- `Sources/flowtype/Services/Speech/ModelInstallation/NativeASRActivationCoordinator.swift`
- `Sources/flowtype/Services/Speech/ModelProvisioning/ModelProvisionRequest.swift`
- `Sources/flowtype/Services/Speech/QwenModelState.swift`
- `Sources/flowtype/Settings/ModelCenter/ASRModelCenterPresentation.swift` (new)
- `Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift` (new)
- `Sources/flowtype/Testing/ASRModelCenterSelfTests.swift` (new)
- `Sources/flowtype/Testing/SelfTest.swift`

## Commit and closeout

Explicit-file commit `0f73f36` contains 11 files, 994 insertions and 23 deletions. Staged whitespace check also exited 0. Final `git status --short` emitted no output. Only this ignored report changed after commit; no source edits followed the final freeze. No unresolved automated concerns; pending C2/C3/C4 composition/resources/UI and real/manual gates are the intentional downstream boundaries above.

## C1 review fix round 1 — Important I1

Review source: `task-C1-review.md`. Fix base: `0f73f36`. Controller ruling: use explicit one-at-a-time model-center user-action admission, not latest-intent supersession or another B5 lifecycle/cancellation callback. No additional agents or external effects. Only the VM and its domain self-tests changed.

### Fix

Added one MainActor admission slot at the VM boundary. `selectPrimary`, async `selectFallback`, `test`, `remove`, and synchronous `changePolicy`/`setAllowsCloudFallback`/`deselect` all acquire it **before** clearing preview/notice, capturing configuration, requesting a sample/credential, starting A5/B5 work, or persisting/removing anything. An overlap returns immediately, emits separate busy feedback and is not queued. The accepted action alone may update its preview/notice and releases the slot with `defer` only after all its domain awaits and final output/projection writes finish. Removal retains admission through its awaited installation refresh. Cancellation retains admission until the existing A/B owner actually returns; no prompt-cancellation/native-drain behavior or domain owner was changed.

The gate stores no Task/provider/lease/network operation. Qwen remains the native lifecycle/transaction owner and A5 remains per-profile recognition owner. External legacy A5 operations remain independent; only model-center user actions share the slot.

The minimal historical `recordValidation` callback remains ungated so an A5 success callback can continue while its user action holds admission. It no longer writes the user action's `notice` on an unrelated callback failure; it returns false. The admitted validation path calls the same private throwing persistence helper and reports its own persistence error through its action notice. History deduplication and readiness rules are unchanged.

### Exact C3 / C4 admission contract

```swift
private(set) var isBusy: Bool
@Published private(set) var busyNotice: String?
```

`isBusy` is read-only outside the VM and observable through `ObservableObject.objectWillChange`. It is deliberately stored before admission publication so synchronous/reentrant UI actions also see the occupied slot; release publishes after the slot is cleared, with no older output writes afterward. There is no `$isBusy` projected publisher. C3 should use the observed VM's `isBusy` to disable conflicting primary/fallback/Test/remove/policy/consent/deselect controls while still allowing browsing/UI `selectedID` changes.

A rejected overlap sets `busyNotice` to `模型中心正在执行另一项操作，请等待完成后重试。` and preserves the accepted action's `notice` and any valid existing `lastTrialResult`. `busyNotice` is separate from action failure/recovery text; the next accepted action clears it. It may remain as feedback for the last rejected click after the original operation finishes, while `isBusy == false` allows explicit retry. Rejected clicks never auto-run later. Accepted action methods retain their existing return signatures.

`refresh`, `refreshInstallations`, UI-only row selection, and the minimal historical callback do not acquire user admission. They project/merge domain state and do not launch another user selection/test/removal operation. All previous C2 sample, C4 application lifetime/readiness clock and live-recording unload wiring handoffs remain pending and unchanged.

### RED evidence

New tests exercise actual injected A5/Qwen paths with controlled continuations, not a second fake VM state machine. The two distinct service-primary attempts are explicitly released in both attempted completion orders; RED did not hang. Tests also cover service→native rejection before allocation/commit, native→service rejection before recognition/commit, valid preview preservation on rejected Test, all conflicting sync mutations and async fallback/removal, removal-held admission, and explicit retries after completion, failure and cancelled/draining work.

The first fixture build (`C1-fix1-red-build.log`) exited 1 due to Swift lazy/default-argument actor-isolation inference at the injected coordinator construction. Moved fixture-only coordinator construction to an explicit helper and supplied the loopback resolver. This was not counted as business RED.

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-fix1-red2-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-fix1-red-focused.log 2>&1
```

Build exit 0, `Build complete! (30.87s)`. Focused exit 1:

```text
C1 I1 distinct service overlap is rejected before transport ... got [A, B], want [A]
C1 I1 pending service primary blocks native allocation — got 1, want 0
C1 I1 pending native action blocks service recognition and primary work — got 3, want 1
C1 I1 rejected Test preserves the valid existing preview — got service preview, want cloud preview
C1 I1 conflicting mutations are rejected before persistence — got 3, want 0
C1 I1 cancelled but draining operation retains user admission — got 2, want 1
=== ASR model center self-test: 117 passed, 22 failed ===
```

The six value descriptions above summarize exact synthetic UUID/value dumps in the full log; all exact assertion strings and complete output are preserved there. Other RED failures include missing busy state/feedback, the newer overlapping service intent committing instead of the admitted one, native versus service commits defeating each other, busy removal deleting a native record, and pending removal admitting another Test.

### Final GREEN and self-review

All commands ran sequentially, with no tracked edits during or after this GREEN. Exact commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/C1-fix1-green-build.log 2>&1
.build/debug/FlowType --self-test --asr-model-center-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-fix1-green-focused.log 2>&1
.build/debug/FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-fix1-green-backends.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/C1-fix1-green-hf.log 2>&1
git diff --check
```

All exit 0:

```text
Build complete! (46.91s)
=== ASR model center self-test: 139 passed, 0 failed ===
=== ASR backend self-test: 1084 passed, 0 failed ===
=== HF install self-test: 866 passed, 0 failed ===
```

Whitespace check emitted no output. Focused test logs have no FAIL/error/warning output. The broad rebuild emitted existing warnings in unchanged AudioDevice/AudioRecorder/DownloadSource and HFInstallTransactionSelfTests; no new VM/admission-test warnings were introduced. No full gate, M2, real model/service, dependency, user-state or manual verification ran.

Consolidated self-review read both complete file diffs and every admission entry/exit. Every conflicting action checks admission before existing action side effects; every accepted path uses a defer, including early validation failure and awaited removal refresh. Rejected actions cannot clear preview or change action notice. The independent minimal callback cannot overwrite an action notice. No older admitted action publishes output after releasing its slot. No B5/A5 lifecycle, persistence ordering, native no-resurrection guard or capture/drain permission was weakened. Independent scoped rereview belongs to the controller.

Files: `Settings/ModelCenter/ASRModelCenterViewModel.swift`; `Testing/ASRModelCenterSelfTests.swift`. Commit identity appended below.

Fix round 1 closeout: **DONE**. Explicit two-file commit `d156b82167a502493f03c1353e64c05beff44d13` — `fix: serialize ASR model center user actions`; tree `589aca9d395b9e8243ba87a76cabc4d6aaa1076f`. Two files, 188 insertions/16 deletions. Staged whitespace check exit 0; final `git status --short` emitted no output. No tracked changes after the GREEN run. No unresolved automated concern; I1 addressed with the controller-approved admission contract, pending fresh scoped review.
