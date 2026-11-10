# Final whole-branch review — D3 step 1

Reviewed base `aacf49a84d66609c57f9d3809624a08ca95fa79c` through `94283b7` using the controller-supplied `review-aacf49a..94283b7.diff` (38 commits, 168 files), requirements, progress rulings, scoped reports, and current source. This is one risk-based review in multiple passes, not a claim to have checked every assertion in every test. No implementation, index, HEAD, or branch changes were made; no tests or external operations were run. This report is the only review output written.

## Strengths

- Runtime routes capture actual backend identity, revision, and credentials for a session. Explicit primary/fallback selection and cloud consent remain visible at the model-center boundary; history uses the actual recognition backend.
- Native activation checks offline resources and admission before allocation, validates before persistence, and transfers ownership through leases. Captured usage tokens and inference drains protect active models against removal.
- Installation pins source/commit/file closure, checks digests and Range responses, and separates staging from publication. Resume journals, publication permits, cancellation generations, and guarded partial cleanup address interruption and ownership hazards.
- The model-center environment lives at application scope. Production settings, onboarding, and recovery entry points reach the same model; views do not independently own downloaders or runtimes.
- Distribution verification handles producer failures, verifies source/cancellation before publication, and restores the previous DMG if report writing fails. It checks submitted bytes, fresh Apple notarization records, and signed extracted/mounted contents instead of accepting a prior success label.
- Test coverage includes routing/credential identity, delayed validation, native ownership, install recovery/cancellation, and verification failures. Dependency locks were not changed; the package resource addition is the validation sample.

## Issues

### Critical

None found in the reviewed implementation.

### Important — I1: a healthy selected local service becomes recording-blocked after 60 seconds

**Locations:** `Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift:381`, `Sources/flowtype/Services/Speech/ASRRouter.swift:476`, `Sources/flowtype/Core/Readiness/ReadinessMonitor.swift:85`, `Sources/flowtype/Core/Readiness/ReadinessSnapshot.swift:71`, `Sources/flowtype/Core/PipelineOrchestrator.swift:275`.

**Trigger:** Select a working local service as the only eligible backend, use `localOnly`, complete its explicit sample Test, and wait at least 60 seconds without changing the service or its credentials. Attempt dictation while the service remains running.

**Cause and consequence:** `currentValidatedServices` removes matching evidence at 60 seconds. `readinessBackends` then excludes the loopback binding, the snapshot marks it unavailable, and the readiness classifier produces `.blocked(.noEngine)`. Recording preflight returns before capture. The application clock refreshes this state every second (`ASRModelCenterEnvironment.swift:79`). The user must repeat the sample Test to regain another short recording window, even though the production router could still attempt the selected service and no real request failed.

This conflates freshness of the “ready” presentation with permission to attempt the configured backend. The experience specification explicitly says results older than 60 seconds display “上次验证” and the next real request still handles unavailability (`docs/superpowers/specs/2026-11-09-model-center-experience-design.md:25`).

**Suggested fix:** Separate admission to a real attempt from fresh live-ready presentation. Keep the 60-second label transition, explicit Test-before-selection, and revision/credential invalidation. Expiry alone must not deny a recording attempt for this already validated, unchanged selection. Preserve ordinary runtime error handling if the service has actually stopped.

**Verification gap:** `ASRModelCenterIntegrationSelfTests.swift:92` checks expiry and an empty live-evidence set, while the runtime-readiness integration starts at line 102. Neither composes expiry with recording preflight. Add a focused regression exercising that composition: after 60 seconds the row is historical, an unchanged selected local service can be attempted, and edits/credential changes still invalidate the relevant evidence.

### Minor — M1: new cloud draft configuration checks require a nonexistent saved credential

**Locations:** `Sources/flowtype/Settings/ASRProviderEditSheet.swift:237`, `Sources/flowtype/Settings/ModelCenter/ASRModelCenterView.swift:222`, `Sources/flowtype/Settings/ModelCenter/ASRModelCenterEnvironment.swift:48`.

**Trigger:** Add a new cloud provider, enter valid fields and a replacement API key, then click “检查配置”. An existing provider whose old credential is unavailable also encounters this when explicitly replacing or removing its key.

**Cause and consequence:** The sheet calls the throwing `storedKey()` closure before `ASRProviderDraftSession.effectiveKey` can use the draft edit. The production closure resolves credentials only for saved profiles; the new UUID is absent and throws `invalidData`. The sheet maps this to a misleading Keychain-unavailable message, so every new cloud draft fails this otherwise local configuration check even with a supplied key. Saving and testing the saved backend remain available, so this does not block the overall setup path.

**Suggested fix:** Resolve draft key intent before reading storage. A nonblank `.replace` uses the entered value without a saved-key lookup; `.remove` uses an empty key; a new draft with `.preserve` has no saved key and uses empty; existing `.preserve` reads storage and retains genuine lookup errors. Preserve the current blank-replacement fallback semantics by treating blank replacement like preserve for the relevant new/existing target. Cover new drafts and replacement/removal when a saved-key accessor throws, without swallowing an existing-preserve error.

