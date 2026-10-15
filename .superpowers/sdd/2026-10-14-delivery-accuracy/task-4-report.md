# Task 4 report — accuracy validation and UI recovery copy

Status: DONE

## Implementation

- Added the pure `DeliveryCopy` mapping for focus changes, ordinary clipboard
  recovery, clipboard ownership changes, uncertain dispatch and literal-preserving
  fallback. Typed/paste-dispatched outcomes intentionally map to no confirmation
  copy.
- Routed existing injection notices through that mapping and made literal damage
  show `技术内容已保留 · 已使用识别结果`, while timeout and ordinary polish
  failures retain their existing notices.
- Added an explicit `copyResult` recovery action for unsafe/pre-event paste
  failures. `CapsuleView` handles it through the existing user-triggered copy
  path, and `retryFailedStage()` refuses copy/dismiss-only contexts, so a failed
  or uncertain delivery cannot be auto-repeated.
- Extended the existing product-validation document in place. The prior session
  readiness/stop/cancel matrix is preserved; a delivery appendix adds coding
  speech cases, candidate-app/manual matrix rows, pending status, evidence fields,
  and separate dispatch/clipboard timing guidance.

## TDD evidence

RED (before implementation):

`swift run FlowType --self-test > /tmp/flowtype-task4-red.log 2>&1` — exit 1;
`=== self-test: 1082 passed, 3 failed ===`.

The expected failures were the new literal-specific notice assertion (old value
was `整理失败 · 已保留识别结果`) and two unsafe-paste recovery assertions (old
button was `复制原文`, with no result-specific action).

GREEN:

- `swift build > /tmp/flowtype-task4-final-build.log 2>&1` — exit 0;
  `Build complete! (4.64s)`.
- `swift run FlowType --self-test > /tmp/flowtype-task4-final-selftest.log 2>&1`
  — exit 0; `=== self-test: 1090 passed, 0 failed ===`.
- Focused copy-mapping coverage was then expanded and rerun with
  `swift run FlowType --self-test > /tmp/flowtype-task4-final-selftest2.log 2>&1`
  — exit 0; `=== self-test: 1093 passed, 0 failed ===`.
- `git diff --check` — exit 0, no whitespace errors.

Tests cover outcome-to-copy mapping, no-copy behavior for dispatched outcomes,
literal fallback copy, delivery recovery actions, no retry action for unsafe
paste contexts, and the existing old JSON/DB history compatibility checks from
Task 3. No real microphone, AX, foreground app, CGEvent, user clipboard, cloud
provider or API key was used.

## Files changed

- `Sources/flowtype/CapsuleView.swift`
- `Sources/flowtype/Core/PipelineOrchestrator.swift`
- `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`
- `Sources/flowtype/Core/Pipeline/Stages/PolishStage.swift`
- `Sources/flowtype/Testing/SelfTest.swift`
- `docs/2026-10-14-flowtype-product-validation.md`

## Self-review and limits

The recovery buttons remain explicit and user-triggered; no terminal outcome is
reclassified as confirmed insertion. The candidate app rows are intentionally
Pending and do not claim native compatibility or live accuracy measurements.
Existing compiler warnings and manual native-app validation limits remain.
