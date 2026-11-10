# C4 — application-owned ASR model center integration

Status: DONE. Stable commit and the single planned code gate both passed; exact closeout follows below. Worktree `/Users/yiheng/pycode/flowtype-local`, existing linked branch `flowtype-local`; base `cdc249b4a15645465f9a22d422e25fee0beeb493`. No nested agents, new dependencies, Package.resolved changes, push, merge, install, signing, or release. The executing-plans/TDD/verification-before-completion skills were read and applied under the task's controller-owned review/gate instructions.

## Delivered ownership and production seams

- New `ASRModelCenterEnvironment` owns the one C1 VM, A5 validation coordinator, HF install session, discovery client and import-preview facade, retaining the existing shared B4 installer and unique Qwen runtime. It owns only recovery/projection clock work; no second installer, recognition or native lifecycle task. `ASRModelCenterHost` is a disposable SwiftUI view over that retained environment.
- AppDelegate constructs the environment before connecting `ReadinessMonitor.connectCurrentValidation` to **only** `model.currentValidatedServices`, then starts offline job recovery/projection observation. The monitor never initializes the environment; the environment never constructs a monitor during its initializer. Model changes refresh readiness without a readiness→VM feedback edge. Config changes refresh after Published's willSet; a one-second application clock refreshes installer snapshots and the VM's exact 60-second evidence expiry, even with no window.
- A5's callback uses a weak VM receiver to `recordValidation`, preserving the coordinator timestamp and minimal history-only payload. The awaited VM test alone creates live evidence; duplicate callback/test history writes deduplicate. Restored history never enters live readiness.
- Production Qwen `sampleProvider` and VM sample both call the exact `ASRApplicationModelDependencies.sample` canonical C2 resource loader. Legacy explicit import/useImported/preset/download/retry consequently retain B5's validation boundary. Startup remains B5's prior-fingerprint/engine-validation offline restore and performs no automatic trial/download.
- Production Qwen `canUnload` calls the shared `SessionResourceCoordinator.isReserved`, reading its actual reservation rather than @Published presentation. B5 still performs the unique lifecycle gate and B6 captured/drain check. Environment removal reasons distinguish record-only/managed-file ownership, exact native model/capture/drain occupancy, pending native operation and active-model recording reservation; domain final guards remain authoritative.
- Every production C3 UIActions effect is supplied: configuration, retained import/HF/discovery/checks/navigation, explicit NSOpenPanel, save-only durable import/local/cloud callbacks, exact credential presence/value, official HF token slot, guarded explicit clipboard copy, removal projection, exact-job pause/resume/cancel/clear. Saves refresh projections and preserve C2 revisions/save-before-test behavior.

## Navigation and old-entry audit

`SettingsTarget.modelInstallation(UUID)` now names exact installation tasks. `.asrBackend`, old `.provider(UUID)` and `.localModels` resolve through the retained environment; no missing ID selects another row. Missing selected placeholders also return to speech with no focused model. Installation anchors/highlight use the job UUID. Microphone/accessibility/Apple anchors remain outside model-center scrolling; cancelled old navigation tasks cannot scroll a newer request.

SettingsWindowController → MainWindowView → SettingsPage → ASRSettingsContent and OnboardingWindowController → OnboardingView → ASRSettingsContent pass the same environment. Legacy cloud/local list bodies now navigate to the shared host and have no old activate/save/load/delete buttons. `ASRModelStatusCard` uses the same projections and backend-target navigation.

No gratuitous changes were made to `OnboardingPipeline` or `TrialSessionPresenter`: both already use `RecordingStage`/`ASRStage`, the unique router's immutable captured binding, injected shared `SessionResourceCoordinator`, and scoped `DemoInjectionStage`. Their production presenters still receive the shared configuration, current readiness and guarded explicit copy. Closing trial cancels its session, not model-center work; delivery/permission policies are untouched. Menus and recovery cards already call StatusBarController's SettingsWindowController destination route and now land in the new host.

