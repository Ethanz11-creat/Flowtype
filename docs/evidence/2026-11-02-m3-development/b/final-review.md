# Independent whole-M3 final review

Date: 2026-11-02. Reviewer: `/root/m3_final_review`.

Scope: all five product tasks in the supplied `review-8d5d6bd..7ce5d21.diff`, BASE `8d5d6bd`, HEAD `7ce5d21306cb03ccb1832a9b3ac30b7f983ac863`. Authoritative requirements: `docs/superpowers/specs/2026-11-02-m3-delivery-and-silence-design.md`, both M3 implementation plans, task briefs and controller rulings. Review method: independent source/control-flow review using the requested `requesting-code-review/code-reviewer.md`; existing test reports/logs consumed as evidence. No production/test edits, checkout/index/HEAD changes, subagents, full-suite repetition, benchmark repetition, real input events or live services. This report is the only reviewer-written artifact.

## Strengths

- Automatic selection is a small policy layer over the existing target/safety decisions. New, missing and invalid settings select Automatic while explicitly saved legacy modes remain representable in both decoding and the Picker. The mode is sampled once per attempt.
- The event latch is separate from temporary clipboard effects and uses the same cancellation lock. The real ClipboardTransaction still owns snapshot completeness, changeCount/content checks, serialization and the 150 ms cleanup window. Failed automatic typing before its first event keeps the protected board and exposes complete recovery text; dispatch/uncertainty does not trigger an automatic second delivery.
- LastDeliverySummary stores metadata only. Menu subscription correctly consumes the emitted Published value synchronously, and reopening refreshes it. Wording distinguishes event dispatch from confirmed insertion and retains the original target for clipboard recovery.
- SpeechPreflight is auditable O(n)/O(1) statistical work over the complete raw recording. It validates every sample, including after earlier signal, handles partial final frames, accumulates in Double with the specified Float32 boundaries, and keeps short/malformed inputs distinct from proven silence. The detached production wrapper propagates cancellation and suppresses obsolete results after worker exit.
- ASR preflight is before route construction, provider/finalize/preview promotion and health changes, including direct/retry entry. The live handle is consumed and its cleanup installed before any preflight exit. Existing/new budgets are established before scanning, retained rather than reset, and checked before recognition starts. Silent/empty/malformed input cannot enter downstream delivery/history. Old preflight results are rejected before provider work and cannot replace a newer session.
- Synthetic coverage meaningfully exercises real transactions, ASR/controller integration, complete audio forwarding, budgets, live cleanup, malformed tails and obsolete completion barriers. Evidence clearly distinguishes source checks from acoustic/GUI/service acceptance and records the final test-only refinement accurately.

## Issues

### Critical (Must Fix)

None identified.

### Important (Should Fix)

### F1 — Automatic typing fallback stops validating the target once chunked typing begins

**References:** `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:111`, `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:138`; cross-interface implementation `Sources/flowtype/Services/KeyboardInjector.swift:60`, `:109`, `:124`, `:129`.

**Trigger and trace:** Paste fails without a key event, for example because the original board cannot be completely snapshotted. The automatic fallback obtains an editable, trusted matching target and calls `typeText`. Its production inject closure calls `KeyboardInjector.insertText`, which sends 64-character pieces and newline pairs with an awaited 4 ms delay after every pair. If the user switches application/text field, or the destination becomes unsafe, during one of these waits, the remaining pairs are still posted globally. `postIfActive` checks task/session cancellation only. Neither the target snapshot nor a target/permission validation callback is carried into that loop, so a focus change does not stop it. Long text makes this a meaningful user-visible window rather than an unavoidable instant between an OS check and an event.

**Impact:** Remaining dictated text can land in a different control/application while the stage reports typedDispatched. That violates the intended correct-target contract and the plan's explicit concern about focus/security/permission changes during fallback. The old Unicode loop already had this limitation, but the new default automatic fallback now relies on it to fulfill a new safety guarantee; it is not outside M3 simply because the low-level loop was unchanged.

