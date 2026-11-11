# Fresh scoped fix review

Date: 2026-11-11. Base: `6e0f09f5a3480a7dfd0ca9791f40838d4e940cb9`. Reviewed HEAD: `aa5d037c316d03d543b3f3f424cbc16b9e44f325`.

Read the original report, fix brief, final fix report, supplied fix-range diff, changed production code and relevant surrounding owners/transports/tests. This is the requested four-finding fix review and regression review of that diff, not a fresh whole-branch audit. Source, index and HEAD remained read-only; only this report was written. No tests were rerun, no child agents were used, and no real models/services/network/credentials/user configuration/microphone/clipboard/permissions/signing/notarization were accessed.

## Strengths

- Recovery now follows the existing selected-candidate routing and identity isolation instead of introducing a separate probe transport. The bounded attempt preserves time for fallback.
- The model-center VM owns cancellation intent through its actual domain task, with captured UUID cancellation handles. It waits for native/service work rather than freeing the UI operation slot at cancellation request time.
- Relocation is a distinct action and uses the existing native validation/persistence/lease transaction. Add-only acquisition stays add-only. The legacy association correction preserves the role slot and imported UUID.
- The production policy view reuses the existing privacy presentation and navigation. The inspected light-mode fixture image visibly contains the disclosure and text-management link without overlap.

## Original finding disposition

### I1 — ADDRESSED

`ASRRouter.swift:592` removes the cloud-only restriction after eligibility, consent and credential filtering. It retains monotonic recovery reservation in `ASRBackendHealthStore.swift:94`; the captured route marks the attempt at `ASRRouter.swift:607`. `ASRStage.swift:98` caps it to the existing stage timeout, five seconds and half the remaining shared completion budget. Healthy fallback therefore no longer permanently hides a repaired loopback/native primary; no extra candidate or hidden audio request is introduced.

Explicit recovery captures the eligible binding key and verifies the current key again (`ASRRouter.swift:613`). The health-store completion compares a captured mutation epoch under the lock (`ASRBackendHealthStore.swift:54`); success/failure/probe/network invalidation advance the relevant epoch. Actual model-center validation calls the completion only after successful native Test or exact current service/cloud validation and durable evidence (`ASRModelCenterViewModel.swift:338`, `:377`, `:386`). Historical onVerified callbacks do not directly clear router health. Native activation continues to acquire a fresh lease revision.

Reviewed regression coverage includes actual router → stage → health service/native recovery, monotonic cooldown, a cancellation-ignoring timed-out attempt preserving fallback budget, production environment Test recovery, a newer failure, revision replacement and credential-generation replacement. The accepted slow-primary limitation is accurately disclosed: a model slower than the bounded automatic recovery attempt may need explicit successful Test.

### I2 — ADDRESSED

`ASRModelCenterViewModel.swift:62` exposes a cancellation handle bound to one UUID. `:72` owns the task, guards a canceled pre-start action and retains admission until task completion. An old handle cannot cancel a successor. The real environment passes this handle (`ASRModelCenterEnvironment.swift:117`), and the busy view renders both an available Escape/cancel action and a separate draining label (`ASRModelCenterView.swift:75`). Closing the window still does not cancel the application owner.

Checked the underlying, unchanged domain guarantees instead of assuming Task cancellation implied drain. Qwen's `execute` cancels its captured worker and ID-guards the asynchronous owner cancel (`QwenModelState.swift:184`); native loading awaits the actual worker (`:958`), validation awaits worker/watchdog/provider drain (`:826`), and ownership/generation checks precede the synchronous persistence and lease swap (`:534`). A5 retains its transport owner while awaiting the recognition operation and suppresses canceled publication (`ASRServiceValidationCoordinator.swift:167`). Production batch transport awaits URLSession byte consumption and propagates cancellation; realtime validation cancels the session and joins its worker (`:69`).

The new tests cover environment/UIActions cancellation during an uncooperative service call, old handle versus new work, unchanged evidence/roles, and native Test/primary/fallback cancellation while loading ignores cancellation. No supported new cancellation/drain defect was found in this scoped diff.

### I3 — ADDRESSED for the original Important recovery defect; new Minor R1 remains

Production external detail now reaches a separate relocation preview (`ASRModelDetail.swift:108`, `:168`). The VM passes the original UUID to `stage(directory:replacing:)` and requires the exact preview and captured installed records (`ASRModelCenterViewModel.swift:425`, `:436`). Inspection captures and rechecks the original model and association (`ImportedASRModelActions.swift:45`, `:58`).

`QwenModelState.swift:413` checks same UUID, original model equality, managed/ambiguous ownership, canonical path aliases, capture/drain occupancy and recording admission. The load and final-generation boundaries repeat the checks (`:631`, `:881`); fingerprint/engine/tokenizer checks bind the inspected candidate. Validation and persistence complete before the selected active lease changes (`:534`, `:552`). Unselected relocation takes the trial-only persistence branch and preserves the unrelated active runtime (`:542`). Fail/cancel/persistence refusal preserves the old record, roles and lease.