Compatibility-only `QwenModelStatusCard`, `ImportedASRModelList`/`loadPreview`, `LocalModelPicker.selectPreset`, `ModelDownloader.startDownload` and old connection-check/domain APIs remain for isolated existing fixtures. Production ASRSettingsContent always takes the environment branch, its old fallback's cloud/local bodies are now delegates, and ASRModelStatusCard no longer embeds the old Qwen card; no production UI reaches these old selection/test buttons. Explicit legacy native domain calls still use the unique Qwen/B4 lifecycle and now receive the canonical sample. Production cloud saves call only `saveModelCenterASRDraft`; saved recognition/selection is C1 VM through C3 disclosure.

## Controller-approved service credential integration fix

The audit found two incompatible A/C handoffs: anonymous router bindings used nil generation while VM live evidence uses a UUID; C2 saves versioned service references while the old router accepted only the legacy fixed reference. `LocalASRServiceProfile.credentialSnapshot(store:)` is the shared VM/editor/router boundary:

- Anonymous: `value:nil` plus pure locked `generation(id: "asr.service.<exact profile UUID>")`; never reads an unused Keychain value.
- Bearer: accept the exact legacy reference, or exact profile namespace plus one valid UUID version; reject cross-profile/cloud/HF/malformed references. Capture value+generation together in one atomic snapshot and require a nonempty value.
- Real `saveLocalASRServiceDraft` UI callback → VM trial → router readiness → recording binding regressions verify versioned credentials. An in-flight immutable provider keeps version one after a save; next capture uses version two. A5/current evidence expires or invalidates without rewriting the old captured call. Anonymous locked-read regression proves no unnecessary key read.

## Safe partial clearing

`ModelInstallationCoordinator.clearPartial(jobID:)` is an independent explicit actor-owned operation; cancel continues to retain staging. It refuses active/draining/verifying/publishing/installed/detached/invalid-journal jobs. It validates the exact durable version/job/plan/snapshot/date against the same in-memory owner, owned jobs-root/UUID/model layout, absence of committed publication or registered installation authority, and physical inventory. Symlinks, hardlinks, case-spelling aliases, arbitrary directories, oversized/unplanned files, foreign sidecars/manifests and imported/installed directory aliases cannot authorize deletion. Only planned payloads, matching transport sidecars and the exact prepublication manifest are allowed.

A clearing-ID reservation covers every await, excludes resume/stop/detach/scheduling and blocks recovery via the existing removal count; defer releases it on all exits. After durable zero-byte paused journal publication, the final current-configuration + ownership recheck and deletion execute in one MainActor transaction, matching the established remove transaction and preventing a concurrent import of staging from being deleted. Failure preserves files, records truthful failed/progress state and releases the reservation. A crash before removal leaves recoverable bytes that recovery recounts; successful clear resumes as a fresh explicit download. No UI performs filesystem deletion.

## TDD and verification evidence

Logs are in this ignored task workspace. All builds and tests are sequential; tracked sources remain frozen while commands run.

| Regression | RED | GREEN |
| --- | --- | --- |
| Safe actual clear, active/cancel-draining, journal, extra file, symlink/hardlink/case alias, committed installation | `C4-clear-red-build.log` build 35.84s/exit0; `C4-clear-red-focused.log` 879 passed/23 failed against callable no-op scaffold | `C4-clear-green-build.log`; `C4-clear-green-focused.log` 902/0 |
| Application recovery focus and configuration/clock refresh | buildable `C4-app-red4-build.log`; `C4-app-red2-focused.log` 248/10 | included in app GREEN |
| Anonymous + versioned service VM/router/capture chain | `C4-credentials-red2-build.log`; `C4-credentials-red-focused.log` 267/6 | `C4-app-green-build.log` 32.96s/exit0; `C4-app-green-focused.log` 273/0 |
| Deleted selected backend must not focus placeholder | `C4-edge-red-build.log` 27.55s/exit0; `C4-edge-red-focused.log` 281/1 | `C4-edge-green-build.log`30.68s/exit0; `C4-edge-green-focused.log`282/0 |
| Registered installation must block clear even if directory disappeared | `C4-clear-record-red-build.log`; `C4-clear-record-red-focused.log`905/2 | `C4-final-hf-install-only.log`907/0 |
| Concurrent import after captured config must survive clear | `C4-clear-race-red-build.log`28.39s/exit0; `C4-clear-race-red-focused.log`910/2 | final affected run pending below |

