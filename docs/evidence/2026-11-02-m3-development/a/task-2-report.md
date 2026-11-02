# M3-A Task 2 implementation report

Status: DONE. Focused and full verification passed; source commit recorded below.

## Source and scope

- Base: `c9f91a1 feat(delivery): define automatic delivery and safe fallback policy`.
- Task brief: `.superpowers/sdd/2026-11-02-m3-a-automatic-delivery/task-2-brief.md`.
- Commit: `7700f36 feat(delivery): enable automatic paste with owned typing fallback`.
- Scope is the seven assigned source/test files only. Controller-owned docs were already dirty and were not edited or staged. Evidence/report remain in ignored `.superpowers` workspace files.

## Implemented behavior

- Configuration's new, missing-key and unknown-value defaults are `.automatic`; the three stored values round-trip without changing the other tested settings.
- Settings represent all three values using the exact specified labels; the explanation retains the candidate-directory qualification.
- SessionContext adds an actual-event latch alongside the existing effect latch, within the same cancellation lock. `postIfActive` uses the event gate; clipboard preparation continues through the unchanged effect gate.
- InjectionStage snapshots the mode once after reserving the sole delivery attempt. Identity/AX checks and the pure method policy determine the first method. Only automatic `.unsafeSnapshot`/`.notDispatched` outcomes enter a fresh target/AX check and `canFallbackToTyping`.
- The shared `typeText` helper distinguishes protected fallback from explicit Unicode recovery. Failure before the fallback's first event returns full text in a nonretryable recovery context without copying over the board. Cancellation without an event is cancelled; a failed or cancelled attempt after an event is uncertain. Normal explicit Unicode pre-effect failure retains its copy recovery.
- No attempt or effect latch is reset. Terminal paste outcomes do not type/copy; duplicate execute cannot repeat effects. ClipboardTransaction's ownership checks, restoration semantics and default 150 ms settling window are unchanged.

## Tests and TDD evidence

All new runtime scenarios use actual InjectionStage, ClipboardTransaction, SessionContext and KeyboardInjector.postIfActive with a fake board and event callbacks. No real clipboard, CGEvent, model, permission, network, or GUI operation was added or manually executed.

### Initial behavioral RED

Command: `swift run FlowType --self-test --m3-delivery-only`

Log: `task-2-logs/red.log` (relative to this report).

Result: exit 1; `=== M3 delivery self-test: 171 passed, 30 failed ===`.

Relevant failures before production edits:

- `new default — got unicode, want automatic`.
- Missing/unknown mode migration returned Unicode.
- Real unsafe/preparation/partial-write scenarios logged `["type"]` instead of `["paste-preparation", "type"]`; paste transaction result was nil.
- Protected fallback failure copied text over the original multi-representation board instead of returning a recovery card.
- Changed PID/focus/secure-input/AX/blind target did not suppress typing.

These were behavioral failures in compilable tests exercising the existing stage, not missing-symbol failures.

### Expanded race tests and compile correction

The later expanded test run initially failed to compile because Swift marks direct `DispatchSemaphore.wait` unavailable inside async functions. This is recorded in `task-2-logs/expanded-compile-error.log`; it is not claimed as a behavioral RED. The barrier wait was moved into a synchronous test-only helper invoked from a detached task. An earlier empty-output invocation was interrupted while adjusting the test rendezvous so absent fallback behavior cannot strand its waiter.

### Focused GREEN

Command: `swift run FlowType --self-test --m3-delivery-only`

Log: `task-2-logs/focused-green.log`.

Result: exit 0; `=== M3 delivery self-test: 305 passed, 0 failed ===`.

Coverage includes:

- Multi-item RTF, PNG bytes and file URL representations; unsafe snapshot; failed dispatch preparation; real partial failed write followed by successful full restoration returning `.notDispatched`.
- Typed fallback once with no reset, duplicate execution suppression, terminal history claimed once, mode read once, and mode changes during preparation retaining the original strategy.
- Protected typing preparation failure, full-text nonretryable recovery and no clipboard overwrite.
- Fresh PID/focus/secure/AX/blind denial with no type/copy.
- Real dispatched/uncertain/clipboardChanged results and user copying during the transaction, preserving the user's new contents and change count.
- Continuation-controlled fallback-recheck cancellation and queued transaction cancellation.
- Semaphore-barrier-controlled task cancellation after a successful temporary write and before the event gate: actual transaction `.cancelled`, restored board, `effect=true/event=false`, no typing/copying. No unreachable transaction result is faked.
- First-key failure/cancellation, including task cancellation, returns uncertain without second delivery.
- Explicit Unicode and legacy routes and their old recovery contracts.
- Independent actual SessionContext effect/event gate behavior.

After focused GREEN, only switch indentation changed before the final build; no behavior changed.

### Final verification

- `swift build`: exit 0; `Build complete! (28.90s)`. Log: `task-2-logs/build.log`.
- `swift run FlowType --self-test`: exit 0; `=== self-test: 2812 passed, 0 failed ===`. Log: `task-2-logs/full-self-test.log`.
- `git diff --check`: clean.
- No `swift test`, app packaging, dependency change, download, Python/conversion script, push or merge was run.

## Changed files

1. `Sources/flowtype/Core/Configuration.swift`: automatic defaults/migration.
2. `Sources/flowtype/Core/Pipeline/SessionContext.swift`: actual-event gate/latch.
3. `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`: policy-driven runtime, refreshed fallback authorization, shared typing completion/recovery.
4. `Sources/flowtype/Services/KeyboardInjector.swift`: balanced pairs use the actual-event gate.
5. `Sources/flowtype/Settings/SettingsPage+Recording.swift`: all three mode labels/explanation.
6. `Sources/flowtype/Testing/M3DeliverySelfTests.swift`: isolated runtime fixtures/scenarios.
7. `Sources/flowtype/Testing/SelfTest.swift`: runtime runner integration, explicit Unicode in Unicode-specific regressions, automatic production-default assertions.

## Self-review and concerns

- Reviewed attempt ownership, cancellation before/after events, protected clipboard failure recovery, strict fresh fallback checks and full terminal outcomes against the brief and spec sections 4.1/4.2.
- Kept the existing seam signatures and the existing transaction implementation. No dependency or M2 model/configuration/lifecycle behavior changed.
- Unicode-specific existing tests now explicitly choose Unicode; tests for production defaults and generic clipboard/cancellation behavior continue to exercise automatic/default semantics. No existing regression was removed.
- One pre-existing compiler warning remains in `Utilities/AppLogger.swift:27` about unnecessary `nonisolated(unsafe)` on a Sendable DispatchQueue; unrelated source was not edited.
- Runtime coverage is synthetic. Real application compatibility/consumption timing, UI acceptance and app packaging belong to controller acceptance and have not been claimed here.
- No known implementation correctness concern found in self-review. Final full suite passed once on stable source (2,812 checks, zero failures); it retained all existing M2 and original transaction assertions.
