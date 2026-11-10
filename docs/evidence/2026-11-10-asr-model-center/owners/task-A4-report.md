# Task A4 implementation report

Current status: DONE after fix round 1 (see appended report). Initial implementation status was DONE_WITH_CONCERNS. Base: 5867ad. Commits recorded below.

## Implemented

- Added pure `ASRBackendRouting.order(selection:policy:descriptors:availableIDs:internetAvailable:degradedIDs:)`: only primary/fallback, deduplication, localOnly/cloudOnly, offline native/service, explicit cloud upload consent, and health reordering without candidate expansion.
- Capture now creates immutable service providers, cloud profile/key/generation wrappers and retained native leases at recording start. Production batch execution iterates `ASRRouteSnapshot.bindings` exclusively; removed production `providerForID` lookup from ASRStage. A missing/empty binding array is honest unavailability.
- Eligibility is decided using nonsecret descriptor metadata before credential reads or provider construction. Excluded cloud/service refs neither access credentials nor contaminate capture errors. Cloud capture uses A2's `Configuration.cloudASRCredential(profileID:store:)`, including its validated selected immutable credential reference, atomic generation/value, nil legacy fallback and empty tombstones. Service credentials validate the owning service namespace before atomic snapshot.
- `CapturedCloudASRProvider` always passes its captured request configuration, returns actual profile identity and rejects DashScope multipart. Realtime starts only from the first captured DashScope binding. Existing early start/ingress/finish/cancel/saved-audio behavior remains; a second realtime candidate cannot reuse the first live handle.
- Preserved sequential attempts, monotonic total 20-second completion budget, cloud attempt cap of 5 seconds when auto has a noncloud candidate, preflight, cancellation/late producer suppression and Apple preview fallback. Actual binding IDs reach context/results/history's existing asrProviderID field; historical legacy IDs still label correctly.
- Added health store keyed by backend ID, revision, model and credential generation. Actual request failures/latency and probe evidence are isolated; network generations reject late probes/old-path request samples. Recovery reservation is monotonic and diagnostic selection does not spend it.
- Added persisted `pendingLegacyNativeResolution`, initialized only by first missing-selection migration for unresolved old native intent. Successful actual lease resolves the real native ID and clears the marker atomically. Explicit clear/selection retires legacy intent. Successful model loading updates an existing native role only; automatic loading only resolves pending legacy intent, without replacing service/cloud selections or reviving cleared intent.
- Updated spec/plan with controller migration and fixture rulings. No new dependency, Package.resolved edit, real service/model/microphone/Keychain/user configuration operation, push, merge, or subagent.

## Exact downstream API handoffs

- `Configuration.pendingLegacyNativeResolution: Bool` is backward-compatible, default false on decode. Do not infer pending intent from old paths once a selection exists without this marker.
- `Configuration.migrateASRBackendSelectionIfNeeded()` is the initial selection+marker projection; ConfigurationStore migration persists both in one configuration blob.
- `Configuration.setASRBackendSelection(_ selection: ASRBackendSelection)` clears the pending marker, including when selection is `.init()` (explicit clear). C1/C4 must use this setter for draft/config edits.
- `ConfigurationStore.setASRBackendSelection(_ selection: ASRBackendSelection) throws` persists the selection+cleared marker before publishing current configuration. C1 can use this for committed explicit route choices.
- `Configuration.resolveLegacyNativeSelection(lease:)` fills only pending localOnly primary/auto fallback; `ConfigurationStore.resolveLegacyNativeSelection(lease:)` persists identity+cleared marker together, preserves current config on persistence failure, and exposes the existing persistence error.
- `Configuration.selectNativeASRBackend(lease:)` replaces an already selected native role only. It does not choose a new route if an explicitly selected service/cloud configuration has no native role. C1's deliberate choose-native action must set the desired route explicitly after validation (B5).
- `ASRBackendID(nativeLease:)` yields `native:import:<actual UUID>` for imported lease identities and `native:preset:<actual preset identity>` otherwise. No hardcoded preset or invented imported UUID.
- `ASRRouteSnapshot(policy:bindings:language:captureError:)` derives old selectedProviderID/localAvailable/cloudAvailable/cloudConfiguration/localLease compatibility fields from captured bindings. `candidateIDs` maps this array. The old metadata initializer remains for legacy characterization fixtures; it never supplies production candidates.
- `ASRBackendBinding.cloudConfiguration` and `.isRealtime` project the immutable CapturedCloudASRProvider. SessionContext.prepareRealtime uses only the first binding's captured configuration.
- `CapturedCloudASRProvider(configuration:underlying:)` owns immutable cloud request state. The injected underlying provider remains the existing real network boundary.
- `ASRBackendHealthStore.recordSuccess(binding:latencyMs:)`, `.recordFailure(binding:)`, `.isDegraded(binding:)`, `.recordProbe(binding:generation:latencyMs:)`, `.networkGeneration`, `.invalidateInternetSamples()`, `.reserveRecovery(binding:uptime:)` provide versioned health/probe/recovery handling.
- Router dependencies include injected credentials, registry, cloud provider, internet availability and native-resolution persistence, allowing tests to run without user state.

