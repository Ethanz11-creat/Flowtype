### Task 1: Audio-driven diffusion waveform

**Files:** Modify `Services/AudioRecorder.swift`, `Core/Pipeline/Stages/RecordingStage.swift`, `Core/Pipeline/SessionContext.swift`, `Core/PipelineOrchestrator.swift`, `UI/AudioVisualizer.swift` under `Sources/flowtype`; create focused visualization frame/motion types under `Services/` or `UI/`; create `Testing/CapsuleWaveformSelfTests.swift`; register in `Testing/SelfTest.swift`.

**Interfaces:** Consumes existing normalized spectrum/PCM and session ownership. Produces `AudioVisualizationFrame` containing normalized frequency detail plus absolute RMS/level, and `SessionController.visualizationFrame` published for the view, scoped/reset like existing spectrum. Preserve `RecordingOutput(spectrum:)` compatibility for existing capture fixtures; live capture must carry real amplitude through a single ordered data stream (no unbounded duplicate stream). Expose deterministic motion math accepting elapsed time so tests do not need wall-clock delays. Task 2 consumes `AudioVisualizer` unchanged and may read the frame for previews.

- [ ] Add focused `--capsule-waveform-only` self-test entry. First test real PCM-derived quiet/loud order (including sustained signals), silence and empty/nonfinite samples; record a failing run before implementation.
- [ ] Implement frame transport; use bounded newest buffering for visualization, finish/cancel cleanly, preserve recorder owner checks. Do not change ASR buffers/results. Keep legacy spectrum consumers/tests source-compatible.
- [ ] Implement deterministic center-to-edge diffusion with stable slight asymmetry, time-based quick rise/slower decay and fixed 2…18 output. Assert finite 10-bar outputs, delayed outer response to a short pulse, quiet/loud separation, silence/stale decay to exact rest, and equivalent results for different render intervals within tolerance. Reset/session regression must cover late callback invalidation.
- [ ] Render ten 2pt rounded bars at 2pt gaps in 40 × 24, blue-purple, no per-frame implicit animation stacking. Tick only while recording and reset on session changes; no fake activity under silence.
- [ ] Run build + focused waveform tests and affected recording/recovery regressions; document commands, counts and any limitations in report. Full suite is reserved for final validation.
- [ ] Self-review and commit `feat(capsule): add audio-driven diffusion waveform`.

