# Task 3 implementation report

Status: DONE. Source commit `1a07557` — `feat: bind recovery cards to the current session` (base `43cc155`).

## Scope

Implemented controller-owned recovery card identity, typed retry authorization, injected recovery effects, readiness refresh/rerouting, terminal uncertainty cards, and the 380×156 two-column capsule. `SessionRecoveryState` contains only card/copy-text values; all lifecycle authority stays private in `SessionController`. Compatibility methods delegate through the same current-card action gate.

Actual ASR retries retain original PCM, route, language and local lease, consume a fresh realtime handle, and receive a new 20-second budget. Configuration failures cannot retry captured credentials after settings changes. Rerecord creates a fresh session. Normal uncertainty closes the old context and event gate after once-only history/summary; explicit cancellation remains idle. Pre-event clipboard ownership changes preserve the uncertain outcome/history while showing the safe deliveryBlocked presentation, per controller clarification.

New tests exercise synthetic stages plus real ASRStage, InjectionStage, typing event loop and ClipboardTransaction boundaries. Effects, configuration, clipboard, provider/route/phrases and readiness are injected. No live cloud request, model load, hardware, permission prompt, or settings navigation is intentionally invoked by the new tests.

## TDD and command ledger

All commands run from `/Users/yiheng/pycode/flowtype-local`. Runtime home created first:

```
mkdir -p .superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home
```

Every build/self-test command uses this prefix; HOME is not reassigned:

```
env CFFIXED_USER_HOME="$PWD/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home"
```

Each focused run's command is the prefix followed by `swift run FlowType --self-test --m4-recovery-only > .superpowers/sdd/2026-11-02-m4-failure-recovery/<log> 2>&1`.

| Log | Result | Interpretation |
| --- | --- | --- |
| task-3-red.log | 19,486 pass / 6 fail, exit 1 | Behavioral RED before production edits: recording interruption/invalid audio became notices, legacy Boolean/name permitted retry, error capsule remained 320×94. |
| task-3-green-initial.log | 19,492 pass / 0 fail, exit 0 | Initial implementation GREEN. |
| task-3-green-expanded.log | Compile failure | Expanded test fixture omitted explicit cloudConfiguration argument; corrected. Not behavioral RED. |
| task-3-red-reentrancy.log | Compile failure | Remaining old RetryASRStage references and source edited during build; corrected and subsequent builds kept source stable. Not behavioral RED. |
| task-3-red-reentrancy-2.log | 19,671 pass / 1 fail, exit 1 | Valid RED: completed readiness callback replaced the card UUID of a newer session started inside refresh. |
| task-3-green.log | 19,672 pass / 0 fail, exit 0 | Expanded ownership, recovery, terminal, lease/realtime, and reentrant readiness GREEN. |
| task-3-red-history.log | 19,680 pass / 4 fail, exit 1 | Valid RED: explicit cancel overwrote a fresh session started from its history-save callback (capture count, card, window and event gate). |
| task-3-green-final.log | 19,686 pass / 0 fail, exit 0 | All focused checks pass, including both finish/cancel callback ownership and newer action authority. |
| task-3-build.log | Exit 0 | Sequential final swift build passed. |
| task-3-full.log | 23,803 pass / 7 fail, exit 1 | All failures in the existing M3 realtime retry fixture; its unknown ProbeError.synthetic now correctly maps to internalFailure and cannot authorize retry. Failed log preserved. |

Expected initial failure excerpts:

```
FAIL: M4 controller: recording(FlowType.RecordingFailure.interrupted) remains actionable error
FAIL: M4 controller: recording(FlowType.RecordingFailure.invalidAudio) remains actionable error
FAIL: M4 controller: name and legacy Boolean cannot authorize retry without real ASR/audio
FAIL: M4 controller: invalid retry cannot rerun synthetic stage — got 2, want 1
FAIL: M4 controller: recovery width — got 320.0, want 380.0
FAIL: M4 controller: recovery height — got 94.0, want 156.0
```

Task 3 adds 205 focused controller assertions beyond the 19,481 approved Task 1/2 baseline.

