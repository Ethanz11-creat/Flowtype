# M3-A Task 1 implementation report

Status: DONE.

## Scope, root cause and design

Base commit: `8d5d6bdf65848946b22ebbec2cacae1e5f7220b1`. Source work started clean. Controller documentation edits were observed during implementation and deliberately excluded from the scoped source commit.

Previously `DeliveryMode` lived in KeyboardInjector and exposed only Unicode and the legacy six-app paste directory. There was no pure automatic method selection or strict post-transaction fallback decision. Added `DeliveryPolicy.swift` and moved the existing enum into it, preserving the exact six legacy bundle IDs. `.automatic` permits initial paste independent of bundle ID; `.unicode` selects typing; legacy selects paste only within the existing directory. `resolveDeliveryMethod` first delegates focus/secure-input checks to `decideInjection` and the permission gate to `applyAccessibilityGate`. Its documented precondition is caller target validation via `decideDelivery`; it does not duplicate target identity checks.

`canFallbackToTyping` accepts only automatic + unsafeSnapshot/notDispatched + no dispatched event + fresh trusted AX + explicitly editable current focus, and delegates stop/current identity and safety checks to `decideDelivery`. Blind current focus is denied; a blind stop snapshot may permit fallback when refreshed current focus is editable and the existing target contract allows injection. No runtime latch, dispatch, clipboard, UI or configuration code changed. Configuration initialization and missing/unrecognized-mode decoding remain `.unicode` for Task 2 to migrate.

## Tests and TDD evidence

New policy tests use real pure functions and synthetic focus/target identities, without fake dispatch or asynchronous replacement. They catch missing safety gates, automatic bundle restriction, legacy directory expansion/contraction, typing-mode changes, unsafe fallback after any dispatched event, fallback after disallowed transaction results, stale/missing targets, PID/focus changes, unknown/non-text/secure focus, permission loss and explicit legacy-mode fallback. All six PasteTransactionResult values are exercised with both event flags. Both eligible paste failures are exercised against every invalid target/permission case. The focused runner is `--m3-delivery-only`; the full suite also calls `M3DeliverySelfTests.policy`.

Commands ran from `/Users/yiheng/pycode/flowtype-local`, in this order. Each command redirected stdout/stderr to the named log, preserved its exit status, then printed its output. No `swift test`, dependency changes, real GUI startup, clipboard/events, network services, audio, keys or model operations were performed manually.

1. RED: `swift run FlowType --self-test --m3-delivery-only`
   - Exit: **1**.
   - Log: `.superpowers/sdd/2026-11-02-m3-a-automatic-delivery/task-1-red.log` (complete output).
   - Expected missing API errors, before any production edit:
     - `M3DeliverySelfTests.swift:7:39: error: type 'DeliveryMode' has no member 'automatic'`
     - `M3DeliverySelfTests.swift:14:22: error: cannot find 'resolveDeliveryMethod' in scope`
     - `M3DeliverySelfTests.swift:59:22: error: cannot find 'canFallbackToTyping' in scope`
   - Remaining inference diagnostics follow from those missing APIs. This missing-API RED is the brief's explicitly allowed RED form.
2. GREEN: `swift run FlowType --self-test --m3-delivery-only`
   - Exit: **0**.
   - Log: `.superpowers/sdd/2026-11-02-m3-a-automatic-delivery/task-1-green.log` (complete output).
   - Final output:
     ```text
     Build of product 'FlowType' complete! (37.46s)
     === FlowType --self-test ===
     === M3 delivery self-test: 133 passed, 0 failed ===
     ```
   - Existing warnings from untouched files: AppLogger.swift:27 unnecessary `nonisolated(unsafe)`; AppleSpeechProvider.swift:196 unused `withLock` result (repeated across compilation units). No warning originates in changed source.
3. Final build: `swift build`
   - Exit: **0**.
   - Log: `.superpowers/sdd/2026-11-02-m3-a-automatic-delivery/task-1-build.log` (complete output).
   - Full output:
     ```text
     [0/1] Planning build
     [1/1] Compiling plugin GenerateManual
     [2/2] Compiling plugin GenerateDoccReference
     Building for debugging...
     [2/5] Write swift-version--1AB21518FC5DEDBE.txt
     Build complete! (19.14s)
     ```
4. Full suite, started only after final build exited: `swift run FlowType --self-test`
   - Exit: **0**; **2640 passed, 0 failed**.
   - Log: `.superpowers/sdd/2026-11-02-m3-a-automatic-delivery/task-1-full-self-test.log` (complete output).
   - Full output:
     ```text
     [0/1] Planning build
     Building for debugging...
     [0/3] Write swift-version--1AB21518FC5DEDBE.txt
     Build of product 'FlowType' complete! (4.88s)
     === FlowType --self-test ===
     === self-test: 2640 passed, 0 failed ===
     ```

`git diff --check` passed. Source was stable before GREEN and remained unchanged for final build and full suite.

## Source identity

SHA-256 of tested files:

```text
a431eab978a32404e584faa463a86f9cecae2e634baab99191aaf4894382b8d2  Sources/flowtype/Services/Delivery/DeliveryPolicy.swift
53dfaef56813a0808848773f4f4a43bf182d423f59e32945e5e060b0b508eb2e  Sources/flowtype/Services/KeyboardInjector.swift
14750c3b28fd45f37c04c12057b080c174bea6265e6ddec5cf5640d47e6a3a7c  Sources/flowtype/Testing/M3DeliverySelfTests.swift
7e4c1a32009b3bba275f85a127c4b7f859846cef0b755c250825846b4c5e3e94  Sources/flowtype/Testing/SelfTest.swift
```

## Files and self-review

- Created `Sources/flowtype/Services/Delivery/DeliveryPolicy.swift` (pure mode/method/fallback policy).
- Created `Sources/flowtype/Testing/M3DeliverySelfTests.swift` (133 policy checks).
- Modified `Sources/flowtype/Services/KeyboardInjector.swift` only to remove the relocated DeliveryMode enum.
- Modified `Sources/flowtype/Testing/SelfTest.swift` only to register focused/full policy checks.

Self-review checked all brief interfaces, exact legacy IDs, preservation of current defaults, reuse of role/target logic, full result/event fallback table, focused/full runner registration and absence of runtime side effects in the pure policy. No scope or correctness issues found. The large existing SelfTest.swift was touched only at runner registration. Runtime dispatch/fallback integration and configuration/settings changes remain Task 2 work by design; this task does not claim that integration or real-machine acceptance.

Concerns: no new-source concerns; existing compiler warnings are recorded above. Independent review and documentation lifecycle remain controller-owned.

Commit: `c9f91a1` — `feat(delivery): define automatic delivery and safe fallback policy`.

Post-commit inspection confirmed exactly the four listed source files in the commit and unchanged tested SHA-256 values. Remaining working-tree modifications are controller-owned documentation only. Report/log artifacts remain in ignored `.superpowers`; no push, merge, branch/worktree cleanup or documentation edits were performed.
