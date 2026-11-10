# Task D1 — health timer ownership and CI baseline

Baseline: `aacf49a`; worktree `/Users/yiheng/pycode/flowtype-local`, branch `flowtype-local`.

## Scope and diagnosis

Read the exact D1 brief and parent spec. No dependency updates. Production remains an actual `.main` DispatchSourceTimer with the existing nil-owner and UUID generation guards. WindowManager now accepts a MainActor EventTapHealthScheduler and owns its cancellation token. Fake scheduling exists only in M5SmokeSelfTests. Existing artifact smoke timer evidence is unchanged.

Historical evidence was already downloaded under `build/ci-release-assessment-41672136709`; verified the report and code-full child stdout/stderr. Run https://github.com/Ethanz11-creat/Flowtype/actions/runs/41672136709 is source `288aa9a6d02ce966a05dbd3fe71a6e26f6a9ad21`, Sources tree `eeab631f159fc5ad0820e45fe03edaacbbb237b9`, clean. It reports code-build Pass, code-full Fail (`fullTestFailed`, exit 1), source-end Pass. Exact stdout: `=== self-test: 25919 passed, 1 failed ===`. Exact stderr: `✗ FAIL: M5 actual health timer advances once per interval`. The 110ms assertion required 2...4 callbacks of a 30ms timer but did not print actual elapsed/ticks. Historical evidence alone cannot distinguish delayed delivery from delayed continuation/extra callbacks or a lifecycle issue.

Ruling agreed with controller: existing owner/generation guards are not assumed broken. Use historical CI as the original RED (brief explicitly permits this), instrument the original assertion locally, then prove ownership deterministically and real callback liveness within 2 seconds. Supplement with independent guard-removal mutation checks. No claim of remotely passing CI; no push.

## Test-first / RED evidence

Sequential original-instrumentation commands:

- `swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/baseline-build.log 2>&1` — exit 0, `Build complete! (36.79s)`.
- `swift run --skip-build FlowType --self-test --m5-smoke-contract-only > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/baseline-focused.log 2>&1` — exit 0, `58 passed, 0 failed`. Observations: elapsed `0.117490042 seconds`, ticks `3`, startCalls `2`, cancelCalls `0`; after stop elapsed `0.188437667 seconds`, ticks `3`, startCalls `2`, cancelCalls `1`. This is a local pass, not reproduced historical RED.

Added ownership/liveness tests before introducing the production scheduling seam. `swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/test-first-build.log 2>&1` exited 1 because the required `EventTapHealthScheduler` / `EventTapHealthTimer` types and injected initializer parameter did not exist. This is an API compilation failure, not a runtime regression failure; historical CI is the original runtime RED.

## First GREEN

- `swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/green-build.log 2>&1` — exit 0, `Build complete! (47.95s)`.
- `swift run --skip-build FlowType --self-test --m5-smoke-contract-only > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/green-focused.log 2>&1` — exit 0, `70 passed, 0 failed`.
- Manual scheduler: ticks `3`, schedules `2`, cancels `2` (includes a restart). Explicit callbacks independently assert tick 1, tick 2, cancellation no tick, stale callback during a restarted generation no tick, new generation one tick. Duplicate start schedules once, interval forwarded, separate owner untouched, double stop cancels once.
- Actual production scheduler: elapsed `0.063673417 seconds`, ticks `2`, callbacksWithinDeadline `2`, startCalls `2`, cancelCalls `0`; stopped elapsed `0.133772042 seconds`, ticks `2`, startCalls `2`, cancelCalls `1`.

## Independent mutation RED checks

Sequential mutations were applied separately to `WindowManager.swift`, always restoring the exact original source in a `finally` block. Each ran `swift build` followed, only after build exit 0, by `swift run --skip-build FlowType --self-test --m5-smoke-contract-only`. Logs are `task-D1-logs/mutation-{owner,generation}-{build,focused}.log`; exit summary is `task-D1-logs/mutation-results.json`.

- Owner mutation: remove only `guard eventTapHealthTimer == nil else { return }`. Build exit 0 (`43.82s`); focused exit 1 (`64 passed, 6 failed`). Exact failures:

```text
  ✗ FAIL: duplicate start has one scheduled timer — got 2, want 1
  ✗ FAIL: M5 owner forwards health interval to scheduler — got [0.03, 0.03], want [0.03]
  ✗ FAIL: M5 one tick for first explicit callback — got 0, want 1
  ✗ FAIL: one tick per callback — got 0, want 2
  ✗ FAIL: M5 stopping twice cancels the owned timer once — got 0, want 1
  ✗ FAIL: M5 restart schedules exactly one new timer — got 4, want 2
```

- Generation mutation: preserve owner guard, replace `guard let self, self.healthGeneration == generation else { return }` with `guard let self else { return }`. Build exit 0 (`23.93s`); focused exit 1 (`67 passed, 3 failed`). Exact failures:

```text
  ✗ FAIL: cancelled generation cannot tick — got 3, want 2
  ✗ FAIL: M5 old generation cannot tick a restarted owner — got 4, want 2
  ✗ FAIL: M5 restarted generation advances once per callback — got 5, want 3
```

These deliberate defects are caught independently; unmodified guards pass. They establish regression-test sensitivity, not evidence that the historical production owner/generation implementation had either defect.

## Final GREEN sequence