Initial `C4-app-red-build.log`/red2 and `C4-credentials-red-build.log` contained ordinary compile errors (closure actor conversion and an inferred static initialization reference cycle); they are not behavioral RED claims. `C4-app-red-focused.log` initially included a fixture's no-op persistence mistake; corrected isolated durable persistence before the authoritative app RED above. The final assembly explicitly connects readiness after owner construction.

`testWindowRecreationKeepsOwnership`, `testRecoveryTargetsSpecificModel`, `testLegacyEntryUsesSameSelection` are registered in the C1 filter through `ASRModelCenterIntegrationSelfTests`. Window recreation runs actual in-flight synthetic A5 recognition; the second root sees busy and cannot duplicate it, then receives the result/history. Additional tests cover canonical native legacy sample, actual resource reservation at Published willSet, captured-lease unload rejection/release, key/profile immutability, coordinator timestamp, 60-second expiry and exact service credential namespace. Native/domain fixtures use synthetic providers/transport/PCM, memory credentials and temporary roots only.

Before the final clear-race guard, the complete required sequential targeted set passed on stable source:

| Command (`.build/debug/FlowType --self-test --...`) | Pass/Fail | Log |
| --- | --- | --- |
| asr-model-center-only | 282/0 | C4-final-asr-model-center-only.log |
| hf-install-only | 907/0 | C4-final-hf-install-only.log |
| asr-backends-only | 1084/0 | C4-final-asr-backends-only.log |
| native-client-only | 960/0 | C4-final-native-client-only.log |
| m4-recovery-only | 19793/0 | C4-final-m4-recovery-only.log |
| m5-isolation-only | 64/0 | C4-final-m5-isolation-only.log |

`C4-final-build.log`: swift build exit0,37.50s. Those final logs contain no warning/error/FAIL lines; dependency lock and whitespace checks passed. The final race fix will rerun only affected build/HF/model-center, followed by the frozen full code gate, as directed by the controller.

## Self-review and pending acceptance

Consolidated review covered production callsite reachability, exact identity/credentials, callback dates/history vs readiness, timer feedback, shared initializer ordering, actual reservation and native drain, disclosure/save-only paths, exact job targets, durable physical ownership and failure/restart state. Self-review found and fixed the deleted-placeholder focus, preserved permission-target scrolling, registered-with-missing-directory protection, and late import cleanup race. No untracked real user data was read/written by fixtures. Known old HF captured-variable compiler warning was not re-emitted by final incremental builds; final evidence below states actual output.

C3's previously inspected model-center layout is reused without a layout redesign; no additional offscreen PNG run is claimed. Real integrated window layout/scroll/focus, VoiceOver/reduced motion, sample intelligibility/real model quality, actual disconnected-network resume, external services/vendors/credentials, mic/permissions/clipboard, artifact/release/signing/notarization and remote CI remain **Pending**. The new acceptance Markdown lists all30 H1–H8 case IDs as Pending; D2 still owns machine-readable ledger/gate. No Pending item is called Pass from fixtures or C3 screenshots.

Stable commit and exactly one planned postcommit `scripts/verify.sh --lane code` are pending below; no full code lane has run yet for C4.

## Stable commit and code gate (running)

Stable explicit 28-file commit: `c6e0efa` — `feat: integrate ASR model center across native client recovery` (762 insertions,283 deletions). No source changes after the final affected checks or commit. Source status/tree identity is recorded with gate closeout below.

