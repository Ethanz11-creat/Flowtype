# Final review fix wave report

Status: DONE. Base `94283b7`; commit `d43a603` — `fix(asr): separate service attempt admission from live readiness`. Branch `flowtype-local`.

## Scope and contract

Fixed final-review Important I1 and Minor M1 only. No subagents/reviewers, broad reaudit, dependencies, locks, capsule layout/style, release operations, or external actions.

I1: `ASRRouter.readinessBackends` now returns `attemptableServiceIDs` separately from `availableIDs`. Only actually captured loopback bindings are included: explicit primary/fallback selection, routing policy, configuration validation, and credential capture still apply. No health reservation, service probe, sample recognition, or persisted selection mutation is introduced. ReadinessSnapshotBuilder independently filters attempt IDs by loopback location and existing selection/policy rules. ReadinessMonitor carries them into the production snapshot.

`ReadinessSnapshot.attemptableServiceIDs` is a separate admission signal. Live backend states/readyBackendIDs retain existing verification requirements. When no primary is live-ready but a selected service can be attempted, classification is degraded `serviceCheckOnUse` (“本机服务将在识别时检查”), which existing recording preflight allows. Microphone denial still blocks; permission degradation, native loaded-lease requirements and cloud constraints retain existing semantics. Settings aggregation preserves the new signal; the menu does not call an unverified service ready when Accessibility is missing. Preparation text explains the real-request check.

Controller ruling applied: valid persisted explicit selected services also admit real user-start requests after restart with **empty live evidence**; another sample Test is not required each launch. Valid edits/replacement credentials on an already selected service likewise can be attempted, while their old verification is invalidated. This is deliberate admission, NOT verification. Unselected/config-only profiles, unknown/cleared selections, invalid endpoints, and failed credential capture remain blocked. Runtime service availability/failure remains the ordinary real-request responsibility.

The model-center VM was not changed: 60-second row transition, currentValidatedServices freshness, exact full-profile/revision/credential invalidation, coordinator ownership, Test-before-new-selection/reselection, and cloud consent/privacy remain intact. Persisted validation records do not become live proof. Router validation-evidence input remains caller-owned fresh current-process evidence.

M1: the actual sheet now passes the throwing saved-key accessor to `ASRProviderDraftSession.checkConfiguration(storedKey:)`. A single shared lazy resolver handles both closure and retained String APIs: nonblank replacement returns exact input; remove returns empty; new preserve/blank replacement returns empty without storage; existing preserve/blank replacement calls storage and propagates its real error. Recognition's existing String API shares that resolver. No error swallowing or Keychain reads were added.

## TDD evidence

All commands ran from `/Users/yiheng/pycode/flowtype-local`, sequentially. Logs are ignored under `build/final-fix/`. All build commands exited 0. RED self-tests exited 1, GREEN self-tests exited 0. No tracked edits occurred during build/test execution.

1. `swift build > build/final-fix/RED-build.log 2>&1`
   - `Build complete! (32.65s)`.
   - Added composed I1 regression before implementation. For M1, first extracted the existing eager sheet behavior into a throwing closure overload, with no behavior fix, so the actual sheet path and regression share a callable seam.
2. `.build/debug/FlowType --self-test --asr-model-center-only > build/final-fix/RED-model-center.log 2>&1`
   - `=== ASR model center self-test: 343 passed, 2 failed ===`
   - Failures: “I1 expiry alone must allow real recording preflight” and “I1 explicit retest restores attempt admission beyond freshness”; both got `.noEngine`, wanted nil.
3. `.build/debug/FlowType --self-test --native-client-only > build/final-fix/RED-native-client.log 2>&1`
   - `=== Native client self-test: 964 passed, 12 failed ===`
   - Six intent cases each failed error-propagation expectation and saved-key access count (got 1, wanted 0). Existing preserve cases correctly propagated errors.
4. Added controller-ruling restart/edit guard expectations, then `swift build > build/final-fix/RED-guards-build.log 2>&1`
   - `Build complete! (29.45s)`.
5. `.build/debug/FlowType --self-test --asr-model-center-only > build/final-fix/RED-guards-model-center.log 2>&1`
   - `=== ASR model center self-test: 351 passed, 5 failed ===`
   - Exactly the five expected admission failures: expiry, valid edited explicit selection, retest beyond expiry, changed valid credentials, persisted selected restart with no live evidence. All got `.noEngine`, wanted nil. Invalid-key/profile/policy/unselected guards passed.
