# Task B4 report — persistent queue and atomic ASR publication

Status: DONE. Required GREEN completed; implementation frozen. Base: `15f158f`. Commit: `e0988d2` — `feat: persist and atomically publish ASR installations`. No full suite (controller reserves it for B6).

## Implemented

- Added the exact spec `ModelInstallState`, `ModelInstallSnapshot`, `ModelStorageOwnership`, `ASRInstalledModelRecord` and `ASRNativeValidationRecord` schemas. Installation IDs and imported model IDs are distinct. Configuration decoding defaults the new installed array to empty; encoding roundtrips it.
- Added actor `ModelInstallationCoordinator` with enqueue/pause/resume/cancel/recover/snapshots and injected transfer, publisher, clock, disk sampler and journal root. Job IDs explicitly equal immutable plan IDs. Jobs persist captured endpoints, pinned commits, credentials references and byte progress, separate from B3 sidecars. Plans are revalidated and disk capacity is freshly sampled at enqueue, queued start and explicit resume using remaining bytes plus max(256 MiB, total/10), with overflow checks.
- One task retains ownership through transport cancellation drain, verification and publication. Pause/cancel revoke a generation and await the active task. Late callbacks and completions cannot update or publish a new generation. Cancelled partials remain resumable. Long Retry-After errors become paused/rateLimit, without automatic retry or a promised countdown.
- Recovery never starts networking. Interrupted jobs become paused; already-renamed jobs complete registration offline after checking the manifest, every planned digest and the strict existing static inspector. Corrupt, mismatched or symlink jobs become isolated failed snapshots with invalidJournal; their bytes remain unchanged. No B4 code deletes model files or external directories.
- Publisher restricts movable staging to the configured sibling `installation-jobs/<plan.id>/model`; coordinator injection must retain the same managed layout. Roots and component paths reject symlinks. Same-volume staging and final roots are checked before `renamex_np(RENAME_EXCL)`, with no copy fallback or overwrite.
- All planned file sizes/digests and the existing engine-specific strict static inspector must pass before the complete manifest is written. Extra payloads/sidecars and reserved manifest destination collisions are rejected. A shared publication permit synchronizes revocation with the immediate synchronous exclusive rename; it never covers inspection, registration or network awaits. Verification remains cancellable. After rename, pause/cancel waits registration and returns the installed outcome, without rollback.
- Manifest stores the immutable plan and stable installation/imported identities before rename. Registration uses a fresh inspection at the canonical final directory because fingerprints include absolute file paths. Repeated publication/recovery keeps one imported/installed pair. A registration failure is reported as failure and retried from the committed directory without downloading again.
- Added a MainActor production registration closure and narrowly scoped throwing `ConfigurationStore.registerInstalledASRModel`: persist the complete pair, verify persistence, then publish current. Existing debounced save behavior is not used for installation success. The library upsert preserves existing validation and every selection field.
- Added RuntimePaths installed/jobs directories and durable `markLibraryDetached(jobID:)` for B6. It refuses invalid journals and active jobs. Recovery never re-registers a detached library entry.

## TDD evidence

Initial RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-red.log 2>&1
```

Exit 1, expected missing B4 API/type errors including missing ModelInstallationCoordinator/Publisher and `Configuration` having no `installedASRModels` member. Tests were written first against the required transaction interfaces.

Behavior RED after first implementation:

```sh
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-focused-initial.log 2>&1
```

Exit 1: `314 passed, 5 failed`; crash boundary retries failed integrity checks. Cause: Foundation's inferred trailing directory slash changed the manifest destination URL after creation. Fixed deterministic directory URLs. The lifecycle RED log (`B4-lifecycle-red-focused.log`) also contains an index-out-of-range test-harness crash after correctly detecting failed recovery; guarded the dependent lookup so later failing checks could run.

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-retry-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-retry-red-focused.log 2>&1
```

Build exit 0; focused exit 1: `354 passed, 18 failed`. Besides URL identity, this caught a committed registration retry downloading again (`got 22, want 11`) and path-dependent fingerprints differing from a fresh final-directory inspection. Fixed bypassing the payload phase for committed installs and canonical final-path inspection.