- `swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/final-build.log 2>&1` — exit 0, `Build complete! (53.87s)`; follows restoration of both independent mutations.
- `swift run --skip-build FlowType --self-test --m5-smoke-contract-only > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/final-focused.log 2>&1` — exit 0:

```text
=== FlowType --self-test ===
M5 manual health timer: ticks=3 schedules=2 cancels=2
M5 actual health timer: elapsed=0.070925917 seconds ticks=2 callbacksWithinDeadline=2 startCalls=2 cancelCalls=0
M5 actual health timer stopped: elapsed=0.140997459 seconds ticks=2 startCalls=2 cancelCalls=1
=== M5 smoke contract self-test: 70 passed, 0 failed ===
```

- `./scripts/verify.sh --lane code > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/final-code-lane.log 2>&1` — exit 1. Report `build/verification/46AD161B-298D-469C-B634-025FAC270EC0/verify-report.json`: source-start/platform-os/platform-arch/platform-swift/code-build/code-full all Pass; source-end Fail `sourceChanged`. Code-full stdout: `=== self-test: 25932 passed, 0 failed ===`, stderr empty. Actual timer elapsed `0.063485334 seconds`, 2 callbacks; after cancellation `0.133798667 seconds`, still 2 ticks.
- Cause of sourceChanged: I created the tracked-scope baseline evidence document while the lane was active. This is an avoidable implementer workflow error, not a timer/product failure and not an all-phase Pass. Controller was informed and directed freezing/committing all task files before the necessary rerun. Original failed report retained.
- Commit `722e109` (`fix: verify health timer ownership without fragile timing counts`) contains the implementation and initial evidence. `git status --short` was empty immediately before the stable-source rerun. No tracked-scope writes will occur during that rerun.
- `./scripts/verify.sh --lane code > .superpowers/sdd/2026-11-09-asr-model-center/task-D1-logs/stable-code-lane.log 2>&1` — exit 0, `Verification code: Pass`. Second invocation justified solely by source-end failure. All report updates during execution were confined to this ignored task workspace. Report `build/verification/68B52C4B-5DE8-4928-AD95-3A4B08F2DAC4/verify-report.json` has all seven phases Pass: source-start/platform-os/platform-arch/platform-swift/code-build/code-full/source-end, each exit 0, no timeout or failure. Clean source git SHA `722e109b00a487073630fe1b2f745b49503d6967`; Sources tree `6ef9813355c20da71c689bc0742cd325f06c257f`. Exact suite summary: `=== self-test: 25932 passed, 0 failed ===`; stderr empty. Manual scheduler ticks=3/schedules=2/cancels=2; actual timer 2 callbacks at `0.069680459 seconds`, stopped still 2 at `0.140093667 seconds`. Raw report and log hashes archived in docs evidence.

`startCalls` and `cancelCalls` diagnostics count test entry-point calls (two starts, one stop); actual scheduling/cancellation counts are separately measured by the injected manual scheduler. All large logs remain ignored in this task workspace.

## Self-review

Read the complete source diff and scheduler file. `git diff --check` passed. Production continues main-queue DispatchSource scheduling at the unchanged default 5-second interval, handler clearing/cancellation, weak owner capture, generation invalidation before cancel, and increments of the existing `windowHealthTicks`. No async actor hop was introduced. Test fake deliberately retains cancelled callbacks so it cannot hide stale-generation bugs. Other window instance remains untouched; restart and repeated stop tested. The real liveness loop reads actual ticks only while the continuous-clock deadline is still open and never translates sleep duration into callback evidence.

Existing `StartupSmoke.swift` still waits for elapsed >= 6 seconds plus both router/window actual timer counts advancing; `ValidationReport.swift` still rejects duration < 6000ms or either actual count < 1 with `.timerDeadline`. Neither file changed. No artifact/release gate weakening, skip, user configuration, Keychain, models, permission prompts, microphone, clipboard, push or publishing.

## Completion

Implementation committed `722e109`; stable code lane passes all phases. Docs-only followup commit `1d8583b` (`docs: record stable D1 code baseline evidence`) records the result without changing verified Sources tree. After that commit, `git status --short` is empty and `git rev-parse HEAD:Sources` remains `6ef9813355c20da71c689bc0742cd325f06c257f`. Remote SHA CI remains Pending/unverified; historical remote failure retained. No remaining D1 implementation concerns. One necessary rerun was caused by the documented avoidable evidence-writing workflow error.

## Files changed

- `Sources/flowtype/WindowManager.swift` — inject scheduling and own its cancellable token; preserve guards/ticks.
- `Sources/flowtype/Utilities/EventTapHealthScheduler.swift` — MainActor scheduler/token protocols and production main DispatchSource implementation.
- `Sources/flowtype/Testing/M5SmokeSelfTests.swift` — deterministic owner/generation regressions, real callback liveness and diagnostics; retain smoke evidence assertions.
- `docs/superpowers/validation/2026-11-09-asr-model-center-D1-baseline.md` — standalone historical/current baseline distinction and pending release/remote gates.
- `docs/evidence/2026-11-09-asr-model-center/d1-historical-ci.json` — preserved historical run/report/failure plus hashes.
- `docs/evidence/2026-11-09-asr-model-center/d1-local-code.json` — exact stable local report.
- `docs/evidence/2026-11-09-asr-model-center/d1-local-code-summary.json` — source identity, timer observations, full-suite log hashes and prior local sourceChanged failure.

Self-review: no outstanding findings. Source staged diff and docs evidence checked; final commit remains local, no push or publish.
