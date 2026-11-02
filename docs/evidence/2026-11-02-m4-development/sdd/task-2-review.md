### Spec Compliance

- ❌ Issues found: classified cancellation is not preserved through InjectionStage's direct-typing fallback. A classifier-known cancellation can cause a clipboard effect instead of a cancelled suspension (`Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:164`, `:172`). The other reviewed Task 2 boundaries match the brief and the approved phrases/deadline/preflight clarifications.
- ⚠️ Cannot verify from this task diff: Task 3 controller enforcement of typed recovery, current-card ownership, retained-audio retry, persistent startup/uncertain cards, and privacy/history behavior. These remain Task 3 checks, not Task 2 approvals (`docs/superpowers/plans/2026-11-02-m4-failure-recovery.md:117`). Actual engine/device startup, microphone removal, GUI, and real-provider acceptance remain Pending (`task-2-report.md:68`). Optional Polish degradation is unchanged in this package; its broader behavior is not independently re-reviewed here.

### Strengths

- First-cause retention is paired with the original error, later budget expiry cannot overwrite it, and terminal recovery receives the explicit kind; ASR-only deadlines remain explicit without broadening the generic classifier (`Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift:85`, `:95`, `:150`, `:184`). Provider/preflight classified cancellation exits before ASR fallback or failure health (`ASRStage.swift:53`, `:151`).
- Startup extraction is narrow, synchronous, and preserves the exact prepare/start → failure → finish contract for every thrown domain; AudioRecorder uses a fixed safe failure log (`Sources/flowtype/Services/RecordingEngineStartup.swift:4`, `Sources/flowtype/Services/AudioRecorder.swift:302`). RecordingStage's existing frozen check returns engineStartFailed before producing its audio payload (`Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift:137`).
- New tests execute actual ASRStage with fake batch/realtime providers, synthetic PCM, injected empty phrases, typed recovery/policy assertions, mixed causes, cancellation, and startup closure ordering. The existing retry fixture now has explicitly transient semantics and synthetic audio rather than weakening recovery policy (`Sources/flowtype/Testing/M4StageFailureSelfTests.swift:39`, `:61`, `Sources/flowtype/Testing/SelfTest.swift:489`, `:505`).
- Existing evidence records focused RED 19380/32, final focused GREEN 19460/0, sequential standalone build, and full 23584/0 (`task-2-red.log:52`, `task-2-green.log:20`, `task-2-build.log:6`, `task-2-full.log:6`). No tests were rerun. Observed compiler warnings concern unchanged AppLogger/recorder lines; none is introduced by this diff (`task-2-green.log:6`, `task-2-green-initial.log:16`).

### Issues

#### Critical (Must Fix)

- None found.

#### Important (Should Fix)

- **Known cancellation can copy the result during typing fallback.** `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:164` still recognizes only Swift CancellationError before the clipboard fallback at `:172`. Trigger: a direct `.type` attempt throws `URLError(.cancelled)` (or another classifier-known cancellation) through the injectable typing boundary before a delivery event, while the Task/context are otherwise active. `checkActive` succeeds; the error fails the narrow type check; the stage executes `copyToClipboard`, records `.clipboard`, and returns `.complete`. The new cancellation mappings at `:170` and `:182` never run for this branch. This violates cancellation-before-effects and the report's claimed cancellation preservation; it can replace the user's clipboard on a cancelled attempt. Classify the original typing error before any fallback and send `.cancelled` through the existing cancelled completion/suspension path. Add a focused real InjectionStage test with explicit `.type` mode, safe synthetic target, throwing injected `inject`, and a fake copy counter; assert zero copies, no event, cancelled outcome/kind, and no successful clipboard completion. Cover plain CancellationError and a wrapped/network cancellation to distinguish the classifier contract.

#### Minor (Nice to Have)

- None found.

### Assessment

**Task quality:** Needs fixes.

**Reasoning:** ASR first-cause handling and the recorder seam are focused and well covered by the supplied evidence. InjectionStage's incomplete cancellation guard leaves an effect-producing branch outside its new typed classification.

### Focused inspection record

- Reviewed package `review-b92a8dd..61c691f.diff` for base b92a8dd → head 61c691f; recovered the test range omitted by the tool's initial output truncation. No git diff/log, test execution, subagents, or source mutation.
- Changed-file reads were limited to mid-function context missing from the package: ASR candidate execution and InjectionStage execute/typeText/copy effect flow. Named risk: new typed cancellation annotations could occur after a fallback side effect; the focused InjectionStage inspection confirms the Important finding (`InjectionStage.swift:146`, `:205`).
- Named cross-interface risk: startup callback ordering might still produce an ordinary empty recording. Checked only RecordingStage callback installation and frozen-to-engineStartFailed path; frozen is set before completion and checked before `.audio` output (`RecordingStage.swift:46`, `:137`, `:155`). This does not claim hardware acceptance or absence of optional preview initialization.
- Named cross-interface risk: unchanged stage mappings or generic deadlines might undermine explicit annotations. Checked FailureClassifier's relevant typed cancellation, recorder, invalid-payload and default mappings; they preserve cancelled/interrupted/internal semantics and leave generic AsyncDeadlineError internal (`Sources/flowtype/Core/Recovery/FailureClassifier.swift:12`, `:41`, `:75`, `:81`, `:100`, `:109`).
- Runtime CFFIXED_USER_HOME isolation/path resolution is accepted from the controller's explicit verified clarification and the report (`task-2-report.md:18`); raw test output alone does not independently prove the launch environment. Only this scratch report was written.
