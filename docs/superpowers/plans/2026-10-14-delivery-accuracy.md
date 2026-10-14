# Delivery and Context Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make final text delivery honest and safe across app/focus changes while using bounded foreground context to improve coding-language accuracy.

**Architecture:** Snapshot target/context at capture start, revalidate target immediately before one delivery side effect, and represent attempted/uncertain/clipboard outcomes separately. Context is structured low-trust data passed independently to refinement; literal-preservation checks can reject a damaged polished result in favor of complete processed ASR text.

**Tech Stack:** Swift 6.2, AppKit Accessibility, NSPasteboard, CGEvent, GRDB migration, existing ASR/LLM pipeline.

**Spec:** `docs/superpowers/specs/2026-10-14-delivery-accuracy-design.md`; evidence `docs/superpowers/typeless-evidence-2026-10-14.md`.

## Global Constraints

- Capture context is bounded, redacted, and safe-field guarded; it never blocks audio or becomes trusted instructions.
- Target identity is revalidated before delivery; focus changes route to explicit clipboard recovery.
- A session has at most one delivery side effect; uncertain paste is never automatically repeated.
- Plain Unicode injection remains default; paste mode is opt-in and experimental.
- Raw/processed text remains available when polish fails or literal preservation rejects output.
- Run `swift build` and `swift run FlowType --self-test` before each commit.

## Review Focus

- Parent secure field prevents both value and selected-text reads.
- A user clipboard change during paste transaction is never overwritten on restore.
- A target app/focused element change between recording and delivery does not type into the new field.
- Literal checks preserve paths, flags, URLs, versions, numbers, backticks, and CJK prose.
- Legacy database/JSON records decode when new delivery/context fields are absent.

### Task 1: Structured bounded context and refinement contract

**Files:**
- Modify: `Sources/flowtype/Services/Context/ContextProvider.swift`
- Modify: `Sources/flowtype/Services/Context/AXContextProvider.swift`
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/PolishStage.swift`
- Modify: `Sources/flowtype/Core/Configuration.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce bounded structured snapshot, time-limited AX collection, context-safe polish prompt block, and `preservesCodingLiterals(original:polished:)`.

- [ ] Write tests for redaction, secure parent, bounded timeout fallback, trusted prompt separation, and literal preservation/corruption.
- [ ] Run self-test RED.
- [ ] Implement context snapshot and refinement guard; reject damaged polish to processed text.
- [ ] Run full build/self-test and commit `feat(accuracy): bound foreground context and protect coding literals`.

### Task 2: Target identity and delivery outcome contract

**Files:**
- Create: `Sources/flowtype/Services/Delivery/DeliveryContract.swift`
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce `DeliveryOutcome`, target snapshot/revalidation pure functions, and one-side-effect gate.
- Preserve Unicode default and distinguish dispatched/clipboard/uncertain/cancelled.

- [ ] Write pure tests for same target, changed target, secure/noneditable/AX-blind, duplicate delivery, and cancellation.
- [ ] Run self-test RED.
- [ ] Implement target snapshot/revalidation and explicit outcome propagation; do not claim paste confirmation from sleep.
- [ ] Run full build/self-test and commit `feat(delivery): make target validation and outcome explicit`.

### Task 3: Clipboard transaction and persistence migration

**Files:**
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`
- Modify: `Sources/flowtype/Core/DictationHistory.swift`
- Modify: `Sources/flowtype/Core/Database/Records.swift`
- Modify: `Sources/flowtype/Core/Database/AppDatabase.swift`
- Modify: `Sources/flowtype/Core/SessionMetrics.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce injectable clipboard transaction preserving representations and restoring only when ownership change-count is unchanged.
- Add Optional delivery metrics migration and report dispatch vs clipboard vs uncertain.

- [ ] Write fake pasteboard tests for restore ownership, user change, multi-representation capture, legacy decode/migration, and metric reports.
- [ ] Run self-test RED.
- [ ] Implement paste transaction and v5 migration; keep plain text fallback and no automatic repeat after ambiguous dispatch.
- [ ] Run full build/self-test and commit `feat(delivery): protect clipboard and persist delivery outcome`.

### Task 4: Accuracy validation and UI recovery copy

**Files:**
- Modify: `Sources/flowtype/CapsuleView.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Create: `docs/2026-10-14-flowtype-product-validation.md`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] Add copy for focus-changed, clipboard recovery, uncertain dispatch, and literal-preservation fallback.
- [ ] Document coding speech evaluation cases and manual app matrix.
- [ ] Add pure tests for outcome-to-copy mapping and old histories.
- [ ] Run full build/self-test and commit `test(delivery): document accuracy and delivery validation`.