The second valid RED observed `M4 stale refresh completion cannot replace newer card` with differing card UUIDs belonging to the same newer session. This proves why session identity alone is insufficient.

## Files

- Sources/flowtype/Core/Recovery/SessionRecoveryState.swift
- Sources/flowtype/Core/Recovery/RecoveryEffects.swift
- Sources/flowtype/Core/PipelineOrchestrator.swift
- Sources/flowtype/CapsuleView.swift
- Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift
- Sources/flowtype/Testing/SelfTest.swift
- Sources/flowtype/Testing/M3SpeechPreflightSelfTests.swift
- Sources/flowtype/Testing/M3DeliverySelfTests.swift

Parent-owned docs/audit/README edits are intentionally excluded from the source commit.

## Self-review and limits

- Kept existing controller lifecycle private; did not add a coordinator or state machine. Existing PipelineOrchestrator.swift remains large (~900 lines); this task replaces focused sections rather than restructuring the file.
- Restored existing accessibility permission watch inside RecoveryEffects.live after review identified it was initially omitted.
- Readiness rechecks validate original card/session/context again after the callback, including route-change refresh. History effects in finish/cancel likewise revalidate captured ownership before publishing/resetting/closing resources; callback tests start a fresh recording and assert its card, window, event gate and action authority survive.
- `hasHistory` means the history-save path was entered, not successful persistence. Privacy/no-op-storage card copy never promises a stored transcript.
- The new suite covers complete explicit copy and no transcript/provider body/URL in cards. Published legacy lastErrorRawText remains the compatibility field; RecoveryCard itself contains only safe presentation values.
- Build warning in existing AppLogger.swift about unnecessary nonisolated(unsafe) is pre-existing and out of scope.
- CFFIXED_USER_HOME isolates the process's supported preferences/home resolution; existing full-suite global directory reads/logging are inherited and this report does not claim the entire historical runner has complete I/O isolation.
- GUI layout, true-device V1–V5, real cloud, hardware/permissions, acoustic calibration and model inference remain Pending.

Final sequential validation commands:

```
env CFFIXED_USER_HOME="$PWD/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home" swift build > .superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-build.log 2>&1
env CFFIXED_USER_HOME="$PWD/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home" swift run FlowType --self-test > .superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-full.log 2>&1
```

The final build log reports `Build complete! (17.11s)`. No `swift test`, benchmark, dependency installation, Python, model download or artifact build was run for this task.

### Full-suite fixture correction

The first full run found these seven failures, all downstream of the same retry fixture cause:

- M3 retry: explicit Retry reruns real preflight (1 vs 2)
- M3 retry: fresh saved realtime handle (0 vs 1)
- M3 retry: new handle finalizes once (0 vs 1)
- M3 retry: saved payload preserved sample-for-sample ([] vs [0.5, -0.5])
- M3 retry: only successful retry writes history (0 vs 1)
- M3 retry: explicit retry retains fresh-budget rule
- M3 retry: explicit retry receives new twenty-second budget

The pipeline already contains a real ASRStage. Its single `Live(fail: true)` test provider threw the unknown `ProbeError.synthetic`, which the approved typed classifier deliberately treats as internalFailure. The controller correctly denies retry for this class. The fix changes that intended transient fixture to CloudASRError.timeout; it does not relax retry authorization or remove any PCM/preflight/budget assertion. A focused `--m3-silence-only` RED/GREEN run and renewed sequential build/full are recorded below when complete.

| Follow-up log | Exact command suffix after the same env prefix | Result |
| --- | --- | --- |
| task-3-m3-red.log | `swift run FlowType --self-test --m3-silence-only` | 982 pass / 7 fail, exit 1; reproduces all seven fixture failures before correction. |
| task-3-m3-green.log | `swift run FlowType --self-test --m3-silence-only` | 990 pass / 0 fail, exit 0; all seven original assertions retained, plus typed-kind assertion. |
| task-3-build-final.log | `swift build` | Exit 0; Build complete! (18.38s). |
| task-3-full-final.log | `swift run FlowType --self-test` | 23,811 pass / 0 fail, exit 0. |

