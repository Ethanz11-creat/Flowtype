# Whole-M4 final consolidated fix report

Status: DONE. Source commit: `5dc1693` — `fix: preserve session ownership after synchronous publication`.

Base: `24f2e517bc137769af07b77622ad0eed358b25b0`; prior product source `c292110`.
Authoritative findings: `final-review.md` Important I1 and Minor M1. No subagents dispatched; no parent design/plan/evidence documents modified.

## I1 — superseded caller continuation

Reproduced the actual controller task-handle replacement using a real `SessionController` and `InjectionStage`. A synthetic first stage gives A a polished payload. Its one-shot `.injecting` Combine subscriber cancels A and starts B. B's synthetic Recording stage marks readiness and waits on an `AsyncStream` inside a task cancellation handler. The handler records actual task cancellation under `OSAllocatedUnfairLock`; it does not emulate the controller's task bookkeeping. Cancelling B previously failed to invoke that handler (0 instead of 1). The stream is finished on test exit even when assertions fail, and polling is bounded to 200 × 10 ms.

Also reproduced a newer same-session `.processing` publication during `.injecting`: the obsolete caller previously posted an event, saved history, and replaced that newer state with a terminal card. A separate `.preparing` subscriber cancellation previously ended idle but reopened the window. These regressions assert the newest state, actual cancellation cleanup once, zero obsolete events/copy/history, final hide, and no stage startup after cancelled preparation.

Production fix stays in the existing controller/context lifecycle:

- `transition` now returns whether its exact presentation generation survived synchronous window effects, observers, state/card subscribers, and `objectWillChange`. It is discardable for callers with no subsequent lifecycle work.
- Preparing, readiness→recording, explicit retry→processing, and pre-Injection callers require a surviving transition plus ownership of the same active, uncancelled context before continuing. The injection caller therefore cannot create/store an obsolete task over B's task.
- Startup checks ownership/generation after the injected readiness lookup and existing preparation/spectrum publications. It checks again after the trailing window effect before executing a stage.
- The shared stage entry/result and finish paths use one private active-context predicate. Finish rechecks generation as well as identity after synchronous history/summary publication and the terminal spectrum publication, so a same-session newer commit is also respected.
- The recording timer's post-publication auto-stop continuation checks context, generation, and current recording state before doing more lifecycle work.

### Readiness/timer continuation justification

The brief permits a precise static guard justification with existing coverage. The readiness subscription requires the current session and `.preparing`, captures the generation before clearing the published preparation notice, then revalidates. Its recording transition must return true and the same context must still be active. Only then can `startRecordingTimer` execute. There is no await or callback between that final guard and timer scheduling. Thus cancel/new-session reentry fails identity/cancellation and generation checks; a newer same-session commit fails the transition result; none can schedule an old timer over a replacement timer. No trailing old cleanup executes after this guard. For an already queued timer tick, the existing session/context/cancellation/state gate remains, and the new post-publication generation gate prevents stale auto-stop.

Existing full-suite coverage: `SelfTest.testReadinessPreflight` exercises a real controller's valid readiness, cancellation, fresh blocked session, and late old readiness/state; `SelfTest.testSessionExperience` covers stale/cancelled timer ticks and exactly-once `markReady`. Existing M4 terminal tests reject late readiness after closing the event gate. The new task-ownership regression additionally proves B can mark ready and its actual recording task is cancelled once. No timer inspection seam or separate lifecycle owner was added. This is source/control-flow verification plus those runtime tests, not a new direct assertion of timer allocation/invalidation.

## M1 — introduced Sendable captures and corrected accounting

Moved the mutable controller reference and arming flag into the existing small `@MainActor` fixture (`weak ownedController`, `armed`). The affected real Combine subscriber triggers and assertions remain intact. The weak reference avoids a fixture/controller retention cycle.

The two warnings at former test lines 459 (`c`) and 557 (`armed`) **were introduced by the previous M4 test implementation**, as shown by historical `task-3-fix1-green-final.log`; they were not preexisting project warnings. This report supersedes the incomplete warning accounting in `task-3-report.md` without editing any historical report/log. The corrected test file was actually recompiled in both RED and GREEN, and neither warning occurs in those logs. The existing `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning remains. The later incremental build's silence is not presented as evidence of a warning-clean rebuild.

## Verification

All commands ran from `/Users/yiheng/pycode/flowtype-local`. Created the owned `final-fix-runtime-home` directory before execution. Each Swift build/run command used the exact prefix:

```sh
env CFFIXED_USER_HOME=/Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-02-m4-failure-recovery/final-fix-runtime-home
```

`HOME` was not overridden. Test boundaries use synthetic text, target identities, recording streams, delivery events, and isolated configuration. No new dependency, Python/conversion, model/cache/key/config access, real provider/network/hardware/permission interaction, benchmark, or `swift test` invocation was introduced/performed by this wave. The full existing suite runs under the same isolated runtime home; this does not retroactively fix historical runner isolation limitations.

| Step | Command following the prefix | Result | Raw log |
| --- | --- | --- | --- |
| Initial fixture compile | `swift run FlowType --self-test --m4-recovery-only` | Exit 1: test used nonexistent `PasteTransactionResult.pasteDispatched`; corrected to `.uncertain` before meaningful RED. Secondary type inference error was consequent. | `final-fix-red-compile.log` |
| Meaningful RED, unchanged production | `swift run FlowType --self-test --m4-recovery-only` | Exit 1; **19,741 passed / 6 failed**; build 14.60 s | `final-fix-red.log` |
| Focused GREEN | `swift run FlowType --self-test --m4-recovery-only` | Exit 0; **19,747 passed / 0 failed**; build 14.93 s | `final-fix-green.log` |
| Stable build | `swift build` | Exit 0; **Build complete! (16.92s)** | `final-fix-build.log` |
| Stable full suite | `swift run FlowType --self-test` | Exit 0; **23,872 passed / 0 failed**; incremental build 4.34 s | `final-fix-full.log` |

The six meaningful RED failures were:

```text
cancel reaches the actual new recording task exactly once — got 0, want 1
repeated cancel does not repeat recorder cleanup — got 0, want 1
newer presentation retains authority — got error(...), want processing(provider: "replacement")
obsolete injection posts no event — got ["event"], want []
obsolete injection saves no history — got [1], want []
cancelled window is not reopened — got Optional("show"), want Optional("hide")
```

The full run is justified because startup, readiness, retry, task creation, finish, and timer auto-stop share controller continuation logic. It ran once after the stable build, with buffered output and normal CPU activity for several minutes. The previous **23,855/0** result remains historical evidence for `c292110`, not the current source. No unchanged full-suite rerun was used as a substitute for the targeted reproduction.

## Scope and self-review

Only source files owned by this wave:

- `Sources/flowtype/Core/PipelineOrchestrator.swift`
- `Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift`

Reviewed the complete scoped diff, synchronous transition callers, injected effect returns, same-session generation replacement, current-task assignment ordering, and terminal/current-context distinctions. `git diff --check` passed. No source edit to ASR, RecordingStage, delivery gates/transaction, routing/lease/audio policy, recovery authorization/policy, UI consumers, or dependencies. M3 delivery latch, balanced key checks, clipboard ownership/settling, fresh retry resources/budget, and explicit cancellation semantics remain intact. No test-only production API was added.

No known unaddressed finding from I1/M1. Device, live provider, GUI, and cross-application acceptance remain Pending; synthetic suites do not establish them. Existing AppLogger warning is outside this scoped wave.
