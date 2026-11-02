# M4 Task 2 implementation report

Status: DONE. Commit: `61c691f` — `fix: preserve stage failure causes for safe recovery`. Base: `b92a8dd04ba9a3c13a36f84cd9f759063aa2403d`.

## Implementation and contracts

- ASRStage retains `firstFailureKind` beside `firstFailure`, classifying original candidate errors before safe generic terminal wrapping. Terminal suspension explicitly carries the first kind, including mixed 401→timeout and timeout→401 chains. Expiry before a later candidate preserves the first actual error/kind. A successful fallback remains successful.
- ASR-owned budget expiry and the actual `withAsyncDeadline` boundary are explicitly transientASR; the generic classifier remains unchanged (`AsyncDeadlineError` outside ASR is internalFailure). An empty candidate list is readiness(noEngine). Unknown NSError remains internalFailure even though the compatible terminal Error still uses the old generic transcriptionFailed wrapper.
- Classified cancellation exits before health recording, fallback, or preview promotion. This includes batch, realtime and wrapped provider/network cancellation; the optional preflight detector catch also respects classified cancellation while ordinary detector failures remain indeterminate.
- Added the parent-approved trailing initializer seam `phrases: @escaping @MainActor @Sendable () -> [String]`, defaulting to the existing dictionary lookup. New stage tests pass `{ [] }`, so actual ASRStage executions use only synthetic phrases and PCM. Saved routing, local lease selection, realtime handles/cleanup, sequential candidate pass, health accounting and preview promotion remain unchanged.
- Added `RecordingEngineStartup.run(prepare:start:onFailure:finish:)` with the exact synchronous closure contract. AudioRecorder's existing startup boundary uses this seam; every engine.start error domain now calls onRecordingFrozen before spectrum finish exactly once. Success leaves the stream open. The changed failure log is a fixed safe string with no NSError/provider payload.
- InjectionStage explicitly marks pre-event blocked failures as deliveryBlocked and their complete polished text as result. Classified cancellation remains cancelled. Existing post-event completion/uncertain outcome handling remains unchanged; no Error-only inference of deliveryUncertain was added.
- Recording/ASR invalid-audio, recorder interruption and all stage invalidPayload typed mappings already supplied by Task 1 remain in use. RecordingStage, PostProcessStage and PolishStage required no source edit; optional Polish degradation is unchanged.
- Added `M4StageFailureSelfTests.run(_:)` to focused and full runners. Corrected the old RetryASRStage fixture's intended transient semantics to explicit transientASR/CloudASRError.timeout and supplied actual synthetic audio via RecoveryAudioStarter in its four pipelines. Controller/view code and old controller-policy assertions are untouched for Task 3.

## TDD and evidence

All commands run from `/Users/yiheng/pycode/flowtype-local`; stdout/stderr are preserved in the named raw logs beside this report. All runtime invocations use the exact prefix below (no HOME override):

```sh
env CFFIXED_USER_HOME=/Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-2-runtime-home
```

The directory was created inside the owned ignored SDD directory before runtime execution. The parent verified Foundation home/Application Support resolution under CFFIXED_USER_HOME. New tests also inject phrases explicitly; full legacy self-tests can initialize shared stores/logger, but their Foundation paths resolve inside this isolated runtime home. Earlier task runs did not use this isolation; this task does not inspect, mutate or restore real user data to investigate them.

