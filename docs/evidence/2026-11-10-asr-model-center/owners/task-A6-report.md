# Task A6 implementation report

Latest status: **DONE**, scoped review round-2 N1 repair committed as `69691c018b9d4604b94ac011138db6ab4b70eec8` (tree `75ee3e8ebccc63a01e6ff98423e645cb10db65c9`). Latest build/backend **1,084/0** pass; UI unchanged in this round. Round-1 native check **953/0** belongs to `8002f16`. Full code lane was last verified on earlier `ff8ec91` (**26,935/0**); it was deliberately not repeated for scoped review fixes. Exact round-2 RED/GREEN evidence appears at the end under “Scoped review fix round 2”.

Original A6 base: `009ba44`; pre-review verified commit: `ff8ec9147000a4425fa197b88a895a059b021d47`.

## Scope and implementation

- Readiness builder now uses injected `backends: [ASRBackendDescriptor]` and `availableIDs: Set<ASRBackendID>`, pure selection/policy/internet filtering, and per-backend states. It never reads credentials, creates providers, probes services, scans model paths, or persists migration. An installed/global `.ready` status without actual available native identity is not ready; preparing/error states remain distinct. Loopback readiness does not require Internet.
- Runtime `ASRRouter.readinessBackends(currentValidatedServices:)` returns `(backends: [ASRBackendDescriptor], availableIDs: Set<ASRBackendID>)`. It captures current configuration/credentials but neither transcribes/probes nor reserves recovery/persists legacy resolution. A configured service binding alone never appears available for readiness. Successful current-process service evidence must match backend ID, revision and credential generation; changed revisions/keys, locked credentials and missing evidence are unavailable. Cloud retains existing configured/valid/credential-accessible semantics, now using the same endpoint/model/key validation as recognition. Native availability comes only from the actual active lease.
- Readiness snapshot retains descriptors, per-backend states, ordered ready IDs and selected stable ID. Menu labels identify the actual service/native/cloud backend. Pending legacy native intent can be represented in memory using actual injected loaded availability; explicit clear/unknown references remain intact.
- ASRStage records the winning immutable descriptor on SessionContext. `SessionController.historySession(context:durationMs:)` is shared by real production history saving and regression fixtures, so fallback identity/model/location survive subsequent route edits. Apple preview explicitly clears selectable identity and retains the existing Apple label/mechanism.
- DictationSession and SessionRecord gain optional `asrBackendID`, `asrModelID`, `asrLocation`. GRDB migration `v6_asr_backend_identity` adds nullable columns to the existing table. Old JSON/rows decode nil without rewriting original transcripts or unknown brands. Metrics count actual location, retain old cloud IDs, and group by captured backend/model/location.
- `.asrBackend(ASRBackendID)` preserves exact failed/capture-only/preflight backend identity; the existing ordered A4 capture failures and attempted-failure precedence remain intact. Preflight recovery captures selection before later edits. Old `.provider(UUID)`/`.localModels` remain valid. Legacy anchors resolve native/cloud references; services/unknown IDs safely open speech settings until model center composition. Unknown/legacy local history is never forced to Qwen.

## Exact C handoff

`ReadinessMonitor.init(currentValidatedServices: @escaping () -> [ASRServiceValidationRecord] = { [] })` composes the runtime source. **The default is empty**, so services remain unavailable for readiness until C4 owns and supplies current successful validation evidence, then calls `refresh()`. This API intentionally creates no new shared coordinator or persistent owner.

The similarly named `ASRServiceValidationRecord` can also represent persisted historical evidence elsewhere: **do not supply restored historical records after restart**. The C4 application owner must retain only current-process A5 successful recognition records and invalidate them with edits/cancellation/restart. A6 rechecks current binding revision and credential generation. C1/C4 still own the new-selection trial and UI flow; existing cloud configuration readiness is retained here. The production shared monitor currently uses the default empty source, pending C4 composition.