Final self-review RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-final-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-final-red-focused.log 2>&1
```

Build exit 0; focused exit 1: `408 passed, 6 failed`, expected:

- `B4 corrupt journal cannot authorize library removal`
- `B4 corrupt journal retained unchanged — got 345 bytes, want 4 bytes`
- Same-plan enqueue after empty-disk rejection threw integrity because admission had already created its job directory.
- External valid staging was moved and registered, failing all three ownership checks.

Fixed the invalidJournal detach guard, moved staging creation after successful admission, and enforced the exact managed sibling layout.

## Final GREEN

Commands ran sequentially:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-final2-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-final2-focused.log 2>&1
.build/debug/FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-isolation.log 2>&1
git diff --check
```

All exit 0. Exact output:

```text
Build complete! (26.78s)
=== HF install self-test: 419 passed, 0 failed ===
=== M5 isolation self-test: 64 passed, 0 failed ===
```

Final incremental build and focused/isolation logs contain no warnings or failures. `git diff --check` produced no output. No full suite was run, per controller instruction. No production changes after these required gates.

The preceding `B4-final-focused.log` was `416 passed, 1 failed`: after adding exact staging ownership, the production-registration fixture still used its old generic fixture path instead of the injected RuntimePaths path. Corrected only that fixture to move synthetic staging into `paths.asrInstallationJobsDirectory/<plan.id>/model`; the final2 commands above test the same production code and pass all checks.

## Meaningful fixture coverage

Synthetic tiny Core ML package metadata and injected bytes exercise actual file hashing, strict static inspection, job journals, manifests, exclusive filesystem rename and library persistence. No native runtime is loaded; synthetic packages do not claim graph/runtime validity.

Covered single transfer ownership, drain resistance, intermediate byte progress, queued-job sequencing, interrupted downloading recovery with zero requests, explicit resume retaining source/credential references, late progress/completion generation rejection, cancelled partial resume, five publication crash boundaries, repeated coordinator recovery, final-path fingerprint consistency, cancel during verification/preauthorization and after rename, failed durable registration/retry without redownload, default-empty configuration decoding, full static rejection after valid hashes, runtime diskFull, long rate-limit pause, fresh disk resampling, exact remaining/minimum reserve admission, 10% reserve on a synthetic 3 GiB metadata plan, invalid/symlink journals, detached recovery and external staging rejection.

## Files changed

- `Sources/flowtype/Services/Speech/ModelInstallation/ASRInstalledModelRecord.swift`
- `Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallSnapshot.swift`
- `Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallationCoordinator.swift`
- `Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallationPublisher.swift`
- `Sources/flowtype/Testing/HFInstallTransactionSelfTests.swift`
- `Sources/flowtype/Testing/HFInstallSelfTests.swift`
- `Sources/flowtype/Core/Configuration.swift`
- `Sources/flowtype/Core/ConfigurationStore.swift`
- `Sources/flowtype/App/RuntimePaths.swift`
- `Sources/flowtype/Services/Speech/LocalModelManager/LocalModelLibrary.swift`

## Self-review and scope

Reviewed all new production files and the existing-file diff. Corrected the concrete identity, final fingerprint, registration retry, corrupt detachment, admission retry and ownership issues above. Every B4 fixture injects transport, credential access, library registration, disk sample and temporary roots; production registration is tested only with an isolated named defaults suite, fake credential/keychain access, injected persistence and isolated RuntimePaths. Named defaults are removed after the fixture. No actual user settings/secrets/models/global Hub token, clipboard, microphone or permission state is read or written.

No dependencies or Package.resolved changes. No activation, engine loading, user model deletion, global cache mutation, full suite, real network/weights, signing or release/push work. Existing AudioRecorder warnings appeared in the first broad recompilation and were not changed. Final incremental build warning status is recorded with GREEN.

## B5/B6 handoff