Each command redirects both streams to its listed log under `.superpowers/sdd/2026-11-02-m4-failure-recovery/`. The final build and full run are sequential, after the focused M3 GREEN. No production code changed after the 19,686/0 focused M4 GREEN; the fixture follow-up also explicitly injects the initial controller test's recovery effects and corrects one outdated test comment.

## Final result

```
=== M4 recovery self-test: 19686 passed, 0 failed ===
=== M3 silence self-test: 990 passed, 0 failed ===
=== self-test: 23811 passed, 0 failed ===
```

The full result comprises 19,686 M4 checks plus 4,125 existing-suite checks (the original 4,124 plus the explicit M3 typed-timeout assertion). All seven failures from the first full run are resolved. Final full output has no failures or runtime warnings; source recompilation logs retain the documented pre-existing AppLogger warning. `git diff --cached --check` passed before commit. The scoped source commit contains exactly the eight listed files, and parent-owned documentation changes remain uncommitted. No merge/push or app build was performed.

Final self-review found no unresolved implementation blocker. Remaining limitations are the expected GUI/device/cloud/model validation Pending items and the inherited full-runner global I/O caveat above. Independent task/whole-M4 review is the parent controller's next step.

# Task 3 fix round 1 — Important I1 / I2

Status: DONE. Scoped fix commit `c292110` — `fix: commit recovery presentation before publishing`. Focused 19,730/0; sequential build passed; full 23,855/0.

Review: `.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-review.md`. Complete findings I1/I2 were read verbatim before changes. Fix source baseline `1a07557`; starting HEAD `27250c3` contains parent documentation only.

## Findings and implementation

I1 reproduced: a retained one-shot `$lastDeliverySummary` Combine subscriber calls cancel then startRecording on the first uncertain summary. Because @Published sends in willSet, nested cancellation published the same summary twice, and returning old finish/cancel removed the newer blocked context/card/window. The fix claims the summary before assignment and revalidates captured ownership after publishing in both finish and cancel. `$lastDeliverySummary` remains source compatible.

I2 reproduced: a retained one-shot `$recoveryCard` subscriber starts a new blocked session during a refreshed card's willSet. The outer setter then overwrote the displayed card and error message while private authority belonged to the new session. Parent additionally named and required the same precise `$sessionState` and `objectWillChange` trigger; both were reproduced before implementation.

The parent explicitly approved the necessary interface refinement before it was implemented: recoveryCard/errorActions/lastErrorRawText are now read-only projections of one committed private SessionRecoveryState; sessionState is a read-only projection of the existing controller's canonical value. Explicit `recoveryCardPublisher` and `sessionStatePublisher` replace the corresponding @Published projections. The only product `$sessionState` consumers were two sites in StatusBarController.swift; both were updated. No product `$recoveryCard`, `$errorActions`, or `$lastErrorRawText` consumers existed. Spectrum/preparation remain @Published, and no settings/UI flow was added.

A private CurrentValueSubject carries only a notification-generation number. Every projection validates that number when its subscriber is invoked. Canonical state/card/actions/text are committed before notifications; a nested newer commit suppresses remaining older notifications, including to subscribers registered after the mutating subscriber. This is publication bookkeeping only: existing private SessionController/SessionContext still owns the sole lifecycle; SessionRecoveryState remains pure card/copy-text values. Clear/reset commits recovery values before notifying, and lifecycle cleanup/window work precedes the final committed notification or is guarded against reentrant replacement.

## Exact commands and raw logs

All commands run from `/Users/yiheng/pycode/flowtype-local`, using the existing task-owned runtime home created in the original ledger. HOME is unchanged. Exact command template:

```
env CFFIXED_USER_HOME="$PWD/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home" swift run FlowType --self-test --m4-recovery-only > .superpowers/sdd/2026-11-02-m4-failure-recovery/LOG 2>&1
```