Pure builder inputs are caller-owned availability evidence, not proof derived from profile existence. Native producer must supply the actual active lease descriptor; readiness must not select an arbitrary discovered/imported/native row.

`ReadinessSnapshot` fields: `backends`, `backendStates`, `readyBackendIDs`, `selectedBackendID`; existing local/cloud/Apple aggregates remain compatibility views. `SettingsTarget.legacyASRTarget` provides temporary safe anchors while retaining the original navigation target.

## TDD evidence

Commands ran sequentially and sources remained frozen until each process exited. Logs are retained in this ignored task workspace. No competing builds or verification processes were used.

### Initial RED

`swift build > .../A6-red-build.log 2>&1` ultimately exited 0, `Build complete! (28.63s)` after fixing a test-only async GRDB closure compile issue. No production changes preceded the runtime RED.

`swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-red-backends.log 2>&1` exited 1: **937 passed, 7 failed**:

```
A6 offline selected loopback is ready: blocked(noEngine), want ready
A6 actual backend survives JSON and SQL: nil, want cloud:actual-fallback
A6 actual model survives JSON and SQL: nil, want actual-model
A6 actual location survives JSON and SQL: nil, want cloud
A6 metrics count actual cloud location
A6 service failure targets actual backend
A6 legacy local without brand does not force Qwen: qwen, want local
```

The initial offline fixture exercised the old selected-service slot failure using the existing API. After injection was implemented it supplies explicit validated availability and separately asserts a configured service without evidence is blocked. Persistence RED injected the new keys through JSON and exercised the real SessionRecord/GRDB boundary, avoiding a missing-symbol/compiler-only failure.

### Intermediate GREEN and resolved build errors

`A6-green1-build.log`: failed on test-only argument order and retired `localUsable` fixture call sites. Updated those fixtures to inject actual descriptors/availability rather than retaining a legacy production path. `A6-green2-build.log`: exit 0. `A6-green2-backends.log`: exit 0, **966 passed, 0 failed**.

### Follow-up RED: real metrics and preflight recovery

`A6-followup-red-build.log`: exit 0, `Build complete! (27.95s)` after correcting a test fixture's nonexistent `.memory()` KeychainAccess helper to explicit inert closures.

`A6-followup-red-backends.log`: exit 1, **974 passed, 2 failed**:

```
A6 metrics expose actual captured backend model and location
A6 preflight recovery retains blocked selection despite edits: settings(speech,nil), want asrBackend(future:selected-before-edit)
```

Implemented actual content-free metrics grouping and captured preflight navigation. `A6-green3-build.log`: exit 0, `34.39s`; `A6-green3-backends.log`: **976 passed, 0 failed**; `A6-green3-native.log`: **953 passed, 0 failed**.

### Follow-up RED: pending legacy readiness

`A6-legacy-red-build.log`: exit 0, `28.13s`. `A6-legacy-red-backends.log`: exit 1, **977 passed, 1 failed**, pending legacy intent with actual loaded availability incorrectly remained blocked. Fixed the pure in-memory view under the existing pending marker; explicit clear still blocks.

`A6-final-build.log`: exit 0, `30.75s`; `A6-final-backends.log`: **978 passed, 0 failed**; `A6-final-native.log`: **953 passed, 0 failed**.

A controller-requested final ambiguity guard was verified separately before freezing source; its RED/GREEN evidence is recorded below.

## Initial verification checklist

The original sequence was final ambiguity RED/GREEN, named backend/native/M3 checks, stable commit and one code lane verification on that frozen commit. Those completed; the first code gate exposed a legacy fixture issue. The controller-authorized fixture fix and necessary second code gate are recorded below with both source identities preserved.

## Self-review and limitations

Reviewed actual winner capture, late config edits, Apple preview, ordered capture diagnostics, endpoint validation, credential generation matching, policy/consent/internet filtering, old-record nil defaults, additive old-v5 upgrade and safe unknown navigation. Existing large ASRRouter/PipelineOrchestrator/SelfTest files were changed locally without unrelated restructuring.

