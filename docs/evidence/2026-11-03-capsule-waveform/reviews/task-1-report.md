# Task 1 report — audio-driven diffusion waveform

Status: implemented, self-reviewed, focused verification green. Parent owns Task 2, plan/ledger updates and final full code/artifact lanes.

Base: `55e5ac8c93bffb93d3bd5e65045b1f93c65b7f63` on existing `flowtype-local` branch. Commit: `139e123` (`feat(capsule): add audio-driven diffusion waveform`), containing only the 10 owned source files.

## Result and API for Task 2

- `AudioVisualizer()` remains the same environment-object view API. It reads `session.visualizationFrame` and `session.sessionState.isRecordingIndicator`; identity is `session.currentSessionIdentifier`. Native content is 10 rounded bars, width 2 / gap 2 (38 intrinsic points) in a 40 × 24 region, exact rest 2 and strict upper bound 18. Colors interpolate brand purple to blue. No implicit height animations; `TimelineView` ticks only while recording, resets history when recording ends or session identity changes.
- `AudioVisualizationFrame(samples: [Float], spectrum: [Float], timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime)` is `Sendable, Equatable`. Read-only fields: `spectrum` (sanitized normalized frequency detail), `rms` (absolute PCM RMS), `timestamp` (monotonic uptime). Computed `level` uses a fixed -60…-12 dB mapping, with no adaptive loudness normalization. `.silence` is the exact rest/reset frame. Invalid PCM contributes silence; out-of-range PCM clips only for visualization. ASR PCM is untouched.
- `SessionController.visualizationFrame: AudioVisualizationFrame` is an observable, read-only computed property over private storage. It intentionally uses guarded explicit `objectWillChange` publication, **not** `@Published` / `$visualizationFrame`: a real synchronous observer test proved that `@Published` willSet can restore stale energy after cancellation. The controller checks context identity, session ownership, cancellation, recording state and generation after notification before assignment. There is no projected publisher API for Task 2 to depend on; ordinary SwiftUI environment-object observation works.
- Synthetic native preview input can use an isolated stage's `context.markReady()` and `context.publishVisualization(AudioVisualizationFrame(samples: ..., spectrum: ..., timestamp: ProcessInfo.processInfo.systemUptime))`. Old `context.spectrumPublisher`/`currentSpectrum` remain compatibility APIs, but new previews should publish complete frames to exercise honest amplitude. Legacy normalized spectrum alone intentionally produces zero loudness.
- `SessionContext.currentVisualizationFrame`, `visualizationPublisher` and `publishVisualization(_:)` transport the complete frame and reject cancellation. The existing synchronous spectrum publisher still gets the same frame's spectrum; there is no secondary asynchronous live stream or forwarding Task.
- `RecordingOutput(visualizationFrames: AsyncStream<AudioVisualizationFrame>)` and `.visualizationFrames` provide a lazy `RecordingVisualizationSequence`. Existing `RecordingOutput(spectrum: AsyncStream<[Float]>)` fixtures still compile, with zero RMS added lazily. Existing `for await ... in output.spectrum` remains supported: the computed property is an `AsyncMapSequence<RecordingVisualizationSequence, [Float]>`, not an independently buffered `AsyncStream`. Consume one representation per output, as before; they share one input source.
- `RecordingOutput.makeVisualizationStream()` creates the actual live newest-1 bounded stream/continuation pair; tested via that same production factory. Finish and cancellation propagate without a forwarding task. The audio tap captures its own continuation and analyzer rather than looking up the current session's producer/analyzer.
- `DiffusionWaveform.accept(_:)`, `.reset()`, `.heights(at: TimeInterval, reduceMotion: Bool = false)` expose deterministic motion. The timestamp and query time are in the same monotonic seconds domain; tests use synthetic elapsed seconds. Ten outputs are bounded and finite. 35ms rise / 180ms decay, ~33ms per outward step plus stable slight asymmetry; frequency detail contributes only a small shape term. Missing callbacks release after 250ms, then settle to exact 2. History is bounded by 3 seconds / 128 frames. Render calls do not mutate motion, so different rendering intervals produce identical values at equal time.
- Reduce Motion removes travel and restrains amplitude; the view uses a 100ms minimum tick interval in that mode. Real amplitude still distinguishes quiet/loud; silence/stale input still rests. No random, synthetic sine or silent baseline motion is used in production.

## TDD and verification evidence

All logs below live in `.superpowers/sdd/2026-11-03-capsule-waveform/`. No full suite was run, per parent instruction reserving full lanes for final combined validation.

