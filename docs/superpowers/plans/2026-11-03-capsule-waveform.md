# Capsule and waveform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Implement the approved compact native frosted capsule and audio-driven diffusion waveform.

**Architecture:** Keep existing recording and recovery ownership intact. Carry absolute PCM energy with visualization data; isolate deterministic motion math from SwiftUI. Keep capsule copy/timing in testable presentation logic, while controller timers are scoped to the current session and operation.

**Tech Stack:** Swift 6.2, macOS 15+, SwiftUI/AppKit, existing Combine/audio/self-test infrastructure.

**Spec:** `docs/superpowers/specs/2026-11-03-capsule-waveform.md`

## Global Constraints

- Existing linked worktree and branch `flowtype-local`; at most one active subagent, no child delegation.
- No new dependencies, cloud requests, model downloads, permission mutations or real clipboard writes.
- Ordinary capsule 216 × 54, radius 27; recovery 380 × 156; typography 13/11pt.
- Ten bars, width/gap 2, rest 2, max 18, 40 × 24 region; real amplitude, no fake activity.
- Preserve M1–M5 lifecycle, focus, cleanup and publication safety; no incremental insertion.
- Focused tests per task, final complete code and artifact verification once. Commit only owned changes; no push or merge.

## Review Focus

- Sustained quiet input must stay smaller than sustained loud input despite normalized FFT bands (Task 1).
- Delayed/stopped old-session audio must not animate new recordings; silent/stale input must settle (Task 1).
- Slow-progress timers must not release ownership, extend deadlines or repaint a cancelled/new session (Task 2).
- Clipboard and uncertain delivery must outrank polish fallback; missing retained audio must not promise retry (Task 2).
- Long diagnostics and real 216 × 54 geometry must remain legible, including at 1× display scale (Task 2).

---

### Task 1: Audio-driven diffusion waveform

**Files:** Modify `Services/AudioRecorder.swift`, `Core/Pipeline/Stages/RecordingStage.swift`, `Core/Pipeline/SessionContext.swift`, `Core/PipelineOrchestrator.swift`, `UI/AudioVisualizer.swift` under `Sources/flowtype`; create focused visualization frame/motion types under `Services/` or `UI/`; create `Testing/CapsuleWaveformSelfTests.swift`; register in `Testing/SelfTest.swift`.

**Interfaces:** Consumes existing normalized spectrum/PCM and session ownership. Produces `AudioVisualizationFrame` containing normalized frequency detail plus absolute RMS/level, and `SessionController.visualizationFrame` published for the view, scoped/reset like existing spectrum. Preserve `RecordingOutput(spectrum:)` compatibility for existing capture fixtures; live capture must carry real amplitude through a single ordered data stream (no unbounded duplicate stream). Expose deterministic motion math accepting elapsed time so tests do not need wall-clock delays. Task 2 consumes `AudioVisualizer` unchanged and may read the frame for previews.

- [x] Add focused `--capsule-waveform-only` self-test entry. First test real PCM-derived quiet/loud order (including sustained signals), silence and empty/nonfinite samples; record a failing run before implementation.
- [x] Implement frame transport; use bounded newest buffering for visualization, finish/cancel cleanly, preserve recorder owner checks. Do not change ASR buffers/results. Keep legacy spectrum consumers/tests source-compatible.
- [x] Implement deterministic center-to-edge diffusion with stable slight asymmetry, time-based quick rise/slower decay and fixed 2…18 output. Assert finite 10-bar outputs, delayed outer response to a short pulse, quiet/loud separation, silence/stale decay to exact rest, and equivalent results for different render intervals within tolerance. Reset/session regression must cover late callback invalidation.
- [x] Render ten 2pt rounded bars at 2pt gaps in 40 × 24, blue-purple, no per-frame implicit animation stacking. Tick only while recording and reset on session changes; no fake activity under silence. Honor accessibilityReduceMotion with restrained amplitude response without travelling diffusion.
- [x] Run build + focused waveform tests and affected recording/recovery regressions; document commands, counts and any limitations in report. Full suite is reserved for final validation.
- [x] Self-review and commit `feat(capsule): add audio-driven diffusion waveform`.

### Task 2: Compact capsule and honest state presentation

**Files:** Modify `Sources/flowtype/CapsuleView.swift`, `FloatingPanel.swift`, `Core/PipelineOrchestrator.swift`, `Core/Recovery/RecoveryPolicy.swift`, affected `Core/Pipeline/Stages/{ASRStage,InjectionStage,PolishStage}.swift` and context if needed; create focused `UI/CapsulePresentation.swift`, `Testing/CapsulePresentationSelfTests.swift`, extend debug native preview harness and `Testing/SelfTest.swift`.

**Interfaces:** Consumes Task 1 `AudioVisualizer` and existing recovery/session outcomes. Produces testable `CapsulePresentation` title/subtitle/indicator/geometry derived from state and typed notice/operation metadata. Keep `.notice(String)` source compatibility where practical; source emission sets typed metadata rather than presentation guessing from string contents. One slow-progress operation timestamp/token at stop; invalidate on terminal/reset. Do not add enum cases just for presentation if a separate model suffices.

- [x] Add focused `--capsule-presentation-only` tests for 216×54 vs 380×156, copy/indicator for each state, typed notice priority/durations, missing retry resources, and slow-progress cancellation/new-session guards; record failing evidence for behavioral changes. Prefer injectable clock/delay or explicit test hooks over real 6-second sleeps.
- [x] Implement exact spec copy, notice durations and progress presentation. Keep 20s completion budget unchanged; slow display is only UI state. Retain first-PCM recording readiness, no dwell or false injection success. Audit all terminal/reset routes for timer invalidation.
- [x] Compact CapsuleView and all FloatingPanel default geometry to216×54; original blue-purple frost/gradient, 13/11 text and readable subtitle contrast. Remove scale breathing; recording bars only during recording, semantic spinner/symbol for other states. Keep error layout/actions, drag/nonactivation and existing radius behavior. Never truncate away the actionable part of long recovery text.
- [x] Extend isolated debug native render harness with selected states; produce render evidence at real size for normal/silent recording, preparing, processing, polishing, slow, injecting, clipboard, no-speech and recoverable error. Use existing preview isolation; no mic/cloud/clipboard effects.
- [x] Run focused presentation and waveform tests, native-client and M4 recovery regressions; self-review and commit `feat(capsule): ship compact frosted state presentation`.

### Final verification (controller owned)

- [x] Review combined implementation against spec, including native render geometry and long diagnostics.
- [x] Run `scripts/verify.sh --lane code` and `scripts/verify.sh --lane artifact` with existing isolated verification setup; inspect complete reports.
- [x] Record evidence and manual hardware limitations in `docs/evidence/2026-11-03-capsule-waveform/README.md`, update plan checkboxes, commit documentation, leave local branch reviewable.
