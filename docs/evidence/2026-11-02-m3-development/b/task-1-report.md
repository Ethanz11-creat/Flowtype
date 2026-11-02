# M3-B Task 1 implementation report

Base: `7c6c130` (`feat(delivery): present honest last delivery outcomes`).
Commit: `d9111f1` — `feat(asr): add cancellable conservative silence preflight`.

## Implemented

- Added `SpeechPreflightUnknownReason`, `SpeechPreflightDecision`, immutable `SpeechPreflightPolicy.conservative`, and the synchronous `SpeechPreflightAnalyzer` seam.
- Conservative policy is exactly 16000 Hz, 320 samples/frame, 1600 minimum samples, Float32 maximum frame RMS 0.0003 and peak 0.001. These remain initial microphone-calibration candidates, not validated real-world thresholds.
- Pure `analyze` scans original samples, accumulates each full/partial frame in Double, converts RMS to Float32 before comparing the candidate boundary, and tracks total peak. No normalization, cropping, full-frame copies, VAD, I/O, models, or network. O(n) time / O(1) additional statistics storage.
- Empty capture is independent of rate; unsupported nonempty rates are indeterminate; all valid short inputs remain indeterminate. Samples must be finite and within inclusive [-1, 1]. The scanner never stops just because sound is found, so later invalid data wins. Cancellation is checked before scanning, at every frame, and before classification.
- `evaluate` explicitly creates a detached synchronous worker, forwards caller cancellation using `withTaskCancellationHandler`, awaits worker exit, then checks caller cancellation before publishing any decision. Cancellation also takes precedence over a late analyzer error; non-cancellation analyzer errors propagate unchanged.
- Added `pure` and MainActor `background` entries to both `--m3-silence-only` and the full suite, preserving `--m3-delivery-only`. Separate opt-in `--m3-silence-benchmark-only` is excluded from routine suites.
- ASRStage/pipeline integration is deliberately left to B2. No GUI, app packaging, user configuration, permissions, user audio, dependency, model, or cache changes were made.

## TDD evidence

All logs below are in `.superpowers/sdd/2026-11-02-m3-b-silence-preflight/`.

1. Pure RED: `swift run FlowType --self-test --m3-silence-only`, exit **1**, `task-1-pure-red.log`.
   - Declarations plus an unavailable-only placeholder allowed real assertions to execute before scanner implementation.
   - `=== M3 silence self-test: 0 passed, 703 failed ===`
   - Example: `five-second digital silence — got indeterminate(...detectorUnavailable), want clearlySilent`.
   - Expected: the actual PCM decision behavior was absent.
2. Pure GREEN: same command, exit **0**, `task-1-pure-green.log`.
   - `=== M3 silence self-test: 703 passed, 0 failed ===`
3. Background RED: same command, exit **1**, `task-1-background-red.log`.
   - Initial wrapper detached the real synchronous analyzer but did not forward or enforce cancellation.
   - `=== M3 silence self-test: 735 passed, 6 failed ===`
   - Failures: `cancel-return` cancellation did not reach worker; canceled analyzer published success; `cancel-cooperative` cancellation did not reach worker; canceled cooperative analyzer published success; production long-PCM cancellation returned success; pre-cancelled empty evaluation returned success.
   - Expected: detached task cancellation does not propagate automatically, and simply awaiting its value does not reject canceled results.
4. Focused GREEN after cancellation implementation and two additional mixed-frame RMS fixtures: same command, exit **0**, `task-1-focused-green.log`.
   - `=== M3 silence self-test: 741 passed, 0 failed ===`

## Coverage and self-review

- Digital silence; empty input; 50 ms, 1599-sample, and exact 100 ms inputs; unsupported rates; inclusive normalized sample endpoints.
- Exact Float32 RMS and peak boundaries, adjacent representable values, positive/negative peaks, and a lone first/last peak.
- Every tail length 1...319 has both a final-peak and tail-RMS fixture. Tail RMS uses the actual partial count rather than 320.
- Low synthetic sine below both candidates and a sine exceeding RMS while below peak; sound after six seconds; one energetic frame surrounded by silence; frames containing both quiet and signal samples.
- NaN, both infinities, both over-range signs, first/middle/tail invalid samples, and invalid short inputs, including invalid data following earlier sound.
- Real `evaluate` production default handles silence, signal, and invalid tail. A synchronous semaphore barrier tests the actual detached wrapper from MainActor: unchanged input forwarding, off-main execution, heartbeat responsiveness, cancellation propagation, no early return before worker exit, stale-success suppression, cooperative cancellation, and unchanged ordinary errors. Bounded barrier timeouts make actor regressions fail without hanging the suite.
- A real 180-second synthetic PCM buffer exercises cancellation through the default analyzer, with no seam. Pre-cancelled evaluation is covered.
- Reviewed all three assigned files and their diff; no correctness issue found. Existing large `SelfTest.swift` was changed only for registration (13 lines); no unrelated restructuring.
- Compiler recompilation emitted the pre-existing unrelated `AppLogger.swift:27` warning that `nonisolated(unsafe)` is unnecessary on a Sendable DispatchQueue constant. No new assigned-file warning appeared.

## One separate 30-minute synthetic benchmark

Command, run exactly once: `swift run FlowType --self-test --m3-silence-benchmark-only`.
Log: `task-1-benchmark.log`; exit **0**, `3 passed, 0 failed`.

- Build mode: SwiftPM default **debug**, no release optimization claim.
- Toolchain: Apple Swift **6.2.1**, target `arm64-apple-macosx15.0`.
- Hardware: **Apple M1**, **8 logical CPUs**, **17179869184 bytes / 16 GiB RAM**.
- OS: **macOS 15.7.9**, build **24G830**.
- Input: **28,800,000 Float32 zeros**, mono **16000 Hz**, 30 minutes / 115,200,000 PCM bytes. Allocation occurs before timing; the same synthetic immutable buffer is reused. No user recording is copied.
- Production `analyze`: **4.535130541 seconds**, `clearlySilent`.
- Production default `evaluate`: **4.530749708 seconds**, `clearlySilent`.
- Production default cancellation: requested **0.003298541 seconds** after task creation; **0.000080167 seconds (~0.080 ms)** from request until worker exit/result observation; `CancellationError()`.
- This is one observation on this debug build and hardware, not a performance gate for all machines. No sample was discarded to improve throughput.

## Required sequential final verification

1. `swift build`, exit **0**, `task-1-build.log`: `Build complete! (23.98s)`.
2. `swift run FlowType --self-test`, exit **0**, `task-1-full-self-test.log`: `=== self-test: 3629 passed, 0 failed ===` (build stage completed in 7.18s). No failure, warning, or error line in this final run.

No `swift test` was run. Controller owns independent review, app packaging, source/bundle gate, and real-microphone acceptance. No implementation correctness concerns identified; calibration and B2 integration remain the planned next scope.

## Files / commit scope

- `Sources/flowtype/Services/Speech/SpeechPreflight.swift`
- `Sources/flowtype/Testing/M3SpeechPreflightSelfTests.swift`
- `Sources/flowtype/Testing/SelfTest.swift`

Only these three source/test files were staged and committed. `git diff --cached --check` passed before commit. This ignored report/log directory is available to the controller for evidence archival. Existing controller plan/spec/audit/evidence edits and archive are preserved and excluded from the implementation commit.