## Fixture boundary and scope rulings

The controller approved a Testing-only `FixtureASRStage` adapter to materialize injected legacy fixture provider/lease metadata into bindings before delegating the real stage. Legacy pure `makeASRRouteSnapshot`/`reserveASRCaptureRoute` characterizations moved into that test file; they are no production routing path. New A4 fixtures exercise actual bindings/router/stage directly, including real cloud/service builders with injected URLProtocol.

The first M4 wrapper run exposed controller replay's existing `pipeline[index] is ASRStage` gate. Controller fixtures now use actual ASRStage and capture injected bindings at their recording boundary; production replay type checks were not changed. Exact retry, resource drain, PCM, captured route, language/credentials, timeout and no replacement-provider assertions remain. The realtime snapshot assertion compares the complete explicit fixture snapshot, not a subset.

Authorized adjacent production edits: Configuration/Store marker+setter, QwenModelState successful native-role handoff, FailureClassifier's credential access classification, backend identity/history mapping. RecordingStage and ASRContract did not require changes: recording already captures before audio start and A1/A2 already supplied the common binding/request types.

## TDD and verification evidence

All commands ran sequentially, with full stdout/stderr retained in this ignored task workspace. No full suite/code/artifact/release gates ran; those remain A6. Fixture tests do not mark real service/manual/microphone/signing checks Pass.

### Initial RED

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A4-red-build.log 2>&1
```
Exit 0; `Build complete! (34.65s)`.

```
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-red-backends.log 2>&1
```
Exit 1:

```
FAIL: localOnly retains selected loopback service — got [], want ["service:11111111-1111-1111-1111-111111111111"]
=== ASR backend self-test: 799 passed, 1 failed ===
```

This fails the original fixed-slot router rather than a missing-symbol/compiler error. The first RED fixture was the selected-loopback capture regression. Detailed immutable cloud/native, cancellation, matrix, health and realtime fixtures were added during implementation; not every later assertion had a separate preimplementation RED observation. The later excluded-credential behavior has its own explicit RED→GREEN cycle below.

### Intermediate fixture/build failures (retained, resolved)

- `A4-green1-backends.log`: exit 1, 827 passed/1 failed (`capture retains original wire model`). The transport fixture needed to consume URLRequest.httpBodyStream and decode binary multipart lossily; fixed its request capture, without weakening the model assertion.
- `A4-fixtures-build.log`: compile failure converting FixtureASRStage into an ObservedASR helper's concrete ASRStage field; migrated that test-only helper type.
- `A4-green2-build.log`: exit 1, `input file .../ASRRouter.swift was modified during the build`. This was an implementation workflow mistake; subsequent builds/tests froze tracked sources until each process exited. Successful fresh builds are below.
- `A4-green3-m4.log`: exit 1, 19,779 passed/9 failed, including `M4 real ASR typed policy controls retry`, `M4 explicit retry runs actual ASR once`, `M4 contention ...`, and `M4 realtime retry ...`. Cause: the test wrapper hid the real ASRStage type from existing replay gates. Fixed controller fixtures to use real ASRStage and captured providers at recording. `A4-final-m4.log`: exit 0, 19,788 passed/0 failed.

### Excluded-credential RED before the final production fix

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A4-excluded-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-excluded-red-backends.log 2>&1
```
Build exit 0 (`28.93s`); runner exit 1:

```
FAIL: excluded backend never accesses credential store
FAIL: excluded credential access cannot contaminate permitted route
FAIL: permitted service failure retains its own cause — got configuration(...credentials), want transientASR
=== ASR backend self-test: 857 passed, 8 failed ===
```

The 8 failures cover localOnly excluding cloud, auto with cloud fallback consent off, and cloudOnly excluding a credentialed service fallback. Fixed by metadata eligibility filtering before any credentials/factories.

### Final GREEN on the final production source

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A4-excluded-green-build.log 2>&1
```
Exit 0; `Build complete! (26.92s)`.

```
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-excluded-green-backends.log 2>&1
```
Exit 0; `=== ASR backend self-test: 865 passed, 0 failed ===`.

```
swift run --skip-build FlowType --self-test --m3-asr-regression-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-excluded-green-m3.log 2>&1
```
Exit 0; `=== M3 ASR regression self-test: 292 passed, 0 failed ===`.

```
swift run --skip-build FlowType --self-test --m4-recovery-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-excluded-green-m4.log 2>&1
```
Exit 0; `=== M4 recovery self-test: 19788 passed, 0 failed ===`.

`git diff --check`: exit 0, no output. Only removed an extra EOF blank line in the new fixture after final verification; no behavioral source edits followed.

New direct fixtures cover selected offline loopback; policy/consent/network/health order and deduplication; 20-second shared budget/5-second cloud cap; captured URL/model/key/generation and actual native lease after edits; independent profile/revision/credential health; failed/late probe isolation; monotonic recovery; locked credential vs empty tombstone; persisted legacy marker/actual lease identity/restart/explicit clear/unknown identity; cancellation-ignoring late producer without fallback or delivery; real service failure with cloud consent off/on; DashScope original live start reused at stop without multipart; excluded credential read counters and correct permitted service failure cause.

## Self-review, concerns and Pending

Self-reviewed the full diff for sole candidate source, profile-selected atomic credential capture, metadata filtering before credential reads, stable actual identities, native role-only success mutation, legacy clear semantics, realtime handle reuse/cleanup, stop budget/cancellation/preview preservation, and fixture boundary/type-gated retries. Kept unrelated dependencies and product UI untouched. Existing ASRRouter/Configuration files are large; changes remain localized rather than restructuring them.

**Concern for fresh review (controller notified):** `ASRRouteSnapshot.captureError` is one access error for eligible but unavailable selected candidates. It does not preserve per-backend failure ordering/attribution when several eligible credential captures fail, or when an eligible fallback's credential is locked before an attempted primary fails. Excluded-candidate contamination is fixed and covered. Reviewer should judge first-cause recovery semantics for the still-eligible case; no additional speculative redesign was made after the controller's scope freeze.

Process limitation: the initial fixture established RED for the capture-routing feature, while several detailed assertions were added during implementation rather than all being observed RED upfront. The explicit excluded-credential RED8→GREEN cycle and final pipeline coverage are recorded accurately above.

Manual actual Keychain, live cloud/service endpoints, microphone/permissions, real native inference, release/signing and full-suite gates remain Pending; fixtures cannot establish these. No unresolved failing required focused check.

## Files

Production: Core/Configuration.swift; Core/ConfigurationStore.swift; Core/Pipeline/SessionContext.swift; Core/Pipeline/Stages/ASRStage.swift; Core/PipelineOrchestrator.swift; Core/Recovery/FailureClassifier.swift; Services/Speech/ASRRouter.swift; Services/Speech/QwenModelState.swift; Services/Speech/Backends/{ASRBackendIdentity,ASRBackendRouting,ASRBackendHealthStore,CapturedCloudASRProvider}.swift.

Tests: Testing/{ASRBackendRoutingSelfTests,FixtureASRStage,ASRBackendSelfTests,ImportedLifecycleSelfTests,M3SpeechPreflightSelfTests,M4RecoveryControllerSelfTests,M4StageFailureSelfTests,ModelProvisionSelfTests,NativeRecoveryNavigationSelfTests,RecordingStageTerminationSelfTests,SelfTest,TrialSessionSelfTests}.swift.

Docs: docs/superpowers/specs/2026-11-09-asr-backends-design.md and docs/superpowers/plans/2026-11-09-asr-model-center-a-backends.md.

## Commit and final worktree

`2639591 feat: capture versioned ASR backend bindings per session` (26 explicit task files; 969 insertions, 150 deletions). `git diff --cached --check` passed after removing the new fixture's extra EOF blank line. Final `git status --short` is clean. The ignored report/logs remain in the task workspace for review.

# Fix round 1 — I1 capture-error policy and I2 controller fixtures

Current status: DONE. Read the complete `task-A4-review.md` after the controller persisted the initially missing file. Both Important findings were verified and fixed; the original single-capture-error correctness concern above is superseded by this fix. No additional unresolved correctness concern identified in this pass.

## I1: attempted failure precedence and scoped capture diagnostics

- Added `ASRBackendCaptureFailure` with `backendID: ASRBackendID`, `error: ASRCredentialError`, and a destination derived from the actual backend identity. Cloud failures target the actual profile UUID; services target speech settings until a service-specific UI destination exists.
- `ASRRouteSnapshot.captureFailures: [ASRBackendCaptureFailure]` retains each eligible unavailable backend's diagnostic in eligible selected route order (primary then fallback). Capture uses a dictionary keyed by actual backend ID, then projects through the pure eligibility order; cloud/service profile array iteration cannot select or overwrite a different backend's represented failure.
- `ASRRouteSnapshot(policy:bindings:language:captureFailures:)` replaces the old captureError initializer parameter. `captureError` remains a read-only compatibility projection of the first ordered diagnostic. A6 should use `captureFailures` for identity and destination rather than the unscoped projection.
- ASRStage begins with no attempted failure. Its first attempted provider error determines failure kind/destination and retained-audio retry policy. Capture diagnostics are used only if there was no attempted failure and no successful result. A locked but eligible fallback no longer masks service 503/timeout or removes Retry.
- New transport fixtures exercise real service adapters with injected HTTP 503 and URL timeout, plus locked allowed cloud fallback. They assert transientASR and retained-audio retry. Multiple failed cloud captures in both profile-array orders assert selection-ordered backend IDs, primary error and actual primary destination.

## I2: real stages and explicit binding capture in controller fixtures

- The M3 live-failure capture now materializes its route before prepareRealtime, so the intended failing live handle actually starts and finishes before saved-audio retry creates a fresh handle.
- Affected M3 controller paths use real ASRStage with providers captured at the recording boundary. The pre-existing ObservedASR completion observer remains only for late-completion race instrumentation and now delegates a real ASRStage; it is not the retained-audio replay fixture.
- SelfTest's RecoveryAudioStarter captures its injected RetryProvider into bindings; retryASR returns real ASRStage. The trial controller fixture likewise uses real ASRStage and an explicit empty binding array for unavailable routing.
- No production replay type gate or authorization condition changed. All original silence, retry, fresh budget, live finish, exact PCM and publication assertions remain.
- Added existing `SelfTest.testSessionRecoveryDelivery` to `--m4-recovery-only` (controller approved) so the immediate retry and renewed budget assertions run without the full suite. The full runner still calls that function exactly once; the focused runner exits before the full path.

## RED evidence

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-red-build.log 2>&1
```
Exit 0: `Build complete! (36.81s)`.