**Why existing coverage misses it:** `M3DeliverySelfTests.swift:242` replaces typing with one synchronous synthetic pair. The PID/focus/secure/AX/blind cases change the snapshot during the initial fallback recheck, before inject is called. They do not exercise the production chunk/newline loop across a suspension.

**Fix:** Carry a strict, fresh matching-target/editable/security/permission validation into the actual automatic fallback dispatch loop. Revalidate after each await and before each subsequent balanced pair, with AX IPC off MainActor and cancellation checked again after validation. On rejection before the first pair preserve the board and recover the full text; after any pair stop with uncertain and never copy/retry. Avoid resetting attempt/event latches. Add deterministic production-loop tests with only OS target/event boundaries faked: pause after the first piece (also cover a newline boundary), switch PID/known AX identity or safety/permission state, and assert no later event and no clipboard overwrite.

### F2 — Cancelling after an event but before InjectionStage returns loses uncertain history and summary

**References:** `Sources/flowtype/Core/PipelineOrchestrator.swift:292`, `:296`, `:301`, `:412`; producer boundary `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:94`, `:145`, `:176`; transaction boundary `Sources/flowtype/Services/KeyboardInjector.swift:313`, `:329`, `:330`; context cancellation `Sources/flowtype/Core/Pipeline/SessionContext.swift:327`.

**Trigger and trace:** A normal automatic paste posts its balanced Cmd-V pair, then awaits the 150 ms settling/restoration task. During that window `deliveryEventStarted` is true but `deliveryOutcome` is still nil. The user cancels. Controller.cancel calls context.cancel, which does not materialize a terminal delivery outcome; the controller saves history/summary only if the outcome is already uncertain. It then invalidates activeSessionID and resets. The transaction subsequently restores the clipboard and returns uncertain; InjectionStage records it on the old context, but executeStage's ownership guard discards that result before finish/saveHistory/recordLastDelivery. The same ordering occurs when cancelling multi-piece typing after a pair but before its inject await returns. A narrow pending typed/pasteDispatched result before controller finalization also deserves coverage.

**Impact:** Text may already have been inserted, possibly only partially, yet this session has no uncertain recovery history and the menu still shows the previous delivery or no delivery. The new honest last-delivery contract fails at an ordinary cancellation point, and full recovery text can be lost. Saving from a stale stage later would break the separate stale-session contract; the decision must occur while cancellation still owns the session.

**Why existing coverage misses it:** `M3DeliverySelfTests.swift:613` tests the cancellation path by calling fixture.deliver(.uncertain) *before* entering its barrier. That already installs the terminal outcome, unlike the production transaction/typing ordering. Runtime event-after-cancel tests inspect the old context directly rather than asserting controller history/summary.

**Fix:** While the controller still owns the context, cancel through the same event gate, then atomically/synchronously establish the appropriate uncertain terminal result from actual event evidence before saving once and invalidating ownership. Do not infer sent text from deliveryEffectStarted, since a restored temporary board is not an event. Cover nil and any already-produced but not-finalized dispatch outcome without changing a previously completed session or enabling duplicate history. Retain the strict stale-result guard. Add real-controller + real-InjectionStage/ClipboardTransaction tests pausing after actual fake event dispatch during settle, cancel, then release cleanup (including after a newer session succeeds); assert one uncertain history/summary at cancellation, restored/owned board semantics, no retry/copy and no late overwrite. Add the analogous partial typing case and a temporary-board-only cancellation negative control.

### Minor (Nice to Have)

- **M1 — Existing logger annotation warning:** `Sources/flowtype/Utilities/AppLogger.swift:27` uses unnecessary `nonisolated(unsafe)` on a Sendable DispatchQueue constant. Compiler warning hygiene only; no M3 behavior regression or source-gate blocker. Remove the redundant annotation in a separate cleanup if desired.
- **M2 — Existing unused yield result warning:** `Sources/flowtype/Services/Speech/AppleSpeechProvider.swift:196` ignores the value returned by `stateLock.withLock { previewContinuation?.yield(...) }`. The actual yield side effect still runs; no M3 failure established. Explicitly discard the result in a separate cleanup. This is not an argument to alter preview lifecycle in this fix wave.