## Known observation adjudication

The DashScope termination observation was independently inspected, including `DashScopeRealtimeASR.swift:243`, `WebSocketTransport.swift:70`, and the realtime validation adapter. `terminate` sets terminal before awaiting transport close; repeated cancellation returns immediately, and canceled receiver/sender task handles are discarded rather than joined. Resolving start/audio waiters before close also means awaiting the adapter worker and a repeated cancel is not proof that every internal actor task has drained. An actor hop remains a suspension boundary even though the current production `close` body has no internal await.

This is a real lifecycle-proof limitation, but **not a demonstrated merge-blocking defect in the current production route**. Terminal checks, ingress/task cancellation, URLSession socket cancellation, and separate transports per session prevent an identified path to late transcript publication, stale selection, or additional audio in the reviewed chain. Injected-session tests do not establish strict actor-internal joining, and this review makes no such claim. If strict close/join semantics are required later, retain and await a shared cleanup completion rather than relying on repeated cancel. This disposition is based on current ownership and cancellation behavior, not on the prior scoped ruling alone.

The captured-mutation warning in `HFInstallTransactionSelfTests.swift:169` is recorded as baseline evidence, not an introduced production regression. Silence in an incremental build does not establish a warning-free clean build.

## Coverage and verification evidence

Production passes covered schema/migration and credential transactions; routing, fallback, readiness, capture, ASR stage and history; loopback validation/DNS pinning/TLS/response boundaries; validation coordinator and model-center UI wiring; native factories, activation, leases and deletion; HF resolution/planning/download/journals/publication/recovery; acceptance and distribution verification/CLIs; packaging, smaller production integrations, and sample loading/licensing. Selected tests and their registration were inspected for these integration risks. Existing scoped reviews were supporting evidence, not immunity from findings.

- The controller records a full code gate at `c6e0efa`: 28,205 passed, 0 failed; seven phases Pass; Sources tree `a54eed31ccff11d9ec8605f27f0eb152d084c867`. This predates later changes and is **not** a final-head pass.
- C4 `f5dcd8d` recorded focused counts: model center 331/0, A 1,084/0, M3 ASR 294/0, Native 960/0, M4 recovery 19,793/0. D2 `74e894e` recorded new 91/0 and outer 200/0 including the nested 91.
- Directly inspected D4 log tails show the intended failure-before-fix evidence in `build/D4/fix1-RED.log` (47 passed, 9 failed), `fix1-GREEN.log` (56/0), and `fix1-GREEN-verification.log` (D2 91/0, D4 56/0, combined 219/0). The CLI fixture exit-status line is present. These support D4, not all runtime changes or real release execution.
- No tests were rerun merely to reconfirm those records. A final code gate and applicable artifact/release gates remain the controller's work after this review and its fix wave.

## Declined to judge / pending external evidence

**Behaviors set aside solely as outside the plan or specification: none.** Reasonable user behavior was considered even where the specification was silent.

The following judgments remain unmade because the review is read-only and the required external execution was prohibited or unavailable. They are explicit release-evidence gaps, not assumed code failures:

1. Actual cloud-vendor recognition, streaming behavior, accuracy, latency and account compatibility: no real vendor requests, credentials, billing, or network execution.
2. Actual supported native-model loading, recognition quality, memory/Metal behavior and resource estimates on target hardware: no real model download, allocation, or inference.
3. Actual local-service compatibility, startup/loss/recovery and authentication across supported servers: no service processes or live probes. The I1 finding is established by the source admission chain, independently of live server behavior.
4. Real HF transfer/resume under redirects, interruption, disk pressure and provider responses: no downloads or external network. Fixtures establish deterministic branches, not real provider behavior.
5. Actual macOS Keychain permission, lock/unlock, migration and recovery experience: no user credentials/configuration or permission changes; only source and existing fixture evidence reviewed.
6. Original 41 and new 30 manual cases, H1–H8, keyboard/VoiceOver/window accessibility and visual behavior, microphone/capsule/clipboard/permission flows: no interactive acceptance or user-device side effects. Source wiring is not a manual Pass.
7. Remote CI result and compatibility on its actual runners: no remote CI execution or fresh remote result was obtained.
8. Real Developer ID signing, notarization submission, authenticated Apple result, quarantine/DMG mounting and clean-machine installation/update: no signing/notary/mount actions. Distribution fixtures and code inspection cannot certify a released artifact.

## Verdict

**Merge readiness: with fixes, not ready as reviewed.** Fix I1 before merge, address the small M1 defect in the same permitted fix wave, then perform the controller's scoped rereview and final code/artifact gates against the resulting commit. No critical defect was found, but the earlier full gate cannot certify this head or subsequent fixes.

**Release readiness: No / Pending.** The actual model/vendor/service/manual/remote-CI/signing/notarization/clean-machine evidence listed above remains pending. A successful fixture gate or merge decision must not be represented as release acceptance.