Final cleanup race RED910/2→GREEN914/0 (`C4-stable-hf-install-only.log`); model-center `C4-stable-asr-model-center-only.log`282/0. `C4-stable-build.log`34.50s passed and **did** re-emit the previously known `HFInstallTransactionSelfTests.swift:169` captured `reject` warning; no new warning. Final await-boundary audit added the same clearing-reservation check after resume's drain await (otherwise a pre-existing suspended resume could bypass a newer reservation). `C4-freeze-build.log`27.48s/exit0, no warnings/errors; `C4-freeze-hf-install-only.log`914/0. No unrelated suites were repeated after this isolated installer guard; the full frozen gate follows. Whitespace/staged checks and Package.resolved comparisons pass.

Exactly one planned C4 code gate is starting now, after the clean stable commit. Tracked source is frozen for its duration:

```sh
scripts/verify.sh --lane code > .superpowers/sdd/2026-11-09-asr-model-center/C4-code-gate.log 2>&1
```


## Final closeout — DONE

The single planned gate exited **0**, `Verification code: Pass`; no retry or second gate was needed. Exact report:

`build/verification/D9CB6556-6056-4207-B50C-1A010DAEA066/verify-report.json`

All seven phases Pass: source-start, platform-os, platform-arch, platform-swift, code-build, code-full, source-end. Frozen git SHA **c6e0efaed8561daaeed333a642b71765375e6314**, full Git tree **1dbc3d82e3d466b6c456d28110fce6e2ef9e8835**, gate Sources tree **a54eed31ccff11d9ec8605f27f0eb152d084c867**, dirty **false**. Final post-gate `git status --short` is empty. All28 committed files belong to C4; Package.resolved is unchanged.

Full self-test child `8D406C9A-0F95-4B7C-8757-71E3113C107D`: **28,205 passed / 0 failed**. Full stderr is empty. Both gate code-build and code-full stdout/stderr contain no warning/error/FAIL lines. The intermediate known HF169 warning documented above remains a baseline compiler concern only; it did not appear in the final freeze build or gate.

| Artifact (relative to gate run directory) | Bytes | SHA256 |
| --- | ---: | --- |
| verify-report.json | 5493 | `5eeb1fd37d350d85bd0dd1d4a3d48e3cf9bb2a4cd16d18499d5cc626cbf02fdc` |
| children/8D406C9A-0F95-4B7C-8757-71E3113C107D/stdout | 3967 | `54efa2ae9f44c9198c51b89ffa6b58aa7c0462eb3c82cbcda7102c5c43f997bc` |
| children/8D406C9A-0F95-4B7C-8757-71E3113C107D/stderr | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Gate `manualStatus` and `ciStatus` remain **Pending**; `artifactIdentity` is null. H1–H8 all30 acceptance cases remain Pending. No actual model/vendor/service/microphone/network-fault/real-window/signing/remote-CI check is inferred from the automated result. Fresh C4/whole-A–C review remains controller-owned; no reviewer was spawned by this implementer.

The final late-import fixture deliberately returns the previously captured configuration after synchronously registering the staging directory as an external import; this deterministically recreates the actor-hop stale snapshot. Clear now refuses and preserves the whole stage. Removing the conflicting record and explicitly retrying clear/resume succeeds, demonstrating reservation release. Resume rechecks the reservation after any native writer drain await. This fix was explicitly approved by the controller before final freeze.

### Exact committed files