6. Implemented fixes; `swift build > build/final-fix/GREEN-build.log 2>&1`
   - `Build complete! (41.31s)`.
7. `.build/debug/FlowType --self-test --asr-model-center-only > build/final-fix/GREEN-model-center.log 2>&1`
   - `=== ASR model center self-test: 359 passed, 0 failed ===`.
8. Self-review found accessibility-degraded menu's existing “已就绪” wording could mislabel attempt-only state. Added concrete regression, then `swift build > build/final-fix/RED-menu-build.log 2>&1`
   - `Build complete! (29.98s)`.
9. `.build/debug/FlowType --self-test --asr-model-center-only > build/final-fix/RED-menu-model-center.log 2>&1`
   - `=== ASR model center self-test: 359 passed, 1 failed ===`
   - Only “I1 missing accessibility must not relabel an unverified service as ready” failed.
10. Corrected conditional menu copy; strengthened empty-key validation and successful saved-key preservation assertions; final frozen build and tests below.

## Final focused verification

- `swift build > build/final-fix/FINAL-build.log 2>&1`
  - `Build complete! (30.11s)`; exit 0.
- `.build/debug/FlowType --self-test --asr-model-center-only > build/final-fix/FINAL-model-center.log 2>&1`
  - `=== ASR model center self-test: 360 passed, 0 failed ===`; exit 0.
- `.build/debug/FlowType --self-test --asr-backends-only > build/final-fix/FINAL-asr-backends.log 2>&1`
  - `=== ASR backend self-test: 1110 passed, 0 failed ===`; exit 0.
- `.build/debug/FlowType --self-test --native-client-only > build/final-fix/FINAL-native-client.log 2>&1`
  - `=== Native client self-test: 986 passed, 0 failed ===`; exit 0.
- `git diff --check`: no output, exit 0.
- `rg -n 'warning:|error:|FAIL:' build/final-fix/FINAL-*`: no matches. This is incremental-build evidence, not a clean-build warning-free claim. Existing HF captured-mutation warning was not re-evaluated.

The suites overlap; counts are per invocation and must not be summed as unique tests. Model-center tests retain their existing isolated preview-path diagnostics; native/backend suites retain named test progress output.

I1 regression composes actual isolated application environment, explicit Test/selection, synthetic clock +60 seconds, row/history/live evidence, actual router metadata capture, snapshot builder/classifier, and the production SessionController.readinessPreflight function. It covers no implicit recognition, real selected route capture, denied microphone, cloud-only policy, exact profile edit without revision rotation, credential replacement, JSON-persisted restart with empty current evidence, locked credential accessor, nonloopback URL, unknown selection, and cleared selection. Existing backend/native suites cover broader policy/cloud consent, native loaded identity, readiness, and real controller preflight lifecycle. No actual capture/network was used.

M1 regression covers new/existing × replace/remove/preserve/blank replace with throwing saved-key accessor, exact read counts, actual configuration-valid/failure results, successful existing preserve/blank preservation, and untrimmed replacement through the shared recognition resolver and injected transport.

## Files changed

- `Sources/flowtype/Services/Speech/ASRRouter.swift`
- `Sources/flowtype/Core/Readiness/ReadinessMonitor.swift`
- `Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift`
- `Sources/flowtype/Core/PipelineOrchestrator.swift`
- `Sources/flowtype/Settings/ReadinessPresentation.swift`
- `Sources/flowtype/Settings/ASRProviderEditSheet.swift`
- `Sources/flowtype/Testing/ASRModelCenterIntegrationSelfTests.swift`
- `Sources/flowtype/Testing/ProviderDraftCheckSelfTests.swift`

Explicit-file git add/commit only. All final verification preceded this commit; no tracked edits followed final verification.

## Self-review and limits

Reviewed all eight-file diff, application monitor wiring, preservation of policy/selection and native availability constraints, shared editor resolver, and regression expectations. Fixed the discovered menu honesty edge with its own RED/GREEN evidence. No outstanding correctness concern found within scope.

No real models/downloads/services/vendor network, user configuration, Keychain, microphone, clipboard, permission changes, signing or notarization. Synthetic fixtures and injected credentials/transports only. No full code/artifact/release gate: controller D3 and fresh scoped review remain pending. These focused passes do not establish manual UI, actual service loss/recovery, real cloud/native quality, remote CI, or release acceptance.
