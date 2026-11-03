# M5-B Task 1 implementation report

Status: DONE — M5-B Task 1 only; ready for controller review.

Base: `d6aaace2bcbc74d21499543e83684598391bda41`.

Commit: `748855375a4f887732aa282d50d0c3ef2d260c43` — `feat: add bounded startup smoke with real timer evidence`.

## Implementation and boundaries

`Validation/ValidationReport.swift` defines closed common failure/readiness/permission tags, explicit-null JSON encoding and SmokeReport's0/1/69 exit mapping. Missing engines or permissions affect readiness only; missing either callback or the6s observation requirement fails with timerDeadline. Only an explicitly identified absent graphical WindowServer session maps to69; ordinary initialization errors remain failure.

`StartupSmoke.run` consumes the already prepared runtime/logger identity, checks the graphical session with CGSessionCopyCurrentDictionary, creates real NSApplication/accessory, isolated ConfigurationStore, safe SessionController/router, real hidden WindowManager panel and real StatusBarController setup, then refreshes read-only readiness. It starts actual probe/health timers and asynchronously observes at least6s, waiting up to10s for both callbacks. The report carries only closed status/count/identity fields and declares tap=disabledForValidation. Startup checks reject a missing/visible panel or incomplete status setup. Cleanup stops owned timers, removes this process's status item, closes its hidden panel and stops permission watch. It never enters ordinary AppDelegate startup. Main logs/flushes the report and emits exactly one JSON line; pre-context bootstrap/logger failures retain safe stderr exits without invented run identity.

ASRRouter's real Dispatch callback now captures weak self and is explicitly Sendable, increments a locked per-instance tick count inside the callback, and refreshes that same instance. Default first delay1s/period30s remain. Start is idempotent; stop invalidates generation, cancels the source and rejects stale callbacks. Shared selfTest startup remains suppressed. Focused fixtures inject short delay/period and synthetic configuration; smoke explicitly starts the real shared timer. No configured provider/model/network work is introduced.

WindowManager's common health timer uses a Sendable Dispatch main-queue callback with generation ownership. Both ordinary setup and startValidationHealthCheck use that same source and repair callback, retaining the5s default. Counters increment only after entry into an active real callback. Validation guards precede tap install/repair/reload and both hotkey handlers; the C event callback also rejects non-app roles before touching cached event/session state.

StatusBar/Dictation production selectors now enforce the role before recording, repairs, permission/settings actions, configuration reload, onboarding, windows/logs/About or quit. Menu disabling is additional presentation. Injected downstream action adapters allow actual handlers/selectors to be tested with synthetic effects, including a positive app branch. Existing injected-session menu semantics remain covered using explicit app-role fixture gates; no user session/ownership contracts were weakened.

`BoundedProcess.run` uses Foundation Process plus Darwin process groups, monotonic deadlines and direct file stdout/stderr. Its controlled child first validates the private control socket, creates its own group, handshakes its exact PID, switches target stdin to/dev/null and execs an argument array. A close-on-exec control descriptor distinguishes successful exec from wrapper failure. The parent never depends on the target actor/run loop. Only the handshaken group (or exact owned child/verified child group before a successful handshake) is signaled: TERM, up to2s grace, KILL, then bounded reap/cleanup checks. No killall or unbounded wait is used. Output files are created without overwriting existing files. The reusable dispatchChildIfNeeded entry is first in ProcessCLI, and is available to future packaging/verification CLI consumers.

ProcessCLI returns the normal child code,1 for signal/launch failure,124 for timeout,125 for tool errors and64 for usage. Result JSON encodes absent exit/failure values as explicit nulls. Its self-test uses only owned short-lived fixtures and temporary files. No shell interpolation, Python, dependency or external timeout utility is used.

## TDD and focused evidence

All logs are local ignored evidence in this B task directory.