| LOG | Result | Evidence |
| --- | --- | --- |
| task-3-fix1-red.log | 19,695 pass / 17 fail; exit 1 | Real Combine summary/card subscriber reproducers before production edits. |
| task-3-fix1-red-state.log | 19,707 pass / 19 fail; exit 1 | Adds exact sessionState and objectWillChange reproducers; each leaves an obsolete error message. |
| task-3-fix1-green.log | 19,726 pass / 0 fail; exit 0 | I1/I2 plus named state/object publication triggers pass after implementation. |
| task-3-fix1-green-final.log | 19,730 pass / 0 fail; exit 0 | Adds downstream-subscriber checks: neither final state nor final card emission is superseded by an outer publication. |

Representative RED output:

```
FAIL: M4 summary subscriber cancel: once-only synchronous summary publication — got 2, want 1
FAIL: M4 summary subscriber cancel: newer message retained — got idle, want error("麦克风权限未开启")
FAIL: M4 card subscriber: newest message survives outer setter — got error("没有可用的语音识别引擎"), want error("麦克风权限未开启")
FAIL: M4 card subscriber: displayed card can execute its allowed action — got [], want ["mic"]
FAIL: M4 state subscriber: canonical error retained — got error("没有可用的语音识别引擎"), want error("麦克风权限未开启")
FAIL: M4 objectWillChange subscriber: canonical error retained — got error("没有可用的语音识别引擎"), want error("麦克风权限未开启")
```

Tests retain actual subscriptions, set one-shot flags before invoking controller methods, exercise real InjectionStage/event gates, and assert once-only history/summary, newer card/message/window, allowed settings effects, and readiness recheck authority of the newer context. These are controller behavior assertions, not merely publisher-value checks.

Sequential validation commands (after focused GREEN):

```
env CFFIXED_USER_HOME="$PWD/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home" swift build > .superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-fix1-build.log 2>&1
env CFFIXED_USER_HOME="$PWD/.superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-runtime-home" swift run FlowType --self-test > .superpowers/sdd/2026-11-02-m4-failure-recovery/task-3-fix1-full.log 2>&1
```

## Scoped files and self-review

- Sources/flowtype/Core/PipelineOrchestrator.swift — committed presentation projections, generation-filtered notification, summary claim and continuation ownership checks.
- Sources/flowtype/App/StatusBarController.swift — exactly two state-publisher consumer updates and their explanatory comment.
- Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift — retained Combine reproducers for I1/I2 and the two named related publication boundaries.

No coordinator, custom property wrapper, dependency, new lifecycle, or public lifecycle field was added. Parent spec/plan/doc edits remain outside the source fix commit. No live configuration/key/model/network/hardware/permission effect is used by new tests. Existing AppLogger compilation warning and historical full-runner I/O caveat remain unchanged. GUI/device/cloud/model validation remains Pending.

## Fix round 1 final evidence

```
=== M4 recovery self-test: 19730 passed, 0 failed ===
Build complete! (24.48s)
=== self-test: 23855 passed, 0 failed ===
```

- `task-3-fix1-build.log`: exit 0, sequential build success; pre-existing AppLogger nonisolated(unsafe) warning only.
- `task-3-fix1-full.log`: exit 0, 23,855 passed / 0 failed; no runtime failure/warning reported.
- 44 additional focused assertions cover the two review findings and the specifically requested state/object notification boundaries. Existing 4,125 non-M4 assertions remain passing.
- `git diff --cached --check` passed. Scoped commit `c292110` contains exactly PipelineOrchestrator.swift, StatusBarController.swift, and M4RecoveryControllerSelfTests.swift. Parent spec/plan changes remain outside the commit.
- Final consumer audit found no remaining `$sessionState`, `$recoveryCard`, `$errorActions`, or `$lastErrorRawText` references in Sources or Tests. The retained `$lastDeliverySummary` API and existing menu/summary regression coverage pass.
- No unresolved I1/I2 implementation concern identified in self-review. GUI/device validation and inherited full-runner I/O limitations remain Pending/unchanged as recorded above. No merge/push or app build performed.