```swift
let publisher = ModelInstallationPublisher.production(store: store, paths: paths) // MainActor
let coordinator = ModelInstallationCoordinator(
    transport: HFDownloadTransport(), publisher: publisher,
    journalRoot: paths.asrInstallationJobsDirectory)
let jobID = try await coordinator.enqueue(plan) // jobID == plan.id
await coordinator.pause(jobID: jobID)
try await coordinator.resume(jobID: jobID)
await coordinator.cancel(jobID: jobID)
let snapshots = try await coordinator.recover() // startup: offline, unfinished => paused
```

Injection alternatively accepts `@Sendable (HFPlannedFile, URL, String?, @escaping @Sendable (Int64) -> Void) async throws -> Void`, plus clock/disk sampler. Root layout must remain `<models>/installed` and `<models>/installation-jobs`, even for isolated roots. B3 remains sole owner/writer of adjacent per-file sidecars; coordinator only writes `job.json`. It never mutates/deletes partials or sidecars while transport is active.

Activation/usage/delete APIs must use `ASRInstalledModelRecord.importedModelID`, never install/job ID. Installing does not choose or activate a model; native validation remains nil. B5 can use the exact spec ASRNativeValidationRecord now defined.

Before B6 removes an installed library entry while retaining files, call and successfully await `try await coordinator.markLibraryDetached(jobID: record.id)`. On throw, retain the library record; corrupt journal input cannot authorize removal. The durable `libraryDetached` flag prevents startup recovery resurrection. Actual managed file deletion/usage reservation remains B6.

Pause/cancel before rename revokes publication and drains. After atomic rename has committed, it is too late to cancel: the call waits for durable registration and reports installed (or an honest registration error eligible for offline recovery). No rollback or file deletion occurs.

## B4 fix round 1 — review I1 / I2 / M1

Base `e0988d2`. Fix commit `c326218` — `fix: cancel ASR verification and admit committed retries`. Status: DONE. Review source: `task-B4-review.md`. Controller authorized the narrow B3 verifier edit and, after identifying its cancellation integration consequence, the corresponding transport catches and regression. No new agents, dependencies, model execution, user state or full-suite work.

### Changes

- I1: Added `HFFileVerifier.verifyAsync`, explicitly `@concurrent` in Swift 6.2. It executes the injected synchronous verifier away from the coordinator actor, within the same task and cancellation state. It introduces no detached or independent production worker. The caller awaits it; pause/cancel keeps `activeTask`/ownership until the verifier and open-file defer have drained. Coordinator checks cancellation/generation again after re-entering its actor before writing progress.
- Real verification checks `Task.checkCancellation()` before/after bounded disk reads and between every 64 KiB chunk, and rethrows CancellationError without mapping it to network. An injected ChunkReader permits deterministic read/cancel tests without allocating large payloads.
- The publisher's internal transaction is explicitly `@concurrent`, and its file verification awaits the same chunk-cancellable helper. Static inspection remains outside the coordinator actor. The short existing revocation/rename lock and the postrename registration rule remain unchanged.
- I2: Added a shared committed-manifest identity check (version, immutable full plan, managed destination, installation/import identity, ownership and no symlinks). Admission treats a matching committed manifest as zero remaining download bytes, while retaining a fresh disk sample and the required reserve. Publisher still rehashes every payload and runs strict static inspection before registration. Failed or mismatched manifests cannot bypass that verification or trigger a network fallback.
- M1: Each active file transfer now has its own UUID in addition to the job generation. Completion invalidates it before further verification, so earlier-file progress tasks cannot replace a later file's byte aggregate.
- Required B3 integration: verifier cancellation is handled separately from integrity failure in both complete (200/206) and 416 outcomes. The 416 branch no longer swallows CancellationError with try?. Both outcomes retain resumable partial/sidecar bytes and report the existing stable cancelled transport error without retry.

### Exact RED evidence

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-api-red-build.log 2>&1
```

Exit 1, expected missing injection arguments `verification` and `readChunk`. Added only these injection seams while retaining synchronous actor verification, then ran behavioral RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-red-focused.log 2>&1
```