```text
Sources/flowtype/App/FlowTypeApp.swift
Sources/flowtype/Core/Readiness/ReadinessMonitor.swift
Sources/flowtype/Core/SessionResourceCoordinator.swift
Sources/flowtype/Services/Speech/ASRRouter.swift
Sources/flowtype/Services/Speech/Backends/ASRCredentialStore.swift
Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallationCoordinator.swift
Sources/flowtype/Services/Speech/ModelInstallation/ModelInstallationPublisher.swift
Sources/flowtype/Services/Speech/QwenModelState.swift
Sources/flowtype/Settings/ASRModelStatusCard.swift
Sources/flowtype/Settings/CloudASRProviderList.swift
Sources/flowtype/Settings/LocalModelPicker.swift
Sources/flowtype/Settings/MainWindowView.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterEnvironment.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterHost.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterView.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift
Sources/flowtype/Settings/ModelCenter/ModelInstallationList.swift
Sources/flowtype/Settings/OnboardingView.swift
Sources/flowtype/Settings/OnboardingWindowController.swift
Sources/flowtype/Settings/SettingsDestination.swift
Sources/flowtype/Settings/SettingsPage+ASR.swift
Sources/flowtype/Settings/SettingsView.swift
Sources/flowtype/Settings/SettingsWindowController.swift
Sources/flowtype/Testing/ASRBackendRoutingSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterIntegrationSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterSelfTests.swift
Sources/flowtype/Testing/HFInstallTransactionSelfTests.swift
docs/superpowers/validation/2026-11-09-asr-model-center-acceptance.md
```


## C4 review fix round 1/5 — I1 / I2 / I3

Committed `f5dcd8d1a3ffbf746d8fc8a5f5ce1c655cff5e29` (`fix: restore model center discovery recovery and realtime trials`), base `c6e0efaed8561daaeed333a642b71765375e6314`. Full tree `b494fea0a0ceae55a2e6159b391727ceff61e495`; Sources tree `9d7710d18bb2491eab7eb1610972eca4a78dc964`. Seven explicitly staged source files, 361 insertions / 6 deletions; worktree clean after commit, `Package.resolved` unchanged. Controller approved the three Important findings and narrow existing-owner repair; no unrelated installer/native-domain rewrite, nested agent, push, merge, signing or live external effect.

### Implemented contracts

- **I1:** `LocalASRServiceDraftSession.discover` resolves `.new` + `.preserve` to nil without calling the saved credential lookup. `.existing` + `.preserve` still calls the strict saved lookup. Explicit replacement/removal is unchanged. Production environment/actions + injected URLProtocol exercise discover-before-save, exact GET/no body/no Authorization, discovered model, unchanged configuration/selection, and missing existing profile refusal without another request.
- **I2:** VM `unloadNative(_:)` and `reloadUnloadedNative()` share existing user-action admission and `NativeASRActivationCoordinator`. Confirmation captures exact loaded backend ID. Unload refuses busy native operation, stale identity, actual recording reservation and captured usage; it never stops recording. Existing Qwen gate performs release. Recovery retains stable backend ID, imported value metadata, selection and policy only, never a lease/provider. Records, files, selection and validation survive unload; failed candidate leaves actual active lease nil and old reload action available. Reload uses canonical sample + existing activation `.existingRole`. Recovery is invalidated by new loaded native runtime, role/consent/policy changes, removal/metadata changes, or old model no longer occupying the captured selected role. Obsolete runtime reload cannot overwrite a different selected native identity. UI shows hardware/import failure reason, explicit unload confirmation and temporary-unready warning, and old-model reload. Compatible hardware success text is not presented as a warning.
- **I3:** A5's admitted cloud DashScope trial now creates existing immutable `RealtimeASRConfiguration` (no context or context-derived language) and existing injected `RealtimeSessionFactory`/live factory, then uses existing `transcribeSavedRealtime` for start → <=1,600-sample appends → finish of canonical 16 kHz PCM. A5's owned task retains the sample worker; whole recognition deadline defaults to 15 seconds. On failure/cancellation/timeout it cancels worker, cancels ingress, awaits session cancellation and actual worker result before relinquishing A5 owner. Success also cleans up. Late success cannot override original timeout/cancel. Existing fingerprint/revision/credential-generation/nonempty-text/onVerified checks remain. Timeout maps to stable `timeout`; explicit configuration CHECK remains configuration-only and starts no realtime factory. Local-service realtime remains unsupported. The old DashScope test-only expectation was changed to configuration CHECK; new synthetic realtime integration verifies actual recognition and selection.

### RED and focused GREEN evidence

