# Code-gate cancellation assertion investigation and deterministic fixture correction

Date: 2026-11-11. Base candidate: `e0980ec6c8b2c35ca67736cce8520bb51b2f4de1`. Final HEAD: `76757c7e5693c0350b67093d1a0750c21b0b214b`. All final targeted checks completed before this explicit-file commit. One implementer; no child agents.

## Original failure and what remains unknown

The controller's immutable code-gate evidence is `build/verification/AAE4C5FF-37F5-4CA9-97AC-0D5AB889EDAD/verify-report.json`. Full run: **28,471 passed / 1 failed**, exit 1; the only stderr assertion was `C4 I3 cancelled producer retains owner until actual cleanup drain` in `ASRModelCenterReviewSelfTests.swift`. The failed code evidence and controller stop report under `build/review-fixes-validation-20261111-004225/` remain unchanged. Artifact/release gates were not started.

That original log did not record the concrete realtime session, whether finish had actually become held, or which of VM/A5 ownership flags was false. **Its exact historical scheduler interleaving is unobserved.** The controlled counterexample below proves a real fixture defect and reproduces the assertion; it does not retrospectively prove the exact unseen scheduling order of the full run. No production ownership defect is established by that original compound failure.

## Root-cause trace and controlled RED

Traced `VM.performUserOperation` → A5 `run` → realtime recognition → `withAsyncDeadline`. Caller cancellation is forwarded to the application-owned Task. A5 removes its per-profile owner only after the recognition operation result; realtime recognition awaits `session.cancel()` and then actual worker result. VM releases its admission after the owned task returns. If the **same** fixture session has both its finish continuation and cleanup continuation installed, these boundaries cannot have completed yet.

The test did not establish that premise: `RealtimeProbe.waitForFinish` and `waitForNewFinish` yielded at most 10,000 times and silently returned on exhaustion. It then canceled the caller and read the latest session's flag with another finite poll. All three lifecycle cases also competed against a real 0.1-second deadline; the timeout case used an unrelated 200 ms sleep. A completed wait therefore did not prove any current held producer existed, and the assertion could label correct canceled-before-admission behavior as broken draining.

Temporary, test-only instrumentation held the caller on an explicit continuation **before** it could enter VM, then invoked the unchanged finite helper, canceled the caller, and separately logged exact session count, held state and both ownership flags. Production source was unchanged for this diagnostic. Raw `fix-logs/gate-diagnostic-red2.log` shows:

```text
DIAG before existing wait: caller=heldBeforeVM sessions=0 vmBusy=false a5Owner=false
DIAG existing wait returned: sessions=0 finishWaiting=false vmBusy=false a5Owner=false
DIAG after caller cancel, before admission release: vmBusy=false a5Owner=false
FAIL: DIAG finite helper must not report readiness before held session exists
FAIL: C4 I3 cancelled producer retains owner until actual cleanup drain
=== ASR model center self-test: 480 passed, 2 failed ===
```

The caller was then released and awaited; canceled-before-admission correctly started zero transports. This deterministically proves that the original synchronization helper can return a false readiness premise, without CPU-load fishing, arbitrary sleeps or repeated full-suite runs. Diagnostic patch is retained at `fix-logs/gate-diagnostic-instrumentation.patch` for reproduction against the base; temporary diagnostic invocation/function are absent from the final source.

Initial diagnostic invocation with a private `--diagnose-realtime-admission` argument was refused by runtime bootstrap (exit 64, `gate-diagnostic-red.log`). It did not execute tests and is not behavioral RED. The test-only call was moved into the existing accepted focused entry and rebuilt; `gate-diagnostic-build2.log` exited 0 in 27.80 s, and `gate-diagnostic-red2.log` is the actual controlled RED above. The initial build (`gate-diagnostic-build.log`) also succeeded in 30.42 s.

## Final changes: fixture versus production seam

### Deterministic fixture

`ASRModelCenterReviewSelfTests` now waits via continuations for an exact session ordinal rather than polling `latest`. The cancellation scenario deliberately starts the observer while caller admission is gated, then releases admission, obtains that new session and waits for its actual held finish. After cancellation it waits for that same session's actual held cleanup continuation. Diagnostics identify its ordinal, starts/finishes and both held states; separate VM and A5 assertions supplement, rather than replace or weaken, the original compound ownership assertion.

The cancellation case releases worker finish while cleanup remains held and checks continued ownership. The timeout case releases cleanup while worker finish remains held and checks continued ownership. Both still require old selection/evidence preservation after true drain. Edited-profile validation similarly waits for the exact old session's cleanup before releasing it.

A test-local `DeadlineClock` parks real timer-task sleep continuations. Each registration has a unique ticket; expiration resumes only that exact ticket. Cancellation removes/resumes its pending continuation with CancellationError. The timeout test retains its configured **0.1-second** duration, positively waits for the new held session and timer registration, then expires that timer. The real deadline race, cancellation, A5 cleanup and stable timeout mapping all execute. It also attempts to expire the previous canceled ticket and verifies the successor remains owned. Pending timer counts are zero after cancellation and edited-validation drain. There are no finite-yield waits or arbitrary sleeps in the rewritten realtime lifecycle scenarios.