- `task-1-red-build.log`: build exit0. `task-1-red-focused.log`: app behavioral RED15 passed/34 failed, exit1, covering missing timer/role/report behavior against safe initial APIs.
- `task-1-process-red-build.log`: compiler exit0. `task-1-process-red.log`: process behavioral RED7 passed/3 failed, exit1, specifically TERM grace, descendant cleanup and missing handshake. The initial runner bounded only its direct child; the test cleaned only recorded owned fixture PIDs afterward.
- `task-1-green-build.log`: intermediate build failed after a source edit split a documentation comment into code. Corrected it. An intermediate Ruby patch also failed before edits; that script was corrected. `task-1-green-build-fixed.log` subsequently builds successfully. These intermediate builds are not used as final stable verification.
- `task-1-process-green.log`:9/1, exit1. Foundation Process fixture children formed separate groups on this platform, so the inherited-group cleanup assertion failed. Replaced fixture spawning with posix_spawn and no SETPGROUP attributes, which inherits the owned group without fork. An intermediate `_NSGetEnviron` compile failure (`task-1-process-green-build-fixed.log`) was corrected to an explicit empty fixture environment. `task-1-process-green-posix.log` then passes10/0.
- `task-1-actual-entry-red-focused.log`:52/6, exit1, after removing only two real entry guards (WindowManager.installEventTap and StatusBarController.repairReadiness). Both validation roles detect the incorrect install return and downstream adapter calls. No real OS/UI effect was used for this mutation. The exact source was restored from task-owned snapshots.
- `task-1-final-focused-build-status.log`: build exit0 (36.17s). `task-1-final-focused.log`:58/0, exit0. Tests directly invoke WindowManager install/setup/repair/reload/double/single handlers and StatusBar repair/permissions/reload/settings/onboarding/quit/log/About/menu selectors plus direct openSettings, proving zero synthetic downstream effects for selfTest/smokeTest and positive app behavior. They also force-enable a dictation sender to verify its actual selector still refuses capture.
- `task-1-process-final-build-expanded.log`: compiler exit0. `task-1-process-final.log`:17/0, exit0. Fixtures cover blocked main, signal termination, normal nonzero code,2MiB stdout, stdin EOF, literal argv containing shell syntax, explicit-null successful result, inherited-group children/grandchild ignoring TERM,2s escalation, independent fixture survival, missing executable and missing handshake.

Timer fixtures trigger one actual short-delay source on only the first of two injected routers; only its tick/config-refresh evidence advances. Duplicate start owns one timer, passive waiting on the other earns no evidence, the common health source ticks, and stopping prevents later health increments. Report fixtures reject missing ticks/short duration and generic startup errors while allowing blocked readiness; only explicit WindowServer absence is Skip.

## Sequential full and bounded process validation

The stable sequential `swift build` exited0 in `task-1-full-lane-build.log` (20.69s). The full runner then executed exactly once:

```sh
build/m5-process --timeout 900 --stdout .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-full.stdout --stderr .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-full.stderr --result .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-full-result.json -- /Users/yiheng/pycode/flowtype-local/.build/debug/FlowType --self-test --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-full-run
```

Actual complete stdout:

```text
=== FlowType --self-test ===
=== self-test: 24224 passed, 0 failed ===
```

Outer CLI and child exited0, normal termination, timedOut=false, failureCode=null, duration198198ms. Owned runner PID50111 and target/group50112. At about181s, a read-only check of those owned processes/log showed progress through synthetic ASR/Polish timeout cases beyond the early configuration fixture; this same run finished at198.198s. No second full was launched. No legacy assertion or real hidden AppKit panel/screen check was removed or skipped; final fourteen external-effect budgets passed.

`task-1-full-log-inspection.log` independently compares the actual isolated log with the root marker:557 lines; first BuildIdentity header; every line UTC/selfTest/runID/[SelfTest]; development identity; last line the exact24224/0 summary; stderr empty. All inspection assertions passed.

After full completion, the watchdog ran four safe negative cases (`task-1-cli-negatives.log` plus per-case stdout/stderr/result): duplicate selfTest/smoke modes64, unknown M5 option64, missing validation-root value64, relative validation-root path1. All had empty target stdout and no timeout. Each explicitly selects a non-app mode. Malformed option usage64 versus root preparation1 preserves A's contract.

