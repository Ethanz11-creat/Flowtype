# Four accepted ASR model-center review fixes

Date: 2026-11-10–11 (Asia/Shanghai). Base: `6e0f09f5a3480a7dfd0ca9791f40838d4e940cb9`. Branch: `flowtype-local`. One implementer; no child agents. Candidate commit: `aa5d037c316d03d543b3f3f424cbc16b9e44f325`. All required targeted checks below completed before this explicit-source-file commit.

## Root causes verified and final contracts

### I1 — all-location recovery and explicit Test

Verified the real `ASRRouter.makeBackendRoute` → `ASRStage.execute` → `ASRBackendHealthStore` path. Health demotion applied to any selected primary under auto, but the capture recovery reservation explicitly required cloud. A healthy fallback ended every capture before a repaired service could clear its failure streak.

Removed only the location restriction after the existing eligibility/privacy/credential filtering. The same captured binding identity reserves the existing monotonic 60-second cooldown; `ASRRouteSnapshot.isHealthRecovery` identifies the resulting first attempt. `ASRStage` caps that attempt at the minimum of the existing per-stage timeout, named `ASRRouterProbeConfig.recoveryAttemptSeconds` (5 seconds), and half the shared remaining completion budget. It neither widens candidates nor starts hidden audio/probe requests. Slow recovered native/service models can remain demoted under this bounded real-capture trial; explicit successful Test can restore them without taking fallback's entire budget.

`ASRRouter.explicitRecoveryCompletion(_:)` captures the eligible selected binding key without reserving cooldown or making transport calls. The health store's completion captures a per-key mutation epoch; success, failure, probe updates and internet invalidation advance it. Completion also recaptures the current route and compares the full binding key (backend, revision, model, credential generation, internet requirement). It cannot clear newer failure/probe state or a different revision/credential/runtime. VM native Test invokes it only after the actual successful native trial; service/cloud Test and reselect invoke it only after exact full profile, key generation, coordinator verified state and durable validation checks. Historical `onVerified` callbacks do not clear health. Application composition passes a late-bound closure referencing the router, avoiding eager singleton initialization. Native activation creates a new lease identity as before.

Behavioral coverage uses real router/stage/health with URLProtocol or synthetic providers: failing service → successful cloud fallback → cooldown → repaired service success and restored priority; same lease native failure/recovery; a cancellation-ignoring recovery timeout leaves half the short shared budget for the healthy fallback. Existing candidate/privacy/revision/credential matrices run unchanged. Actual environment Test recovery, newer real failure, changed revision and changed credential generations are covered.

### I2 — application-owned token cancellation

Verified the production model center created unowned UI tasks and offered only a busy label, although Qwen's `execute` already cancels its captured worker and calls `cancel()` guarded by native operation ID, and A5's owned recognition task already suppresses cancellation results and awaits producer drain.

The VM now owns the async intent Task and UUID until the domain operation returns. `currentOperation` returns an `ASRModelOperationCancellation` capturing that UUID; stale captured cancel closures cannot affect a successor. Public Test, primary, fallback, reload and relocation intents share this owner. Cancellation cancels that owned Task, triggering the existing Qwen/A5 handlers. It does not prematurely release admission, persist canceled selection/evidence or publish late transcript success. A pre-start canceled task does not execute its action.

Production `ASRModelCenterEnvironment.actions` exposes the current captured cancellation. The busy view has an Escape/cancel-action button and distinct “已取消；等待计算排空…” text. Closing/recreating a settings window remains observation only; it does not automatically cancel app-owned work.

Coverage invokes actual environment UIActions cancellation (not a test-held task cancel) during uncooperative service recognition; checks unchanged configuration/evidence, drain admission and old cancellation versus new work. Native VM Test/primary/fallback cancel while the synthetic load ignores cancellation, retaining the prior lease, roles and validation until the actual owner drains. Existing window recreation and realtime cleanup tests remain active.

### I3 — explicit external relocation through B5

Verified the production detail omitted relocation and its acquisition entry always called add-only `savePreview`. The legacy load helper uses existing-role selection semantics and is not suitable for preserving unrelated roles.