All build/test commands sequential; no source edits while any build/test ran. Logs below are relative to this report directory.

- RED build exit 0: `C4-fix1-red-build.log`; behavioral RED `C4-fix1-red-focused.log`: **297 passed / 16 failed**, specifically discovery transport, native unload/recovery and realtime selection/ownership.
- Initial implementation build exit 0: `C4-fix1-green-build.log`; `C4-fix1-green-focused.log`: **326/1**. Sole remaining failure was new regression fixture constructing an editor with manually replaced/stale revision; real save correctly rejected it. Fixture now edits the latest stored profile, keeping captured revision. Additional role invalidation cases and actual SwiftUI recovery previews were then completed.
- Final build: `C4-fix1-verified-build.log`, exit 0, **no emitted warning/error**. `git diff --check` clean.
- Final model center: `C4-fix1-verified-focused.log`, `--asr-model-center-only`, **331/0**.
- Backend/transport/credentials: `C4-fix1-backends.log`, `--asr-backends-only`, **1084/0**. This ran before the final display-only suppression of compatible hardware text and fixture preview background; A5/discovery code remained unchanged.
- M3 realtime/pipeline/native lifecycle: `C4-fix1-m3.log`, `--m3-asr-regression-only`, **294/0**.
- Native client: `C4-fix1-native.log`, `--native-client-only`, **960/0**.
- Recovery: `C4-fix1-m4.log`, `--m4-recovery-only`, **19793/0**.

New regressions prove actual recording/capture unload refusal, marker-file and complete configuration preservation, failed replacement truthfully nil, explicit old exact reload, stale confirmation refusal, selection/policy invalidation and obsolete-runtime role preservation. Realtime fixtures cover save-only behavior, configuration-only check with zero sessions, captured key/no language, exact canonical PCM and bounded chunks, start/finish/cleanup, fallback consent/selection, primary and switch-back, empty response preservation, cancellation holding both VM and A5 slots through uncooperative cleanup, timeout holding ownership and refusing late success, and profile/key replacement preventing stale selection/evidence.

Initial broader recompilations reemitted existing warnings in AudioDevice.swift (CFString raw pointer and unused nameResult), AudioRecorder.swift (deviceIDSize and captured inputConsumed), DownloadSource.swift (deprecated regionCode), and HFInstallTransactionSelfTests.swift:169 (captured reject mutation). None originate in this fix; final incremental build emitted none. No broad warning cleanup was undertaken.

### UI artifacts and limits

Four actual SwiftUI offscreen PNGs are retained in `C4-fix1-recovery-previews/`: `memory-refusal-light.png`, `memory-refusal-dark.png`, `unloaded-recovery-light.png`, `unloaded-recovery-dark.png`, each 480 × 700 points. Visually inspected memory-refusal-light and unloaded-recovery-dark: concrete memory reason, unload control, temporary-unready message, exact old model reload and footer actions render visibly without overlap in those fixtures. Initial transparent-background fixture captures were replaced with the normal page background; final captures come from final focused run `8EEED006-AA2A-49D4-9C23-E56D71730E27`. These are synthetic component renders, not real window/confirmation interaction/VoiceOver proof.

No full code gate rerun this fix round, as directed. Prior **28,205/0** gate applies only to `c6e0efa`, not this fix commit. Independent scoped review follows; final D3 planned verification remains downstream. All H1–H8 acceptance rows remain Pending. Real vendor/model/network/microphone/Keychain/user state, model quality, real window behavior, remote CI and signed/distributed artifact claims remain Pending.

Exact committed files:

```text
Sources/flowtype/Services/Speech/Backends/ASRServiceValidationCoordinator.swift
Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift
Sources/flowtype/Settings/ModelCenter/ASRModelDetail.swift
Sources/flowtype/Settings/ModelCenter/LocalASRServiceEditSheet.swift
Sources/flowtype/Testing/ASRBackendValidationSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterReviewSelfTests.swift
Sources/flowtype/Testing/ASRModelCenterSelfTests.swift
```
