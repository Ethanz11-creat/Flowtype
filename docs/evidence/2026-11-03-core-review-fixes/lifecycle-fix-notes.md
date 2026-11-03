# CORE-03 / CORE-04 receiving-code-review fix notes

Reviewed the actual baseline call paths before changing code. CORE-03 is confirmed: `finish()` synchronously calls the AsyncStream termination handler, which called stop while the same nonrecursive state lock was held. CORE-04 is confirmed: nonisolated startup registered `Timer.scheduledTimer` on an unserviced generic-worker RunLoop. Both were pre-existing issues and neither requires adopting Typeless's private protocol.

## Scope and implementation

- `StreamingPreviewSession` owns one stream's result, continuation, cleanup actions and timeout. Terminal result ownership is claimed under a lock; `yield`, `finish`, `endAudio`, `cancel` and all other client callouts run outside it. Reentrant stop is idempotent. Setup actions arriving after termination are immediately cleaned. Late callbacks cannot replace finished text.
- AppleSpeechProvider captures that session in each recognition callback instead of mutating shared current recognition state. Its current request/session pair is snapshotted under its provider lock and used outside. A later start detaches and stops its old preview before authorization/setup, preventing reuse of old fallback text.
- `DispatchCancellableTimer` uses a serviced private serial dispatch queue, monotonic dispatch deadlines and generation checks. Cancelling outside that queue drains a callback already running; self-cancellation avoids a sync dispatch onto the same queue.
- `RecordingHeartbeat` is the actual production progress/watchdog owner used by AudioRecorder. It tracks tap progress using system uptime, scopes start/progress/cancel to recording ownership, and invokes frozen notification before completing visualization. Registration is protected against stop-before-schedule resurrection. Cancelled/replaced recordings cannot refresh or cancel the current watchdog.

## Focused evidence

`core04-red.txt`: executed the unchanged baseline CancellableTimer source in Swift 6 from a generic async worker. A 10ms repeating timer received **0 callbacks over 100ms**, expected more than zero; probe exit **1**. This is a behavior reproduction of the concrete scheduler bug, without microphone access.

`core03-red-characterization.txt`: safe AsyncStream synchronous-termination probe showed the caller lock unavailable inside the termination callback. The expected lock-free-callout property failed; probe exit **1**. This is a framework-semantics characterization plus the inspected baseline call chain, **not** a claim that the entire old Apple provider was executed. An actual nonrecursive-lock crash/deadlock was deliberately not triggered. The new production owner did not exist at baseline, so its new regression tests were not run against a fictional pre-existing API.

`CoreLifecycleRegressionSelfTests.run` contains **33** checks against the actual production session, timer and watchdog owners. Standalone Swift 6 compilation with only a Reporter shim passed **33/0** (`lifecycle-green.txt`); no app or framework recognizer was initialized. Covered: final/error/explicit-stop cleanup; reentrant termination and exactly-once resource release; consumer cancellation; late result/task setup; preview timeout from a worker; scheduled timer cancellation/replacement; watchdog starvation before any buffer and after synthetic progress; no premature expiry following progress; notify-before-finish order; stale-owner progress/cancel; normal-stop suppression.

The watchdog tests use an injected monotonic clock and real serviced scheduler, avoiding a fake direct invocation of onRecordingFrozen. AudioRecorder's actual wiring calls this owner's start/recordTap/cancel; real hardware route behavior remains separate acceptance work.

## Verification ownership and limits

Child did not run package build/full suite or commit; parent owns shared builds, focused/full registration and final candidate gates. One parent build found a duplicate local binding in AppleSpeechProvider; it was corrected by renaming the replacement snapshot. The first standalone run covered 25 checks before production watchdog extraction; the final 33-check run supersedes it.

No microphone, Speech authorization request, model inference, cloud request, keyboard/clipboard effect, installation or push was performed. Actual device freeze/unplug/Bluetooth recovery and Speech-framework behavior remain manual Pending. Synthetic ownership/termination tests do not imply physical-device acceptance.

Lock ordering checked: no state lock is held across user/framework callbacks; preview finish releases its own lock before timer cancellation; watchdog callbacks never acquire AudioRecorder.lifecycleLock. The current recorder's frozen callback only sets its independent flag. Holding the recorder lifecycle lock during cancellation therefore cannot invert against watchdog callback draining.