Build exit 0 (`Build complete! (28.02s)`); focused exit 1:

```text
  ✗ FAIL: B4 fix actor responds before hash completes
  ✗ FAIL: B4 fix next owner waits hashing drain — got 3, want 1
  ✗ FAIL: B4 fix hash inherits parent cancellation
  ✗ FAIL: B4 fix actor responds before hash completes
  ✗ FAIL: B4 fix next owner waits hashing drain — got 3, want 1
  ✗ FAIL: B4 fix hash inherits parent cancellation
  ✗ FAIL: B4 fix chunk cancellation throws
  ✗ FAIL: B4 fix cancelled verifier does not read remaining chunks — got 4, want 1
  ✗ FAIL: B4 fix committed disk admission: HFDownloadError(code: FlowType.HFDownloadError.Code.diskFull, retryAfter: nil, requiresPause: false)
  ✗ FAIL: B4 fix completed-file callback cannot regress progress
=== HF install self-test: 431 passed, 10 failed ===
```

After implementing I1/I2/M1, the newly authorized transport-integration regression supplied a second RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-transport-red-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-transport-red-focused.log 2>&1
```

Build exit 0 (`Build complete! (33.97s)`); focused exit 1, only expected transport failures:

```text
  ✗ FAIL: B3 hash cancellation retains partial after 200 — got nil, want Optional(8 bytes)
  ✗ FAIL: B3 hash cancellation retains sidecar after 200
  ✗ FAIL: B3 hash cancellation retains partial after 416 — got nil, want Optional(8 bytes)
  ✗ FAIL: B3 hash cancellation retains sidecar after 416
=== HF install self-test: 447 passed, 4 failed ===
```

### Additional fixture evidence / self-review

- Deterministic synchronous verifier gate resists cancellation until explicitly released. Both pause and cancel must become observable through coordinator snapshots before that gate exits. The queued next owner must not start while verification is still draining. The gate then verifies the same task's cancellation flag; the stopped installation never publishes, and the queued job succeeds only after drain.
- A real three-chunk file uses an injected actual FileHandle reader gated after the first chunk. Cancellation must remain CancellationError and stop at one read; it must not hash/read the remaining payload or become a network failure.
- A valid static synthetic package contains a sparse 300 MiB file, hashed with bounded buffers. Its first registration fails after rename. Explicit resume rejects fresh available capacity of 256 MiB minus one byte, then succeeds with exactly 256 MiB (less than payload size), registers once and sends zero transport requests. No real weights or graph execution are involved.
- A stored first-file callback fires while the next file holds the active transfer, after its newer aggregate is observed. It must not regress progress; the fixture subsequently drains and installs.
- Actual injected HTTP 200 and 416 replies exercise transport cancellation in the new real chunk verifier, retain the exact partial and sidecar, classify cancellation, and make only one request.
- Self-review read the complete production diff, checked actor re-entry guards and transport ownership/catch paths, and ran diff whitespace checks. No unowned verifier tail, activation, rollback or deletion was introduced. Final GREEN below governs the freeze.

### Fix round 1 final GREEN

Commands ran sequentially:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-final2-build.log 2>&1
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-final-focused.log 2>&1
.build/debug/FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-09-asr-model-center/B4-fix1-isolation.log 2>&1
git diff --check
```

All exit 0, exact outputs:

```text
Build complete! (29.23s)
=== HF install self-test: 451 passed, 0 failed ===
=== M5 isolation self-test: 64 passed, 0 failed ===
```

Final build/focused/isolation logs have no warnings or failures. Diff whitespace check produced no output. No full suite ran. Production and tests frozen after these required gates; only this evidence report and commit metadata are updated afterward.

Files in this fix round: HFDownloadJournal.swift, HFDownloadTransport.swift, ModelInstallationCoordinator.swift, ModelInstallationPublisher.swift, HFDownloadSelfTests.swift, HFInstallTransactionSelfTests.swift. No other source files, Package.resolved, model/runtime state or dependencies changed. I1, I2 and M1 are addressed; no remaining concerns identified in the scoped self-review.