The tests use in-memory credential stores, explicit inert legacy Keychain closures, synthetic descriptors/PCM, injected providers and in-memory GRDB queues. No real service, cloud request, native model inference, microphone, permissions, clipboard, user config/model/secret path, or real Keychain migration was performed. Package.resolved is unchanged. No subagents, push, merge, release or signing operation.

Real service/vendor/native/microphone/manual/signing checks remain **Pending**. The code lane cannot establish them. B installer and C model center implementation are outside this task. Controller owns the required fresh review over the complete A range.

## Final ambiguity RED/GREEN and frozen source

`A6-ambiguity-red-build.log`: exit 0, `Build complete! (31.29s)`. `A6-ambiguity-red-backends.log`: exit 1, **978 passed, 2 failed**. Both `[native, otherNative]` and reversed descriptor orders wrongly selected a pending native by array order. Final guard requires exactly one injected available native descriptor; the production projection supplies only its actual active lease descriptor. No native model discovery or arbitrary row selection occurs.

`swift build > .../A6-stable-build.log 2>&1`: exit 0, `Build complete! (29.54s)`. `swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-stable-backends.log 2>&1`: exit 0, **980 passed, 0 failed**. Tracked source is frozen after this guard; remaining verification runs on the same source.

## Changed files

Production: Core/Database/{AppDatabase,Records}.swift; Core/DictationHistory.swift; Core/Pipeline/SessionContext.swift; Core/Pipeline/Stages/ASRStage.swift; Core/PipelineOrchestrator.swift; Core/Readiness/{ReadinessMonitor,ReadinessSnapshot}.swift; Core/SessionMetrics.swift; Services/Speech/ASRRouter.swift; Settings/{ReadinessPresentation,SettingsDestination,SettingsPage+ASR,SettingsView}.swift.

Tests: Testing/{ASRBackendRoutingSelfTests,CloudProviderSelfTests,ImportedLifecycleSelfTests,ModelProvisionSelfTests,NativeRecoveryNavigationSelfTests,SelfTest}.swift. Existing readiness fixtures now inject explicit synthetic availability; existing native recovery fixture expectations target the exact represented binding ID and retain the legacy provider/local target tests. No dependency, Package.resolved or installer/model-center files changed.

## Decisions and provenance

Controller ruled that service construction must not imply recognition verification. A6 therefore admits only current-process validated evidence; C4 owns its later application composition. Controller explicitly approved the pending-legacy readiness normalization fix and required deterministic actual-native identity rather than arbitrary descriptor order. The extra guard and both-order RED→GREEN evidence satisfy that constraint. No broader source refinements followed.

## Stable commit and named GREEN checks

Final source commit: **`9f274567b569c71cea4a09fd07f95250a7c17c2d`** (`9f27456 feat: expose actual ASR backend readiness and history`), 20 explicit task files, 410 insertions/91 deletions. `git diff --cached --check` passed before commit; worktree was clean before launching the code gate. No tracked files have changed during verification.

Sequential final commands on this source:

```
swift build
swift run --skip-build FlowType --self-test --asr-backends-only
swift run --skip-build FlowType --self-test --native-client-only
swift run --skip-build FlowType --self-test --m3-asr-regression-only
```

All exited 0: build `29.54s`; backend **980 passed, 0 failed**; native client **953 passed, 0 failed**; M3 ASR regression **292 passed, 0 failed**. Full outputs: `A6-stable-build.log`, `A6-stable-backends.log`, `A6-stable-native.log`, `A6-stable-m3.log`.

The single required `scripts/verify.sh --lane code` was started after the stable commit, with all tracked files frozen. Full wrapper output is `A6-code-gate.log`; final status/source record will be appended when the process exits.

## First code gate failure and justified fixture-only fix