Both deferred warnings were inspected in source and corresponding compilation evidence. They remain nonblocking; no other warning-based issue was inferred.

## Recommendations

Consolidate F1/F2 into the controller-owned final fix wave, then perform scoped independent review of the changed dispatch/cancellation interfaces and their deterministic integration regressions. These are distinct gaps: F1 prevents wrong-destination continuation; F2 preserves an honest result for events that already escaped. Passing current tests does not establish either behavior. Keep the production clipboard transaction and its ownership cleanup intact.

Update controller-owned status/evidence only after that gate. No additional general refactor, dependency, model, Python execution or repeat benchmark is needed to fix these findings.

## Evidence and validation limitations

- Inspected task reports, both progress ledgers, the complete supplied product diff, new tests, relevant unchanged dispatch/transaction/context/controller interfaces and raw RecordingStage handoff. HEAD matches the requested review revision. Controller-dirty documentation was left untouched; its pending final consolidation is not reported as an implementation failure.
- Existing full run: **3875 passed / 0 failed** on stable production source, after sequential build. The final committed test-only completion-barrier refinement has **989/0** focused plus a succeeding build; related ASR/realtime/lease regression is **292/0**. This is not represented as a full-suite run of the refined final test file. Earlier A final focused/full evidence is **381/0** and **2888/0**.
- The existing one-off 30-minute debug synthetic benchmark reports analyze **4.535 s**, evaluate **4.531 s**, cancellation request-to-exit approximately **0.080 ms** on its recorded machine. It supports that measured case, not every hardware configuration. No benchmark or test command was rerun in this review.
- F1/F2 are established by the production control flow and test-seam mismatch described above; this read-only review did not dispatch real events or add/run a new reproduction. The requested deterministic regressions should demonstrate RED before the fixes.
- Accepted controller rulings are reasonable: defer the intermediate A bundle until final source; create a missing budget before preflight; retain the full production run plus focused/build verification for the test-only barrier delta. The shell-only packaging probe override is a proposed packaging procedure, not yet runtime validation.
- Current-bundle GUI, app compatibility and 150 ms clipboard consumption, microphone calibration, real model/service paths, physical device recovery, continuous 20 rounds and V1–V5 remain Pending. Synthetic pass counts cannot establish these. Final packaging is still after the source gate.

## Declined to judge

- Human-voice classification or rejection of arbitrary keyboard/fan/wind noise: outside the explicitly conservative energy/peak detector contract; measured acoustic behavior and threshold calibration remain required Pending acceptance.
- Zero cloud upload or billing for a silent realtime recording: explicitly not promised because recording-time streaming can precede this stop-time gate; only post-stop finalize/fallback/delivery suppression is judged here.
- Confirmed AX readback/insertion success: explicitly outside M3; reviewed the truthful dispatched/uncertain semantics rather than treating sent events as insertion confirmation.
- Empirical current-bundle application, microphone, service and physical-device performance: cannot establish from a read-only source review and existing synthetic evidence; retained as Pending, not silently waived or marked Pass.
- New packaging success and GUI launch of the final fixed revision: not yet performed and downstream of this source review; the recorded optional-Python-probe ruling was assessed only as procedure.

## Assessment

**Ready to merge / pass the final source gate? No — with fixes F1 and F2.**

The core M3 architecture and silence integration are coherent and extensively tested, but automatic fallback can continue into a changed destination and real cancellation after dispatch can bypass the new uncertain recovery summary/history. Both are ordinary user-facing delivery/lifecycle failures that must be fixed before approving the source gate. No additional M3-B source blocker was found. Product completion remains separately dependent on the explicitly Pending real acceptance matrix even after source fixes pass.