The detail now has an explicit external-only directory relocation action. Its separate preview explains validation and preserved roles. `stageRelocation` calls the existing `ImportedASRModelActions.stage(directory:replacing:)` with the original imported UUID; previews capture the original imported value and matching installed records. `relocatePreview` captures the exact preview ID, rejects stale previews/records and uses the app-owned cancelable operation. The add-only `savePreview` implementation was not weakened.

`QwenModelState.relocate(_:replacing:sample:)` and the new `.relocation` selection intent reuse the existing B5 provision/reinspection/hardware admission/trial/fingerprint/version/generation/persist/lease transaction. Guards reject managed or ambiguous ownership, other-record path aliases (canonicalized symlinks/case/Unicode), live recording, captures/drains, original record changes, candidate changes and canceled operations. Guards run before loading and again at generation/commit boundaries. Persistence occurs before active lease replacement. Failed/canceled relocation preserves the old model, roles and lease. Unselected relocation uses B5's trial-only commit path and keeps the unrelated active runtime.

B6 design section 65 explicitly requires clearing `legacyPresetID` on relocation. Controller ruled that a legacy-adopted external model keeps imported UUID and exact role SLOT, while only the exact old associated `native:preset` role changes to `native:import:<same UUID>` atomically with clearing the association and updating the path. The candidate remains its inspected imported identity. Original captured association determines whether it was selected before commit; unrelated preset roles are unchanged. Ordinary external backend IDs remain unchanged. Regression covers legacy primary, fallback and unselected paths. An initial association-preserving implementation was rejected by this cross-contract check and has separate behavioral RED evidence below; it is not the final behavior.

Coverage uses production environment/UIActions → preview → VM → Qwen transaction: primary/fallback/unselected success, load failure, commit failure, cancellation, capture and recording occupancy, managed ownership, changed original model, changed installed association, alias before/during load, changed original during load and obsolete preview. Existing importer/add-only/native transaction suites also run.

### M1 — independent text-polish disclosure

Verified production settings uses `ASRModelCenterHost`, bypassing the legacy mode section that displayed `SettingsPrivacyPresentation.localPolishDisclosure`. The model center policy summary now directly consumes that existing presentation and calls its production UIActions navigation to `.settings(.text)`. No new privacy rule or duplicated copy was introduced. Tests construct the real model-center view with production environment actions, exercise all policy/polish toggles, and assert the actual navigation destination.

Offscreen actual SwiftUI fixture renders in `fix-logs/previews/policy-relocation-{light,dark}.png` were visually inspected. Both show the existing text-upload disclosure and text-management link without overlap at 850 × 760 points. The model detail uses its existing scroll area; relocation appears below metadata. These component renders are not manual keyboard/VoiceOver/window tests.

## RED → GREEN evidence

All commands were sequential in this worktree. No tracked source edits occurred while any build/self-test ran. No real user configuration, credentials/Keychain, models, services, network, microphone, clipboard, permissions, signing/notary, download, push or merge were used. Build dependencies remained locked.

Commands use `swift build > <log> 2>&1`, followed only after exit by `swift run --skip-build FlowType --self-test <flag> > <log> 2>&1`. Logs are under `fix-logs/` beside this report.

| Cycle | Build log | Test log / flag | Observed result |
|---|---|---|---|
| I1 RED | i1-red-build2.log | i1-red.log / --asr-backends-only | Exit 1: 1,115 passed, 4 failed; service never recovers priority or wins repaired capture |
| I1 GREEN | i1-green-build.log | i1-green.log / --asr-backends-only | Exit 0: 1,119 passed, 0 failed |
| I2 RED | i2-red-build.log | i2-red.log / --asr-model-center-only | Exit 1: 367 passed, 3 failed; missing cancellation and late persisted selection/evidence |
| I2 GREEN | i2-green-build.log | i2-green.log / --asr-model-center-only | Exit 0: 388 passed, 0 failed |
| I3 RED | i3-red-build.log | i3-red.log / --asr-model-center-only | Exit 1: 398 passed, 8 failed; no same-UUID stage/path repair/runtime update |
| I3 initial GREEN | i3-green-build.log | i3-green.log / --asr-model-center-only | Exit 0: 440 passed, 0 failed; before final B6 legacy correction |
| B6 legacy + M1 RED | legacy-m1-red-build.log | legacy-m1-red.log / --asr-model-center-only | Exit 1: 450 passed, 9 failed (7 legacy association/slot/identity + 2 disclosure/navigation) |
| Final build/model center | final-build.log | final-model-center.log / --asr-model-center-only | Build exit 0 (35.84 s), no emitted warnings/errors; test exit 0: 464 passed, 0 failed |