Legacy relocation clears `legacyPresetID`, preserves the original imported UUID and maps only the exact old preset role to the imported identity within the persisted configuration (`:746`). Ordinary external role IDs remain unchanged. This meets the original same-UUID relocation requirement; however, the UI focus does not follow the new legacy-derived backend ID, as detailed below. The controller's explicit focus requirement is therefore not fully satisfied yet.

### M1 — ADDRESSED

The production policy summary derives `policyDisclosure` directly from `SettingsPrivacyPresentation.make(config:).localPolishDisclosure` (`ASRModelCenterView.swift:65`) and renders its copy and manage-text action (`:131`). The action navigates to `.settings(.text)` (`:24`). Existing conditions remain exactly local-only ASR plus enabled polishing; no new privacy semantics are introduced. Tests use the actual view's property and production environment action across all policy/polish combinations, and the archived component render supports the layout claim. This does not establish real keyboard/VoiceOver interaction acceptance.

## New issues

### Critical

None found in the scoped fix diff.

### Important

None found in the scoped fix diff.

### Minor

#### R1 — Successful legacy relocation leaves detail focused on the old preset

- **Changed location:** `Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift:444` (successful relocation continuation); related new UI path `Sources/flowtype/Settings/ModelCenter/ASRModelDetail.swift:171`.
- **Trigger:** Open an external legacy-associated preset row, relocate it through the new preview and complete validation successfully. Its backend changes from `native:preset:<preset>` to `native:import:<same UUID>` under the accepted B6 mapping.
- **Evidence:** `relocatePreview` awaits the transaction, clears the preview and refreshes, but never updates `selectedID`. The detail-sheet continuation also only dismisses and invokes relocation. `refresh()` always keeps built-in preset rows (`ASRModelCenterViewModel.swift:162`) and only clears selection when its row disappears (`:191`). Consequently the old preset ID survives as the selected detail, now normally showing “未安装,” while the relocated row and current runtime exist under the imported ID.
- **Impact:** The user remains on the wrong model detail after a successful repair and cannot see its updated path/status there. Roles, persisted UUID and active lease are correct; this is a navigation/feedback defect, not data loss or a failed relocation transaction.
- **Correction:** After successful relocation, resolve the actual backend ID for the captured imported UUID from the committed model/association and focus that row, consistent with the existing primary/fallback selection continuations. Do not move focus on failed, canceled or stale-preview completion.
- **Coverage:** Add a regression starting with `selectedID == old preset ID`, running the production environment relocation action, and asserting focus equals the imported backend after successful primary/fallback/unselected legacy relocation. Existing `legacyRelocation` tests check association, role and lease but never set/assert selectedID (`ASRModelCenterFixSelfTests.swift:48`).

## Evidence assessment

Read the final raw log summaries rather than rerunning their suites: build completed in 35.84 seconds; model-center 464/0, backend 1,128/0, provision 197/0, native client 986/0, M3 294/0, M4 19,793/0, HF/native activation 914/0. Those results support the implementer's stated focused verification; they do not cover R1. The checkout was clean at the reviewed HEAD. Existing historical d43 evidence has not been treated as evidence for this fixed candidate.

The tests exercise meaningful production seams with isolated synthetic providers/transport. In particular the native/service cancellation tests wait for intentionally uncooperative work and inspect retained configuration/lease rather than merely asserting a canceled Task flag. Relocation tests cover load/persist failure, cancellation, stale model/association/preview, aliases, managed ownership and occupancy. No extra test execution was needed to establish the deterministic UI-focus omission.

## Declined to judge

- Untouched acquisition, unrelated routing, unrelated UI and full-branch behavior: not re-audited because this assignment explicitly restricts review to the four fixes and breakage introduced by their diff. Adjacent code was read where it establishes those fixes' actual behavior.
- No other behavior considered within this scoped fix review was set aside as outside the specification.

These are separate unverified acceptance gates, not newly discovered source defects: the 71 real manual/device checks, actual-model/vendor integration, current remote CI and formal Developer ID/notarization/distribution remain Pending. Full new-candidate code/artifact/release gates are intentionally controller-owned after the final fix-review freeze. This review does not promote fixture evidence to those acceptance results.

## Recommendations and assessment

Fix R1 and verify the focused identity-following UI action before freezing the candidate for controller-owned full gates. No broader refactoring is indicated.

**Ready to merge? With fixes.** The original I1/I2/I3 Important defects and M1 disclosure regression are substantively corrected with coherent production ownership and transaction boundaries. One Minor omission remains against the explicit relocation-focus requirement; no new Critical or Important issue was established in the reviewed diff.

**Formal release readiness: Pending.** A clean scoped fix review does not replace the full candidate gates or outstanding manual/remote/distribution evidence.