```
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-red-backends.log 2>&1
```
Exit 1: `=== ASR backend self-test: 866 passed, 7 failed ===`.

Relevant failures:

```
FAIL: attempted service 503/timeout outranks locked eligible fallback — got configuration(...credentials), want transientASR
FAIL: locked fallback cannot remove retained-audio retry
FAIL: multiple capture errors follow selection order instead of profile array order
FAIL: capture-only failure retains primary backend destination — got nil, want ...provider(primary UUID)
```

Both 503 and timeout failed classification/retry. The multiple-capture fixture also reproduced profile-array ordering and missing identity/destination before implementation.

```
swift run --skip-build FlowType --self-test --m3-silence-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-red-silence.log 2>&1
```
Exit 1: `=== M3 silence self-test: 1009 passed, 5 failed ===`.

```
FAIL: M3 retry: typed transient failure authorizes retained audio — got nil, want transientASR
FAIL: M3 retry: explicit Retry reruns real preflight — got 1, want 2
FAIL: M3 retry: terminated live is never reused — got 0, want 1
FAIL: M3 retry: explicit retry retains fresh-budget rule
FAIL: M3 retry: explicit retry receives new twenty-second budget
```

This independently reproduces the reviewer's existing focused failure on the unchanged production code. Per controller ruling, no separate repetitive M4 RED was run before fixing the same concrete-stage defect.