The first I1 build (`i1-red-build.log`) failed due to the new fixture passing Int rather than UInt64 for session ID. The fixture type was corrected before any product fix, and the next build produced the behavioral RED above. API-shaped optional UIAction/presentation scaffolds were added before I2/I3/M1 RED so failures exercised missing behavior rather than undefined-symbol compilation. Additional adversarial assertions were added during each fix; they are not all claimed to have independent RED observations.

Final focused results and candidate identity follow. Full code/artifact/release gates remain controller-owned after fresh scoped review; no old candidate evidence is relabeled.

## Self-review and limits

Reviewed the entire scoped diff for identity snapshots, cancellation admission/drain, atomic persistence before lease swap, exact role mapping, add-only preservation, managed/captured protections and policy copy reuse. Historical docs/evidence and dependencies are unchanged. No unrelated redesign or cleanup was included. Actual model/vendor integration, human interaction and formal release evidence remain pending as before.


## Final focused verification and handoff

The final code candidate is `aa5d037c316d03d543b3f3f424cbc16b9e44f325`.

- Sources tree: `9025b69faf0da060b173960e7b3e8cd3e8956ea6`.
- scripts tree: `95057298acb707b433912b0652c406a7865f3e6c` (unchanged).
- No product source changes followed the successful final build/tests.
- `git diff --check` and `git diff --cached --check`: exit 0, no output.
- `git status --short` after commit: empty. The requested report, raw logs and preview PNGs are intentionally in ignored `build/reviews/...`, not force-added to historical evidence.

| Exact command suffix after `swift run --skip-build FlowType --self-test` | Raw log | Exit | Passed / failed |
|---|---|---|---|
| --asr-model-center-only | final-model-center.log | 0 | 464 / 0 |
| --asr-backends-only | final-backends.log | 0 | 1,128 / 0 |
| --model-provision-only | final-provision.log | 0 | 197 / 0 |
| --native-client-only | final-native.log | 0 | 986 / 0 |
| --m3-asr-regression-only | final-m3.log | 0 | 294 / 0 |
| --m4-recovery-only | final-m4.log | 0 | 19,793 / 0 |
| --hf-install-only | final-hf-native-activation.log | 0 | 914 / 0 |

The existing `--hf-install-only` entry contains `NativeActivationSelfTests`; it was run for the modified B5 owner. `--native-client-only` contains `ImportedModelUISelfTests`; M3 contains imported lifecycle tests. The model-provision suite alone is not misrepresented as native activation coverage. All commands ran sequentially; no overlapping builds or tests. Final logs contain no FAIL, warning or error diagnostics.

Explicit committed files:

```text
Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift
Sources/flowtype/Services/Speech/ASRRouter.swift
Sources/flowtype/Services/Speech/Backends/ASRBackendHealthStore.swift
Sources/flowtype/Services/Speech/ModelProvisioning/ModelProvisionRequest.swift
Sources/flowtype/Services/Speech/QwenModelState.swift
Sources/flowtype/Settings/ImportedASRModelActions.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterEnvironment.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterView.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift
Sources/flowtype/Settings/ModelCenter/ASRModelDetail.swift
Sources/flowtype/Testing/ASRBackendRoutingSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterFixSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterIntegrationSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterSelfTests.swift
```

All I1/I2/I3/M1 requested fixes are implemented and targeted verification is green. No new unresolved implementation concern was found in the scoped self-review. Known practical limit: bounded automatic recovery favors preserving fallback time; an intrinsically slower recovered primary may need explicit successful Test. The report and fixture tests do not claim actual-model, true service, real UI interaction/accessibility or release acceptance. Fresh independent scoped review and controller-owned full gates remain next.
