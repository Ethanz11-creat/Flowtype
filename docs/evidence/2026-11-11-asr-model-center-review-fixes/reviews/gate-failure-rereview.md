# Scoped review of code-gate fixture correction

Date: 2026-11-11. Base: `e0980ec6c8b2c35ca67736cce8520bb51b2f4de1`. Reviewed HEAD: `76757c7e5693c0350b67093d1a0750c21b0b214b`.

Reviewed only the four-file delta supplied in `gate-failure-fix-range.diff`, its diagnostic report/instrumentation and raw evidence, relevant deadline/coordinator semantics, and the fourth Ruling in `fix-progress.md`. Source/index/HEAD remained read-only and the checkout was clean. Prior review reports are preserved; only this report was written. No suites were rerun, no child agents were used, and no real services/models/network/user state/credentials/microphone/clipboard/permissions/signing/notarization were accessed.

## Diagnostic conclusion

The original full code gate remains a **Fail** for e0980ec. Its immutable report identifies code-full exit 1; the actual stderr has the one compound ownership assertion, and stdout reports **28,471 passed / 1 failed**. Those logs do not identify the session or held finish/cleanup state. The precise original interleaving therefore remains unknown; this review does not relabel the failure or claim a demonstrated production ownership regression.

The retained temporary instrumentation and `gate-diagnostic-red2.log` establish a narrower, valid root cause: while caller admission is explicitly held, the old finite-yield waiter returns with **zero sessions, finishWaiting=false, vmBusy=false and a5Owner=false**. Canceling then reproduces the compound assertion's false premise. The behavioral diagnostic reports 480/2, including the explicit false-readiness assertion. This proves that the old helper did not establish what its callers assumed. The initial refused diagnostic argument is not behavioral evidence, consistent with the implementer report.

## Strengths and specification alignment

**The fourth Ruling is satisfied.** The final changes replace false readiness with positive, identity-bound barriers, preserve the actual ownership assertions and exercise the real deadline race through a narrowly scoped sleeper dependency. They do not change VM/native ownership behavior or hide the old failed gate.

- `ASRModelCenterReviewSelfTests.swift:165` deliberately registers the session observer while admission is held. It then releases admission, obtains the exact new session ordinal and waits for that session's held finish and held cleanup. Checks separately inspect VM and A5 ownership and retain the original compound assertion (`:182`). No finite polling or arbitrary sleep remains in these rewritten lifecycle scenarios.
- Cancellation releases finish while cleanup remains held (`:185`); timeout releases cleanup while finish remains held (`:203`). The tests thus preserve both independent lifetime requirements. Final role/evidence checks still reject late canceled/edited success, and timeout still asserts the stable timeout failure after a late worker result.
- `DeadlineClock.sleep` registers a unique ticket and continuation under its lock (`:330`). Cancellation-before-registration is caught by Task.isCancelled; cancellation after registration removes that exact ticket and resumes it with CancellationError. Expiry and cancellation compete to remove the same continuation, preventing double resume. Expiring a removed old ticket cannot resume a successor (`:352`), which is also asserted in the timeout scenario.
- The timeout test keeps the configured 0.1-second value, waits for the exact timer and held producer, and explicitly expires that timer. It runs the existing DeadlineRace and coordinator cleanup rather than substituting a fake timeout result. Cancellation and edited-validation completion assert zero pending timer continuations.

The new test observers are exact event barriers, not general-purpose cancellable services. In the inspected scenarios each admission/session/finish/cleanup/timer observer has a matching explicit event and each owned operation is awaited. I found no intrinsic lost-wakeup, double-resume or circular-wait defect in these paths. A future production regression that prevents a promised event could make an event-waiting test stall; that is not evidence of a current fixture deadlock and must not be converted into false readiness by restoring a finite-yield fallback.

## Production seam and compatibility

`AsyncDeadline.swift:8` adds an optional Sendable sleeper with nil default. Nil executes the same original `Task.sleep(for: .seconds(max(0, seconds)))`; the producer, timer, DeadlineRace locking/winner selection/install-after-completion handling and caller cancellation are unchanged. The injected path receives the same clamped duration. The function remains source-compatible with existing labeled-operation and trailing-closure calls.

`ASRServiceValidationCoordinator.swift:46` adds a final optional nil-default `realtimeDeadlineSleep` and forwards it at the existing deadline call. The default realtime timeout remains 15 seconds. Its cancellation cleanup still cancels ingress/session and joins the actual sample worker before relinquishing the A5 owner. No changed route, selection, credential or persistence behavior was found.

The existing default-utility test is added only to the focused `--asr-model-center-only` branch (`SelfTest.swift:420`). That branch calls `finish`, whose return type is Never and which exits the process. The unchanged full-suite call at `:574` is therefore still the only invocation in a normal full run; a focused run also gets exactly one. Its real-default timeout, cancellation and success checks remain intact.

## Issues

- Critical: none found in this four-file delta.
- Important: none found in this four-file delta.
- Minor: none found in this four-file delta.

## Evidence checked

Read the final logs without executing their commands:

- `gate-fix-final-build.log`: build complete in 37.56 seconds, no warning/error diagnostics found.
- `gate-fix-final-model-center.log`: **496 passed / 0 failed**. Cancellation session 4 and timeout session 5 each report starts=1, finishes=1, finishHeld=true, cancelled=true, cleanupHeld=true, vmBusy=true and a5Owner=true at their positive barriers.
- `gate-fix-final-backends.log`: **1,128 passed / 0 failed**.

These focused results support the correction but do not establish a renewed full-gate Pass. Prior focused evidence and original failed full evidence remain attached to their respective candidates.

## Declined to judge

- Behavior outside this four-file delta was not re-audited; I1/I2/I3/M1 and R1 retain their previously closed dispositions.
- The exact historical full-run scheduler interleaving cannot be determined from its uninstrumented evidence; this is an evidence limit, not a specification exclusion.
- No behavior within this scoped correction was dismissed as outside the specification.

## Assessment

**Scoped review: clean.** The proven fixture synchronization defect is corrected without weakening ownership/drain requirements, and the small nil-default production seams preserve existing runtime behavior. No further source correction is recommended by this scoped review.

Candidate `76757c7e5693c0350b67093d1a0750c21b0b214b` is ready for the controller's renewed full code gate. The rerun is justified by the changed source and focused verification, not by retrying an unexplained failure until green; artifact/release gates should follow the required full-code outcome.

**Formal release readiness remains Pending.** This review does not replace the full candidate gates, the 71 actual manual/device checks, current remote CI or formal distribution evidence.