1. Added focused `--capsule-waveform-only` flag to both `SelfTest` and `RuntimeOptions.selfTestFilters`, plus full-run registration. Wrote PCM/motion checks against safe rest stubs.
2. `swift build > task-1-red-build.log 2>&1`: exit 0.
3. `.build/debug/FlowType --self-test --capsule-waveform-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-1-red-run`: **12 passed / 7 failed**, expected behavioral RED, recorded in `task-1-red.stdout` and `.stderr`. Failure names: actual quiet/loud sine PCM RMS; absolute quiet/loud separation; center-before-edge; delayed short pulse; stable asymmetry; sustained quiet/loud separation. The shell wrapper printed these files after running and therefore reported its final `cat` exit status rather than the test status; the test summary/stderr are the red evidence.
4. Implemented the frame/math/transport/native view. A first green-build attempt failed with a stale `self.spectrumAnalyzer` reference after moving the analyzer to the engine scope. I corrected it before the previous SwiftPM siblings fully exited, causing that prior attempt to also report `input file ... AudioRecorder.swift was modified during the build`. A second build waited for the first and then succeeded. Both attempts accidentally shared `task-1-green-build.log`, so it contains mixed/sparse output and is **superseded**, not final build evidence. Subsequent builds used unique filenames and no edits while compiling.
5. Initial green focused run (`task-1-green-run`, stdout/stderr): exit 0, **19 passed / 0 failed**.
6. Added real controller lifecycle checks, legacy/live stream adaptation, buffering, cancellation, malformed data and reduced-motion checks. Production stream factory initially had a safe unbounded stub to expose missing newest buffering. `swift build > task-1-lifecycle-red-build.log 2>&1`: exit 0. Focused `task-1-lifecycle-red-run`: exit 1, **40 passed / 4 failed**. Expected failures: newest whole frame, drain newest then finish, clear on stop, ignore queued-after-stop frame.
7. Added actual `objectWillChange` observer that synchronously cancels during frame publication. `swift build > task-1-publication-red-build.log 2>&1`: exit 0. Focused `task-1-publication-red-run`: exit 1, **40 passed / 5 failed**. The fifth failure demonstrates stale frame restored by @Published after synchronous cancel.
8. Replaced factory policy with `.bufferingNewest(1)`, added non-recording clear/reject behavior, and guarded explicit frame publication. `swift build > task-1-final-build.log 2>&1`: exit 0, **Build complete (40.78s)**. Final log contains no errors and 3 pre-existing AudioRecorder warnings: mutable `deviceIDSize`, reference/mutation of converter `inputConsumed` captured var. Those lines' semantics are unchanged.
9. Final focused commands ran independently with distinct isolated roots; each stdout/stderr was fully inspected, all stderr empty:

```sh
.build/debug/FlowType --self-test --capsule-waveform-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-waveform-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-waveform.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-waveform.stderr
# exit 0: 45 passed / 0 failed

.build/debug/FlowType --self-test --m4-recovery-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-m4-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-m4.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-m4.stderr
# exit 0: 19788 passed / 0 failed; includes RecordingStageTerminationSelfTests startup/freeze/healthy stop/cancel drains

.build/debug/FlowType --self-test --native-client-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-native-run > .superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-native.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/task-1-final-native.stderr
# exit 0: 938 passed / 0 failed; includes TrialSessionSelfTests session resource/ownership/lifecycle regressions
```

`git diff --check`: exit 0. Reviewed the complete owned diff and new source files. No model, cloud, microphone, permission mutation or clipboard effects were invoked. No new dependencies.

## Owned files

- `Sources/flowtype/Services/AudioRecorder.swift`
- `Sources/flowtype/Services/AudioVisualizationFrame.swift` (new)
- `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift`
- `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- `Sources/flowtype/Core/PipelineOrchestrator.swift` (waveform storage/publication/reset only)
- `Sources/flowtype/UI/AudioVisualizer.swift`
- `Sources/flowtype/UI/DiffusionWaveform.swift` (new)
- `Sources/flowtype/Testing/CapsuleWaveformSelfTests.swift` (new)
- `Sources/flowtype/Testing/SelfTest.swift`
- `Sources/flowtype/App/RuntimeEnvironment.swift` (required flag allowlist)

## Decisions, limitations and concerns

- Chose explicit guarded observable frame storage instead of @Published based on the failing real reentrancy test; parent acknowledged this interface choice. Ordinary consumers still read `session.visualizationFrame`.
- Legacy spectrum fixtures carry zero RMS rather than infer volume from normalized frequency detail. This preserves fixture execution/termination without inventing loudness; native waveform previews need complete PCM frames.
- Absolute RMS/dB mapping and 250ms staleness cutoff are fixed, independent of FFT normalization. Real hardware voice feel and noise-floor tuning remain manual checks; Task 1 deliberately does not change audio precheck/VAD/recognition.
- Native render screenshots and combined capsule geometry are Task 2/final responsibilities. This task verifies native view compilation and deterministic geometry/math, not actual microphone behavior.
- No unresolved test failures in the final focused runs. Parent-owned plan/spec edits were left unstaged. Scratch report/logs are intentionally not committed.
