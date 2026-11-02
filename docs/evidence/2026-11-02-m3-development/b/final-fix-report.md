# Final M3 fix wave — F1 and F2

Base: `7ce5d21306cb03ccb1832a9b3ac30b7f983ac863`.
Implementer: `/root/m3_final_fix`. Scope: the two Important findings in `final-fix-brief.md`; binding M3 design §§3–4 and the explicit controller cancellation ruling. No delegation.

## Changes

**F1:** Automatic fallback carries a fresh strict target validator into the actual `KeyboardInjector.insertText` chunk/newline loop. Before every balanced pair, including the first, it samples the stop target match, editable focus, secure-input decision and current accessibility permission. Cancellation is checked around the awaited validation and again through the existing event gate. Production AX collection still uses the existing detached worker in `currentDeliveryTarget` / `deliveryTarget`. Rejection before the first event keeps the board and full recovery text; rejection after an event terminates uncertain, with no copy/retry or latch reset.

The narrow `TypingEvents` seam replaces only native event preparation/posting and inter-pair wait. Real newline normalization, segmentation, 64-Character chunking, injection serialization, validation and event/cancellation gating always run. Native preparation still creates both events before claiming an event latch; a preparation failure is not dispatch evidence. The source/pair wrappers transfer their CoreGraphics objects within the serialized injection operation, and synchronous posting always emits down/up together. Legacy explicit typing retains its existing policy; the strict validator applies to automatic fallback.

**F2:** Controller cancellation requests pending-delivery materialization only for its current owned context. `SessionContext.cancel(recordPendingDelivery:)` closes the existing cancellation/event lock, obtains final actual-event evidence, and synchronously changes nil or pending typed/paste-dispatched outcomes to uncertain before the controller saves history/summary or invalidates ownership. A previously saved session is not reclassified. Normal context cancellation defaults to existing outcome behavior. Effect-only preparation cannot produce an uncertain result. Existing once-only history claiming, summary deduplication and stale-stage ownership rejection remain in place.

`ClipboardTransaction` itself is unchanged: complete snapshots, change-count/content ownership checks, independent cleanup, user-copy preservation and default 150 ms settling remain the shared production implementation.

## Regression coverage

New `M3FinalFixSelfTests.swift` is registered in both the existing delivery-focused and full self-test entrypoints. It exercises real InjectionStage / production typing loop and real controller / ClipboardTransaction with fake OS/storage boundaries, synthetic text and an isolated defaults suite.

- PID, known AX identity, secure input, revoked permission, blind focus and nontext focus changes at the first-pair validation, after a chunk, before a newline and after a newline.
- Complete recovery text and protected multiformat board before first dispatch; exactly one balanced pair and uncertain afterward; no retry/copy and no attempt reset.
- Successful exact chunk/newline ordering; fresh target lookup per pair; cancellation inside awaited target validation; native-boundary preparation failure before first or after one pair without falsely claiming an event.
- Controller cancellation while real paste cleanup is suspended with event evidence but nil outcome, including concurrent user-copy ownership; analogous partial typing; pending produced paste/typing outcomes before controller finalization.
- Immediate uncertain history/summary while cancellation owns the session, full recovery text, repeated cancellation, then a newer real-stage completion before old cleanup returns; late results do not overwrite or save/publish again.
- Real transaction temporary-board-only cancellation negative control and restoration; completed newer context outcome remains unchanged after cancellation.

## TDD and verification evidence

All logs are in this directory. Initial test-harness compilation issues were resolved before the behavioral RED evidence below; no failed compilation is represented as a behavioral reproduction.

1. **RED** — `swift run FlowType --self-test --m3-delivery-only`, exit **1**, `final-fix-red.log`: **527 passed / 78 failed**. The narrow nonbehavioral native preparation/wait seams and regressions were present; per-pair validation and cancellation materialization were absent. Failures show extra events after target changes, typedDispatched instead of uncertain, and nil/unchanged pending outcome plus missing history/summary at controller cancellation. This reproduces both findings without real OS input.
2. **GREEN** — same focused command, exit **0**, `final-fix-green.log`: **611 passed / 0 failed** after both production fixes. The count differs from RED because correct first-event rejection reaches two recovery assertions instead of one failed suspension assertion.
3. **Boundary self-review additions** — same focused command, exit **0**, `final-fix-green-boundaries.log`: **628 passed / 0 failed** after adding successful ordering, cancellation-during-validation and preparation-failure regression checks.
4. **Sequential final build** — `swift build`, exit **0**, `final-fix-build.log`: build completed in **35.66 s**.
5. **Full self-test** — `swift run FlowType --self-test`, exit **0**, `final-fix-full-self-test.log`: **4124 passed / 0 failed**. Executed once, after the successful sequential final build.
6. `git diff --cached --check`: exit **0**. A final whitespace-only formatting pass in the new test file removed trailing whitespace and aligned the fixture initializer; no behavior changed after the focused GREEN or final build.

Compiler output retains the pre-existing AppLogger unnecessary `nonisolated(unsafe)` warning; no new compiler warning was introduced. No `swift test`, benchmark repetition, dependencies, downloads, Python, real clipboard/events, GUI, permissions, models, cloud APIs or user configuration were used.

## Self-review

Reviewed the complete scoped diff and new tests against both findings. Checked native preparation versus actual-event evidence, balanced pair atomicity, cancellation after target awaits, the unchanged off-main AX implementation, immutable attempt/event latches, event-gate closure before cancellation publication, historySaved protection for completed sessions, stale-controller guards, and user-owned clipboard restoration. Existing broad inject test seam remains compatible, but these regressions deliberately do not replace the whole inject function. The new test file is focused on this fix wave; no unrelated restructuring or warning cleanup.

No unresolved correctness concern identified. Synthetic tests establish source-level behavior, not current-bundle GUI/acoustic/app-compatibility acceptance; controller-owned re-review and packaging remain separate gates. All controller-owned dirty documentation is excluded from the scoped commit.

## Files and artifacts

Product: `Sources/flowtype/Services/KeyboardInjector.swift`, `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`, `Sources/flowtype/Core/Pipeline/SessionContext.swift`, `Sources/flowtype/Core/PipelineOrchestrator.swift`.
Tests: `Sources/flowtype/Testing/M3FinalFixSelfTests.swift`, `Sources/flowtype/Testing/SelfTest.swift`.
Review artifact: `final-fix.diff` (only these six source/test files).
Commit: `f7554ee` — `fix(delivery): revalidate fallback pairs and preserve cancelled dispatch`. Status: **DONE**.