### Small production dependency injection, unchanged defaults

- `withAsyncDeadline(seconds:sleep:operation:)` adds optional Sendable sleep injection defaulting to nil. Nil executes the **same original** `Task.sleep(for: .seconds(max(0, seconds)))`. The same DeadlineRace implementation owns producer/timer cancellation and winner selection; it was not replaced by a test fake.
- `ASRServiceValidationCoordinator` adds optional `realtimeDeadlineSleep`, default nil, forwarding it to that existing utility. Production realtime timeout remains 15 seconds. All caller signatures remain source compatible; cleanup, VM, native and route behavior are unchanged.
- `SelfTest` invokes the existing `testAsyncDeadline` owner test in the focused `--asr-model-center-only` branch, covering default real timer expiry, default caller cancellation against an uncooperative producer, and normal success. The full-suite branch retains its original single invocation; the focused branch exits before reaching it. This avoids duplicating the default utility test in full registration.

These two production files are dependency seams, not a claimed product cancellation fix. Fresh scoped review must explicitly include their default/source-compatibility and race semantics.

## Verification process

All builds/tests were sequential with no tracked edits during active execution. No full code/artifact/release gates were run or repeated by this implementer. Exact focused command shape:

```sh
swift build > <build-log> 2>&1
swift run --skip-build FlowType --self-test --asr-model-center-only > <model-center-log> 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > <backends-log> 2>&1
```

Paths below are relative to this report directory.

- First deterministic implementation: `fix-logs/gate-fix-green-build.log`, exit 0, 41.72 s, no emitted warnings/errors. `fix-logs/gate-fix-green.log`, exit 0: **496 passed / 0 failed**. This included the existing default utility test in the owner suite before moving that registration to the focused-only branch.
- The first GREEN proved both real boundaries, with raw diagnostics:

```text
C4 cancellation barrier: session=4 starts=1 finishes=1 finishHeld=true cancelled=true cleanupHeld=true vmBusy=true a5Owner=true
C4 timeout barrier: session=5 starts=1 finishes=1 finishHeld=true cancelled=true cleanupHeld=true vmBusy=true a5Owner=true
```

- A final build/model-center run was justified by the test-registration correction, followed by one A5 backend owner suite for the new optional coordinator seam. Final logs/results are appended below after completion.

## Self-review and limits

Reviewed exact waiter registration/resumption, session ordinal capture, cancellation-before-registration handling, timer ticket isolation, separate cleanup/worker lifetimes, and focused/full test dispatch. The original ownership assertions remain, now after positive preconditions; no assertion, timeout category or actual drain requirement was weakened. No VM/native ownership behavior was changed. Historical evidence reports were not overwritten.

All tests use isolated configuration and synthetic session/sample/credentials. No real models/services/network/user configuration/Keychain/microphone/clipboard/permissions/signing/notary/download/push/merge were used. Original full failure remains valid evidence for the old candidate. The new focused evidence does not claim a renewed full gate passed; controller will obtain that only after fresh scoped review of the final candidate.


## Final candidate and results

Final HEAD: `76757c7e5693c0350b67093d1a0750c21b0b214b`.
Sources tree: `a3fb7822700cc8bfda8d8d36240619d13f9bec18`.

| Command | Raw log under fix-logs/ | Exit | Result |
|---|---|---|---|
| swift build | gate-fix-final-build.log | 0 | Build complete, 37.56 s; no emitted warnings/errors |
| swift run --skip-build FlowType --self-test --asr-model-center-only | gate-fix-final-model-center.log | 0 | 496 passed / 0 failed |
| swift run --skip-build FlowType --self-test --asr-backends-only | gate-fix-final-backends.log | 0 | 1,128 passed / 0 failed |

Final model-center log repeats the exact session 4 cancellation / session 5 timeout positive-barrier diagnostics shown above, both with VM and A5 ownership true. Default utility owner checks are included in the focused count. `git diff --check` and `git diff --cached --check` exited 0; final logs have no FAIL/warning/error diagnostics. No source edits followed final verification. Worktree is clean after commit.

Explicit committed files:

```text
Sources/flowtype/Services/Speech/Backends/ASRServiceValidationCoordinator.swift
Sources/flowtype/Testing/ASRModelCenterReviewSelfTests.swift
Sources/flowtype/Testing/SelfTest.swift
Sources/flowtype/Utilities/AsyncDeadline.swift
```

This is ready for the requested fresh scoped review of the four-file delta, including both nil-default production sleeper seams. The original uninstrumented failure's exact scheduler order remains unknown; the diagnosed finite-wait defect is proven by controlled RED and removed without weakening cancellation/drain checks. A renewed full code gate has not been run by this agent and remains the controller's next step after review.