The first and initially sole code-gate run exited **1**. Report: `build/verification/972DBEAF-45D6-43C5-82DD-E515DFD29F67/verify-report.json`. Preserved source identity: `gitSHA=9f274567b569c71cea4a09fd07f95250a7c17c2d`, `sourceTree=bb82274170df6d5eaa73902f9feb0402a19bbda5`, `dirty=false`. `source-start`, all platform phases, `code-build`, and `source-end` passed. `code-full` failed `fullTestFailed`: **26,927 passed, 3 failed**:

```
capture entry: production boundary reserves recovery
capture entry: concurrent callers cannot duplicate reservation
capture entry: successful recovery restores cloud
  got cloud:<actual profile UUID>, want cloud-asr
```

Exact cause: the production-entry subsection of `SelfTest.testHealthRecovery` still passed `localAvailable=true` with no injected `localLease`, so it could not produce a native binding. It also recorded failures under obsolete `cloud-asr`, which does not address the captured `cloud:<profile UUID>` versioned health key, and used legacy `isHealthRecovery`/slot assertions instead of actual captured binding order. This was an A4 fixture handoff missed by its focused runner; no production regression was inferred or patched.

Controller approved fixture-only conversion and one necessary code-gate rerun after a fresh stable commit. Added `testHealthRecovery` **only** to the `--asr-backends-only` branch; full runner still invokes the group exactly once. `A6-gatefix-red-build.log`: exit 0, `35.31s`. `A6-gatefix-red-backends.log`: exit 1, **1,025 passed, 3 failed**, independently reproducing the same full-gate failures before conversion.

Converted only the fixture subsection: explicit actual native lease, stable selected cloud/native IDs, in-memory credentials, no persistence callback or global local-lease source. It records failures/success under the captured actual cloud UUID. Assertions require exact cloud/native order for one reserved recovery, exact native/cloud order and retained lease for all eight concurrent callers, and exact cloud/native order after success. Late-probe/stale-failure checks now inspect current versioned health and exact route order for the replacement model, preserving their original intent without relying on legacy diagnostics. Forced-policy zero-probe assertions remain.

`A6-gatefix-green-build.log`: exit 0, `Build complete! (33.11s)`. Focused GREEN and fixed commit/code-gate results follow below. Controller explicitly directed no unchanged native/M3 repeat for this `SelfTest.swift`-only conversion; the already recorded native/M3 production-source checks stand, and final full gate rechecks all full-run groups.

## Fixture fix GREEN and final stable commit

`swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-gatefix-green-backends.log 2>&1`: exit 0, **1,033 passed, 0 failed**. The additional focused assertions are the existing health group plus exact current-binding checks; full invocation count remains once.

Fix commit: **`ff8ec9147000a4425fa197b88a895a059b021d47`** (`ff8ec91 test: capture versioned ASR health recovery bindings`), only `Testing/SelfTest.swift`, 50 insertions/25 deletions. Production source is unchanged from `9f27456`. Cached whitespace check passed and the worktree was clean.

The controller-authorized necessary second `scripts/verify.sh --lane code` runs on this fixed stable commit; wrapper output `A6-code-gate-fix.log`. All tracked files remain frozen until it exits. The first failed code-gate report and logs remain intact as evidence; its result is not overwritten or presented as a pass.


## Final code gate PASS and exact verified source

The necessary second `scripts/verify.sh --lane code > .../A6-code-gate-fix.log 2>&1` exited **0**:

```
build/verification/3306EA34-08E0-4DD3-9D0F-787F1FEB8733/verify-report.json
Verification code: Pass
=== self-test: 26935 passed, 0 failed ===
```

All seven phases **Pass**, exit 0: `source-start`, `platform-os`, `platform-arch`, `platform-swift`, `code-build`, `code-full`, `source-end`. Verified identity:

