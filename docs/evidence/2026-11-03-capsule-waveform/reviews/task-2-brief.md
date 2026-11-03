### Task 2: Compact capsule and honest state presentation

**Files:** Modify `Sources/flowtype/CapsuleView.swift`, `FloatingPanel.swift`, `Core/PipelineOrchestrator.swift`, `Core/Recovery/RecoveryPolicy.swift`, affected `Core/Pipeline/Stages/{ASRStage,InjectionStage,PolishStage}.swift` and context if needed; create focused `UI/CapsulePresentation.swift`, `Testing/CapsulePresentationSelfTests.swift`, extend debug native preview harness and `Testing/SelfTest.swift`.

**Interfaces:** Consumes Task 1 `AudioVisualizer` and existing recovery/session outcomes. Produces testable `CapsulePresentation` title/subtitle/indicator/geometry derived from state and typed notice/operation metadata. Keep `.notice(String)` source compatibility where practical; source emission sets typed metadata rather than presentation guessing from string contents. One slow-progress operation timestamp/token at stop; invalidate on terminal/reset. Do not add enum cases just for presentation if a separate model suffices.

- [ ] Add focused `--capsule-presentation-only` tests for 216×54 vs 380×156, copy/indicator for each state, typed notice priority/durations, missing retry resources, and slow-progress cancellation/new-session guards; record failing evidence for behavioral changes. Prefer injectable clock/delay or explicit test hooks over real 6-second sleeps.
- [ ] Implement exact spec copy, notice durations and progress presentation. Keep 20s completion budget unchanged; slow display is only UI state. Retain first-PCM recording readiness, no dwell or false injection success. Audit all terminal/reset routes for timer invalidation.
- [ ] Compact CapsuleView and all FloatingPanel default geometry to216×54; original blue-purple frost/gradient, 13/11 text and readable subtitle contrast. Remove scale breathing; recording bars only during recording, semantic spinner/symbol for other states. Keep error layout/actions, drag/nonactivation and existing radius behavior. Never truncate away the actionable part of long recovery text.
- [ ] Extend isolated debug native render harness with selected states; produce render evidence at real size for normal/silent recording, preparing, processing, polishing, slow, injecting, clipboard, no-speech and recoverable error. Use existing preview isolation; no mic/cloud/clipboard effects.
- [ ] Run focused presentation and waveform tests, native-client and M4 recovery regressions; self-review and commit `feat(capsule): ship compact frosted state presentation`.

### Final verification (controller owned)

- [ ] Review combined implementation against spec, including native render geometry and long diagnostics.
- [ ] Run `scripts/verify.sh --lane code` and `scripts/verify.sh --lane artifact` with existing isolated verification setup; inspect complete reports.
- [ ] Record evidence and manual hardware limitations in `docs/evidence/2026-11-03-capsule-waveform/README.md`, update plan checkboxes, commit documentation, leave local branch reviewable.