## Final GREEN evidence

Commands below ran sequentially with sources frozen until each process exited:

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-green-build.log 2>&1
```
Exit 0: `Build complete! (50.75s)`.

```
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-green-backends.log 2>&1
```
Exit 0: `=== ASR backend self-test: 875 passed, 0 failed ===`.

```
swift run --skip-build FlowType --self-test --m3-silence-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-green-silence.log 2>&1
```
Exit 0: `=== M3 silence self-test: 1014 passed, 0 failed ===`.

```
swift run --skip-build FlowType --self-test --m3-asr-regression-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-green-m3.log 2>&1
```
Exit 0: `=== M3 ASR regression self-test: 292 passed, 0 failed ===`.

```
swift run --skip-build FlowType --self-test --m4-recovery-only > .superpowers/sdd/2026-11-09-asr-model-center/A4-fix1-green-m4.log 2>&1
```
Exit 0: `=== M4 recovery self-test: 19793 passed, 0 failed ===`. Count includes the five existing testSessionRecoveryDelivery assertions newly exposed to this focused runner.

`git diff --check`: exit 0 with no output. No source edits after this GREEN sequence. Full suite/release gates remain A6; no real-user/service/microphone/Keychain/native inference checks were performed or claimed.

## Files and self-review

Explicit changes: Core/Pipeline/Stages/ASRStage.swift; Services/Speech/ASRRouter.swift; Testing/ASRBackendRoutingSelfTests.swift; Testing/M3SpeechPreflightSelfTests.swift; Testing/SelfTest.swift; Testing/TrialSessionSelfTests.swift.

Self-reviewed actual backend IDs, deterministic diagnostic order, attempted-error precedence, capture-only recovery destinations, existing controller replay type checks, the original live handle's actual failure and the focused/full runner call sites. Kept production replay gating intact and the late-producer/preview/budget tests unchanged. No subagents, dependency changes, user-state access, push, merge or further scope expansion.

Fix commit: `d2f8d87 fix: preserve ASR attempted failures and controller replay fixtures` (6 explicit files; 120 insertions, 28 deletions). Cached whitespace check passed. Final `git status --short`: clean.