```
gitSHA: ff8ec9147000a4425fa197b88a895a059b021d47
sourceTree: 4f3a68429487af62a0ff6618d5e46eec438e700e
dirty: false
```

No tracked file was edited during either code-gate run. Final `git status --short` is empty; HEAD is the exact verified commit above, and `git diff --check` passes. Only ignored reports/logs were written after verification. Both initial failure and final success remain reviewable, rather than substituting focused fixtures for the full lane.

Final commit range for task review: `009ba44..ff8ec91`; implementation commit `9f27456`, fixture fix `ff8ec91`. Controller owns the required fresh review over the **whole A range**, not just this final task range. No subagent reviewer was spawned.

No unresolved automated test or code-gate failure remains. C4's current-process service-validation composition is intentionally pending by controller ruling (default empty evidence); actual native/service/vendor/microphone/manual/signing/artifact/release validation remains Pending and is not established by this code gate.

# Whole-A review fix — I1 legacy controls and M1 descriptor limit

Status: **DONE**, scoped review pending. Base: `ff8ec91`; commit: `8002f16 fix: synchronize legacy ASR settings with backend selection`. The earlier full-code-gate Pass belongs to `ff8ec91`, **not** this changed source. Per controller direction, no automatic full-gate repeat was performed for this scoped repair; final build/backend/native evidence is below.

## I1 cause and implementation

Whole-A review found that legacy cloud-list activation/deletion and policy controls changed legacy flags/policy while production capture correctly honored `asrBackendSelection`. This could display B selected while sending the next recording to A, or leave policy changes with zero compatible bindings. Generic save/restart remigration would incorrectly revive explicit clears, so no save observer or unconditional migration was introduced.

Added a 94-line pure action domain, `ASRSettingsAction`, and `ConfigurationStore.applyASRSettingsAction(_:activeNativeID:)`. Store action application persists the entire candidate configuration before publishing; failure leaves prior configuration and display flags intact. The pure domain uses the centralized explicit-selection setter, preserving identity and consent atomically.

- `.activateCloud(UUID)` explicitly selects that stable cloud UUID and updates legacy flags. It preserves the existing noncloud role/fallback and upload consent. Local-only activation or two occupied noncloud roles returns a visible conflict with no mutation.
- `.changePolicy(ASRRoutingPolicy)` uses a currently selected compatible role, or an exact configured imported/preset native reference/actual active native lease, or the **single explicitly flagged** active cloud profile. It never uses `activeProvider`'s first-row fallback. No intended compatible reference yields a conflict and unchanged configuration. It preserves unrelated occupied roles rather than evicting one. Auto can restore an explicitly configured native fallback but cannot grant cloud fallback consent.
- `.deleteCloud(UUID, confirmSelected:)` requires confirmation for either selected primary or fallback. It retains the exact now-unavailable selected reference, removes only the profile/legacy key association, never promotes another row and never removes committed credentials already held by in-flight captures.
- Cloud list selection badges now derive from authoritative primary identity. Activation/deletion use the store action; selected deletion has explicit confirmation and a visible unavailable-choice explanation. Check owners synchronize only after successful persistence.
- Existing mode picker uses the same action and shows rejected-action messages while leaving policy/selection unchanged. The existing recovery “use automatic routing” action also uses it; conflicts retain the current recovery card and navigate to its settings destination. No new model-center page or replacement-selection flow was built.
- Generic settings saves, draft saves and restart remain unchanged. Explicit cleared selection is not resolved from legacy model or active-provider fields by unrelated actions.

M1: captured cloud descriptors now use `CloudASRVendor.maxUploadBytes(for:)`, matching the existing request builder's known upload bound; a literal 25,000,000-byte OpenAI captured-descriptor assertion covers this.

## RED evidence before implementation

Added a store/action → real capture fixture with isolated defaults, inert legacy Keychain closures, in-memory ASR credentials, exact native lease, synthetic providers and no network/microphone/model access. Initial compile-only fixture issues (recognition closure Result type and Swift 6 actor-isolated cleanup) were corrected **before runtime RED** and are not counted as behavioral evidence.

