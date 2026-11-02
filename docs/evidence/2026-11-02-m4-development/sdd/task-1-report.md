# M4 Task 1 implementation report

Status: DONE. Baseline: `bb6d9549fb6fd4de0fbebe6c91029d9b050a6eee`.

Commit: `b92a8dd` — `feat: classify failures and define safe recovery policy`.

## Implementation

- Added the exact safe failure categories and permission/configuration/recording enums. Reused `ReadinessIssue`.
- Added `FailureClassifier.classify(_:)` using concrete existing typed errors and NSError domain/code only. It never parses localized/provider text, URLs, response bodies or NSError userInfo. Cloud/Speech network wrappers preserve known categories through four layers; deeper chains and unknown errors become `internalFailure`.
- Added immutable resources, presentation and card values without stored Error, audio or transcript. Added `RecoveryAction` with existing labels and the three new actions; the pure policy only emits ASR retry for transient ASR + actual `ASR` stage + audio available + no delivery event.
- Implemented the exact specification message/action table, including action ordering, resource-dependent copying/history, restricted routing repair, maximum four actions and empty cancellation presentation. Existing `DeliveryCopy` remains untouched.
- Preserved the original four `ErrorRecoveryContext` initializer arguments/properties and added optional trailing `failureKind`/`textKind` arguments resolving to nonoptional stored values. Explicit categories win over legacy `retryable`; nonnil rawText infers `.raw`, including empty String.
- Added focused `--m4-recovery-only` routing and the same pure synthetic suite to the full runner. The policy matrix exercises all 22 fully expanded failure values across 144 stage/audio/text/event/routing/history profiles, checking exact copy/actions plus safety invariants.

## Confirmed interface decisions

The controller confirmed these mappings before final verification and recorded them in the specification:

- Typed `ASRStageError.transcriptionFailed` is transient without reading its String. Task 2 must retain underlying first-failure categories before using the generic wrapper.
- Postprocess `emptyResult` and polish `damagedLiterals` are processing failures; all typed invalidPayload cases are internal failures.
- Every `ModelProvisionError` is endpoint/model configuration, never an ASR retry/download operation.
- Generic `AsyncDeadlineError` is internal because the classifier has no stage context; Task 2 assigns the ASR-only budget exhaustion category explicitly.

Injection error classification describes the pre-event blocked case. The existing delivery owner must explicitly choose `deliveryUncertain` after its event latch; the classifier cannot infer posted events from an Error.

## TDD and verification evidence

All commands ran from `/Users/yiheng/pycode/flowtype-local`, sequentially. Each named raw log is preserved beside this report in the owned SDD directory. No dependency install, model download, Python conversion, real configuration/key/audio/cache access, GUI, live provider call, hardware operation, `swift test`, benchmark, branch/worktree recreation, push or merge was performed.

| Phase | Command (stdout/stderr redirected to named log) | Exit/result | Raw log |
| --- | --- | --- | --- |
| RED | `swift run FlowType --self-test --m4-recovery-only` | 1, expected compile failure before implementation; no runtime assertions executed | `task-1-red.log` |
| Initial GREEN | `swift run FlowType --self-test --m4-recovery-only` | 0; 19297 passed, 0 failed | `task-1-green-initial.log` |
| Final focused GREEN | `swift run FlowType --self-test --m4-recovery-only` | 0; 19328 passed, 0 failed | `task-1-green.log` |
| Build after focused stability | `swift build` | 0; Build complete! (17.14s) | `task-1-build.log` |
| Single full run after build | `swift run FlowType --self-test` | 0; 23452 passed, 0 failed (19328 M4 + 4124 existing) | `task-1-full.log` |

RED included the expected diagnostics:

```text
error: cannot find type 'RecoveryResources' in scope
error: cannot find type 'RecoveryTextKind' in scope
error: value of type 'ErrorRecoveryContext' has no member 'textKind'
```

Final focused GREEN ended:

```text
Build of product 'FlowType' complete! (12.01s)
=== FlowType --self-test ===
=== M4 recovery self-test: 19328 passed, 0 failed ===
```

Full run ended:

```text
Build of product 'FlowType' complete! (4.46s)
=== FlowType --self-test ===
=== self-test: 23452 passed, 0 failed ===
```

The initial GREEN preceded the agreed generic-deadline refinement and additional wrapper/ATS cases. Final focused GREEN covers the final source; the standalone build and single full run followed it without further source changes. The RED/focused compilation logs contain the preexisting AppLogger.swift:27 unnecessary `nonisolated(unsafe)` warning. No new warning was introduced, and standalone build/full logs contain no warnings/errors/failures.

## Files changed

Only these six source files belong to the scoped implementation commit:

1. `Sources/flowtype/Core/Recovery/FailureKind.swift` (new)
2. `Sources/flowtype/Core/Recovery/FailureClassifier.swift` (new)
3. `Sources/flowtype/Core/Recovery/RecoveryPolicy.swift` (new)
4. `Sources/flowtype/Core/Pipeline/PipelineStage.swift`
5. `Sources/flowtype/Testing/M4RecoveryPolicySelfTests.swift` (new)
6. `Sources/flowtype/Testing/SelfTest.swift` (runner only)

This report and raw logs stay in the owned, ignored SDD directory. Parent-owned specification/audit/evidence edits are excluded from the commit.

## Self-review and concerns

Reviewed all six scoped source changes, exact table strings/actions, wrapper boundaries, typed unknown/error separation, resource retry rules, context compatibility, safe value ownership and runner integration. `git diff --check` passed. All test inputs and new functionality are pure synthetic values; there are no system/network/configuration effects in these new files.

No unresolved correctness concern. Controller/view behavior and old nested `ErrorAction` intentionally remain for Task 3's alias conversion. Stage first-failure retention is Task 2. Real system/UI/hardware acceptance remains Pending under the plan and is not claimed by these checks.