| Phase | Command (prefix above on every swift run) | Exit/result | Log |
| --- | --- | --- | --- |
| Test authoring compile attempt 1 | `swift run FlowType --self-test --m4-recovery-only` (no runtime executed) | 1; incorrect FocusSignals initializer; this compile-only attempt omitted the isolation prefix | task-2-test-compile-initial.log |
| Test authoring compile attempt 2 | `swift run FlowType --self-test --m4-recovery-only` | 1; missing fixture sendContext argument; no runtime executed | task-2-test-compile-second.log |
| Behavioral RED before implementation | `swift run FlowType --self-test --m4-recovery-only` | 1; 19380 passed, 32 failed | task-2-red.log |
| Initial GREEN | `swift run FlowType --self-test --m4-recovery-only` | 0; 19431 passed, 0 failed | task-2-green-initial.log |
| Expanded batch/realtime GREEN | `swift run FlowType --self-test --m4-recovery-only` | 0; 19456 passed, 0 failed | task-2-green-before-preflight.log |
| Build before parent-requested preflight cancellation refinement | `swift build` | 0; Build complete! (25.94s) | task-2-build-before-preflight.log |
| Final GREEN including wrapped preflight cancellation | `swift run FlowType --self-test --m4-recovery-only` | 0; 19460 passed, 0 failed (132 new stage assertions) | task-2-green.log |
| Final sequential standalone build | `swift build` | 0; Build complete! (17.17s) | task-2-build.log |
| Single final full self-test | `swift run FlowType --self-test` | 0; 23584 passed, 0 failed (19460 M4 + 4124 existing) | task-2-full.log |

The meaningful behavioral RED included:

```text
FAIL: M4 stage batch configuration(...credentials): original typed cause — got transientASR, want configuration(...credentials)
FAIL: M4 stage realtime internalFailure: original typed cause — got transientASR, want internalFailure
FAIL: M4 stage known credentials before budget expiry: original typed cause — got transientASR, want configuration(...credentials)
FAIL: M4 cancellation has no fallback or health failure — got 3, want 0
FAIL: M4 delivery copy owns complete result — got raw, want result
=== M4 recovery self-test: 19380 passed, 32 failed ===
```

These failures were expected before ASR first-cause retention/typed cancellation and explicit injection result ownership. Startup contract assertions and further deadline/cancellation cases were added during implementation; the behavioral RED above covers the preexisting stage regressions.

Final stable verification output:

```text
Build of product 'FlowType' complete! (13.73s)
=== M4 recovery self-test: 19460 passed, 0 failed ===
Build complete! (17.17s)
Build of product 'FlowType' complete! (4.38s)
=== self-test: 23584 passed, 0 failed ===
```

Final focused GREEN preceded the final standalone build and single full run, without source changes between those checks. Final build and full logs contain no warnings, errors or failed assertions. The earlier build was superseded only because the parent explicitly requested classified preflight cancellation and its covering regression. The full suite took several minutes of CPU time on its existing synthetic data path and exited successfully; it was neither interrupted nor repeated.

## Coverage


The new suite runs actual ASRStage with in-process batch/realtime fake providers: terminal 401 versus timeout/unknown NSError plus exact typed policy retry eligibility; both two-candidate failure orders; first 401 surviving later budget expiry; successful fallback; no engine; initial budget expiry and actual async deadline; every known cancellation family in both transports; wrapped preflight cancellation without provider/health; invalid local directory/runtime and the real `apple-preview` ID; unchanged optional preview promotion; malformed PCM without provider/health/preview; all four stage invalid payloads; unknown pre-event injection failure with complete result text.

Startup closure tests cover CoreAudio and arbitrary synthetic NSError domains, exact prepare→start→failure→finish order/count, interruption visible before stream finish, and successful start invoking neither failure nor finish. This is the narrow hardware-free guarantee consumed by RecordingStage's existing frozen check; these tests do not instantiate the real AudioRecorder or claim actual engine/device acceptance.

## Files changed

Scoped source commit includes exactly:

- Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift
- Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift
- Sources/flowtype/Services/AudioRecorder.swift
- Sources/flowtype/Services/RecordingEngineStartup.swift (new)
- Sources/flowtype/Testing/M4StageFailureSelfTests.swift (new)
- Sources/flowtype/Testing/SelfTest.swift

Parent-owned audit/spec/plan/evidence changes are excluded. Reports/logs remain in ignored SDD storage.

## Self-review and limits