```
swift build > .../A6-review-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-review-red-backends.log 2>&1
```

Build exit 0, `29.78s`. Focused exit 1: **1,035 passed, 6 failed**:

```
I1 explicit activate B routes next capture to B: got exact A/native, want exact B/native
I1 activation survives restart: got exact cloud:A, want exact cloud:B
I1 delete selected A never promotes arbitrary B: got remaining B active, want no active rows
I1 localOnly to cloudOnly uses explicit active cloud: got [], want exact cloud:A
I1 cloudOnly to localOnly uses exact configured native: got [], want native:preset:action-native
M1 captured known OpenAI upload bound is exposed: nil, want 25000000
```

After implementation, `A6-review-green1-build.log` exit 0 `46.01s`, `A6-review-green1-backends.log` exit 0 **1,041 passed, 0 failed**.

## Occupied-role edge RED/GREEN

Expanded behavioral coverage for required deletion/consent/clear/persistence boundaries. `A6-review-edge-red-build.log` exit 0 `28.06s`; `A6-review-edge-red-backends.log` exit 1 **1,060 passed, 2 failed**:

```
I1 changing mode cannot silently evict an occupied unrelated fallback
I1 occupied roles conflict preserves complete configuration
```

The action incorrectly replaced an explicit service fallback while selecting a configured cloud profile for cloud-only. Fixed the minimal conflict guard: a new role cannot enter when two distinct explicit slots are occupied. Existing compatible-role swaps retain the other slot, and nil-primary cases cannot duplicate fallback. No broader implementation refinements followed.

## Final GREEN on committed source

All checks ran sequentially with tracked source frozen until process exit:

```
swift build > .../A6-review-final-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-review-final-backends.log 2>&1
swift run --skip-build FlowType --self-test --native-client-only > .../A6-review-final-native.log 2>&1
```

Exit 0 for all: build **27.99s**; backend **1,062 passed, 0 failed**; native client **953 passed, 0 failed**. `git diff --check` and cached whitespace check pass. No unresolved focused failure; no new real-service/manual acceptance claim. No full gate was run for this review fix by explicit controller direction; the next integration phase owns a fresh full gate on its final source.

Regression coverage verifies: exact action-B → next-capture B/native; prior capture A and its immutable bindings remain unchanged; restart retains B; primary deletion confirmation and retained missing ID; fallback confirmation/deletion with no cloud upload or replacement; unrelated deletion preserves both roles and consent; local/cloud policy transitions both directions; local-only activation conflict; all-inactive cloud rows cannot become arbitrary first replacements; auto restores exact configured native fallback; auto from local primary cannot authorize cloud fallback; occupied-role conflict is atomic; unrelated appearance/language save plus restart preserves explicit clear; failed action persistence retains prior flags/route; known upload limit survives capture.

## Files and self-review

Explicit task files: Core/ConfigurationStore.swift; Core/PipelineOrchestrator.swift; Services/Speech/ASRRouter.swift; new Services/Speech/Backends/ASRSettingsAction.swift; Settings/{CloudASRConnectionCheck,CloudASRProviderList,SettingsPage+ASR}.swift; Testing/{ASRBackendSelfTests,CloudProviderSelfTests}.swift; new Testing/ASRSettingsActionSelfTests.swift.

Self-reviewed pure action mutation staging, explicit role selection, deterministic single-active cloud behavior, two-slot conflict, consent preservation, selected deletion confirmation, immutable credential/in-flight capture retention, visible rejected-action state, generic-save clear preservation and code/test registration. Existing cloud ownership fixture now asserts deletion does **not** arbitrarily activate a remaining row. No dependency/Package.resolved changes, subagents, real user state, push, merge or installer/model-center scope.