Exactly one bounded development smoke was then run:

```sh
build/m5-process --timeout 15 --stdout .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-smoke.stdout --stderr .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-smoke.stderr --result .superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-smoke-result.json -- /Users/yiheng/pycode/flowtype-local/.build/debug/FlowType --smoke-test --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-b-smoke-and-artifact/task-1-smoke-run
```

Actual report: schema1, mode=smoke, role=smokeTest, ok=true, duration6356ms, probeTimerTicks=1, windowHealthTicks=1, tap=disabledForValidation, origin=development, metadata=null, failureCode=null. Readiness=blocked; ax=granted, mic=notDetermined, speech=notDetermined. These are read-only state tags, not permission requests. Outer/child exit0, normal termination, timedOut=false, outer duration6499ms, failureCode=null.

`task-1-smoke-inspection.log` proves stdout is exactly one JSON line with exactly fifteen required fields, runID matches its independent root marker, duration≥6000 and both ticks≥1. The three-line log has the same identity header first and exactly the stdout report last; every line UTC/smokeTest/runID; stderr empty. Every assertion passed. This was a real WindowServer smoke Pass, not Skip. Final ten runs remain with C. No source behavior changed after final focused/full/smoke verification.

## Scoped files and commit

Exact staged list in `task-1-scoped-files.log`:

```text
Sources/flowtype/App/FlowTypeApp.swift
Sources/flowtype/App/RuntimeEnvironment.swift
Sources/flowtype/App/StatusBarController.swift
Sources/flowtype/App/Validation/StartupSmoke.swift
Sources/flowtype/App/Validation/ValidationReport.swift
Sources/flowtype/Services/Speech/ASRRouter.swift
Sources/flowtype/Testing/M5SmokeSelfTests.swift
Sources/flowtype/Testing/SelfTest.swift
Sources/flowtype/WindowManager.swift
scripts/verification/BoundedProcess.swift
scripts/verification/ProcessCLI.swift
scripts/verification/ProcessRunnerSelfTests.swift
```

Scoped stage contained12 files,682 additions/28 deletions. `git diff --cached --check` passed with empty output in `task-1-staged-check.log`; `task-1-commit.log` records the successful commit above. Final `git status --short` and `git diff HEAD --check` produced no output. Reports/logs/run roots/tool binaries remain ignored local evidence, not committed. No later task was started.

## Self-review and limitations

The entry/exit audit is retained in `task-1-entry-exit-audit.log`. Self-review checked weak instance captures, locked counters/generation cancellation, common timer start/stop, actual selector guards before adapters, no ordinary AppDelegate path, isolated stdout/logs, group handshake/TERM/KILL cleanup, no-overwrite output and app-role controls. The stable final build and process compiler emitted no warning; earlier dependent builds retain existing recorder/audio-device warnings without unrelated cleanup.

This runner cleans only this run's handshaken process group. Foundation Process can form new groups during ordinary child tool calls on this platform; the original fixture failure records that fact. POSIX fixtures prove cleanup of descendants inheriting the group, and that an independent group is untouched. This is not an OS sandbox or proof that all nested new groups are covered. B3/C nested watchdog/recovery/tool owners must bound and clean their own groups and restore their own state; they cannot assume outer group cleanup covers a new group.

Effect counters and synthetic action adapters prove code-boundary behavior, not external OS monitoring. Smoke does not install or authorize a real tap, process real hotkeys, record audio, infer speech, load/download models, mutate a real clipboard, dispatch input, open permission settings or launch ordinary AppDelegate. Passive permission/readiness state is permitted. Ordinary app/hardware/GUI appearance, artifact/GPU/packaging and final ten-smoke/release lanes remain Pending/out of B1 scope.

No real user config/dictionary/DB/Keychain/model cache was read as a baseline. No dependency lock/package changes, installs, Python, swift test, nested agents, push, merge, plans or ledger changes were made. Work stops after B1 for controller review.