Reviewed the six scoped files, exact startup seam signature/order, cause retention in both candidate orders and expiry, cancellation ordering relative to health/provider calls, safe log strings, complete-result ownership and runner/fixture changes. `git diff --check` passes. Build diagnostics seen so far are preexisting AppLogger nonisolated(unsafe), AudioRecorder deviceIDSize mutability and inputConsumed capture warnings on unchanged lines; no unrelated cleanup is included.

No Python, dependency changes, model downloads, network/provider requests, real hardware/AudioRecorder access, user configuration/key/model-cache reads, swift test, benchmark, push or merge was performed. Controller card/action ownership is Task 3. Hardware startup failure, microphone removal and UI/system/provider acceptance remain Pending; this implementation does not claim them.

No unresolved correctness concern after self-review and verification. Scoped commit `61c691f` contains exactly the six listed source files; parent-owned documentation edits remain uncommitted and untouched.

## Review fix round 1 — Important F1

Review identified a missed effect path in the initial implementation: InjectionStage.typeText recognized only Swift CancellationError before copying on direct-typing failure. Classifier-known URL/wrapped cancellation could therefore bypass the later recovery annotations and produce a successful clipboard effect. The earlier broad cancellation-preservation claim did not cover this path; this fix supersedes that claim with focused runtime evidence.

Changed the original typing-error guard to use `FailureClassifier.classify(error) == .cancelled` before any clipboard fallback. It rethrows the original error through the existing cancelled outcome/suspension path. Existing post-event uncertain behavior stays in place. Two adjacent recovery argument indentation mistakes were corrected without behavior changes.

Covering test file: `Sources/flowtype/Testing/M4StageFailureSelfTests.swift`, new `typingCancellation(_:)` called by the focused/full M4 suite. Three real InjectionStage executions use explicit `.unicode` mode (resolves to `.type`), matching safe synthetic PID/focus snapshots, fake inject/copy boundaries, and no actual AX/keyboard/clipboard calls. Inject throws plain CancellationError, URLError(.cancelled), and Cloud→Speech→URLError(.cancelled). Each case asserts one actual typing boundary invocation, zero copies, no delivery event/effect, cancelled outcome, no successful clipboard notice/terminal-delivery flag, cancelled recovery kind, and retained complete-result ownership.

Exact RED command (stdout/stderr redirected to task-2-fix-1-red.log):

```sh
env CFFIXED_USER_HOME=/Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-2-runtime-home swift run FlowType --self-test --m4-recovery-only
```

RED before the guard fix exited 1. The plain CancellationError case passed; network and wrapped cancellation each failed the effect/outcome checks:

```text
FAIL: M4 typed cancel 1: no clipboard fallback — got 1, want 0
FAIL: M4 typed cancel 1: cancelled terminal outcome — got Optional(FlowType.DeliveryOutcome.clipboard), want Optional(FlowType.DeliveryOutcome.cancelled)
FAIL: M4 typed cancel 2: no clipboard fallback — got 1, want 0
FAIL: M4 typed cancel 2: suspension instead of successful completion
=== M4 recovery self-test: 19469 passed, 10 failed ===
```

GREEN uses the identical command above, redirecting stdout/stderr to task-2-fix-1-green.log. Exit 0:

```text
Build of product 'FlowType' complete! (11.83s)
=== FlowType --self-test ===
=== M4 recovery self-test: 19481 passed, 0 failed ===
```

Scoped fix commit: `43cc155` — `fix: stop typed cancellation before clipboard fallback`. Self-review and `git diff --cached --check` passed before commit. The GREEN compile log contains only the previously documented unchanged AppLogger nonisolated(unsafe) warning. No unresolved F1 concern remains.


Only InjectionStage.swift and M4StageFailureSelfTests.swift belong to this localized fix commit. Per the fix-loop instruction, compilation plus the focused suite cover the amended code; the unchanged full suite is not repeated. Parent documentation edits remain outside the commit. No subagents, controller changes, real user configuration, hardware, provider/network calls or model access were involved.