Controller explicitly approved the action semantics and requested a fresh scoped review after this commit. Prior A6/C4 current-process service evidence handoff and all real/manual Pending limitations continue to apply.

Final review-fix source: `8002f16e2f5549dfe1b80ef8428edeea76207771`; tree `0c3f28039d6c4036febd0da691e86a27ae6afda9`; `git status --short` empty.

# Scoped review fix round 2 — N1 pending native intent

Status: **DONE**. Review source: `task-A6-rereview1.md`. Base: `8002f16`; fix commit **`69691c018b9d4604b94ac011138db6ab4b70eec8`** (`69691c0 fix: retain pending native intent across cloud edits`), tree **`75ee3e8ebccc63a01e6ff98423e645cb10db65c9`**. Only `Services/Speech/Backends/ASRSettingsAction.swift` and `Testing/ASRSettingsActionSelfTests.swift` changed; 71 insertions/2 deletions. Final worktree clean.

## Cause and scoped repair

The round-1 action domain unconditionally called `setASRBackendSelection`, whose explicit-selection contract clears `pendingLegacyNativeResolution`. Deleting an unselected cloud row changed no native role but persisted an explicit clear of unresolved path/automatic native intent. The same issue affected confirmed deletion of a cloud primary with a still-pending native fallback and cloud-primary activation while that native fallback remained unresolved.

The action now compares the original selection/policy with its resulting selection. For **cloud deletion or activation only**, it preserves an already-true pending marker when the original policy is unchanged and the unresolved native role remains nil: auto fallback or local-only primary. The selection is updated directly in this narrow non-native-edit branch; explicit policy/selection operations still use the centralized explicit-selection setter. This does not manufacture a pending marker, revive explicit clear, or preserve a marker after native intent was replaced. No generic-save/restart/router behavior or UI flow changed.

## RED evidence

Added store → migration → action → restart → actual lease capture/persist regressions before production changes:

```
swift build > .../A6-N1-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-N1-red-backends.log 2>&1
```

Build exit 0, **30.41s**. Focused exit 1: **1,068 passed, 10 failed**. Auto and local-only unrelated-cloud deletion each lost the pending marker before/after restart and could not resolve/persist the exact later native lease ID. Auto activation of B likewise lost pending native fallback and captured only cloud B after restart.

Controller requested the same boundary for confirmed deletion of selected cloud A while native fallback is pending. Added that case before production changes, reran:

```
swift build > .../A6-N1-primary-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-N1-primary-red-backends.log 2>&1
```

Build exit 0, **30.33s**. Focused exit 1: **1,070 passed, 14 failed**. Four extra failures reproduced loss of pending marker, persisted marker and actual native fallback resolution after deleting the cloud primary. Existing explicit-clear assertions remained green throughout RED.

## GREEN evidence on final committed source

```
swift build > .../A6-N1-green-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .../A6-N1-green-backends.log 2>&1
```

Both exit 0: build **31.04s**, focused **1,084 passed, 0 failed**. Tracked files stayed frozen until each command exited. `git diff --check` and `git diff --cached --check` passed before commit. No source edits followed GREEN.

The regression table covers migrated `auto [cloud:A,nil]`, migrated `localOnly [nil,nil]`, unrelated cloud B deletion, selected cloud A deletion with explicit confirmation, restart before any native lease, and subsequent capture with an injected actual native lease that persists the exact native identity and clears the marker only after resolution. Auto activation selects B while retaining the unresolved native fallback. A later explicit clear followed by cloud deletion/restart/capture still has no candidates or pending intent. This exercises real ConfigurationStore persistence and ASRRouter capture with isolated defaults/in-memory credentials/synthetic lease only.

No UI changes, native-client rerun or full suite/code gate per explicit controller scope. The latest full-gate Pass remains the earlier `ff8ec91` result; it is not claimed for this changed source. No subagents, dependency change, real Keychain/config/model/microphone/network/user-state operation, push or merge. Manual/real service/native checks remain Pending.
