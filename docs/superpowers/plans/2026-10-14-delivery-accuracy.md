# Delivery and Context Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make final text delivery honest and safe across app/focus changes while using bounded foreground context to improve coding-language accuracy.

**Architecture:** Snapshot context at capture start and target at stop, revalidate target immediately before one delivery side effect, and represent attempted/uncertain/clipboard outcomes separately. Context is structured low-trust data passed independently to refinement; literal-preservation checks can reject a damaged polished result in favor of complete processed ASR text.

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
- Modify: `Sources/flowtype/Services/LLMService.swift`
- Modify: `Sources/flowtype/Settings/SettingsPage+ASR.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce bounded structured ForegroundContext snapshot, time-limited AX collection (0.15s per AX call, 0.5s total wait, no UI/audio blocking), context-safe polish data block, and `preservesCodingLiterals(original: String, polished: String) -> Bool`.
- Selected text/app name precede bounded cursor-near element text; maxChars 1200 after redaction. Preserve secure/parent guards. Store snapshot in SessionContext at capture start and clean up async collection on cancel.
- LLM context uses user message data separate from system instructions. `Configuration.cloudPolishSendContext` default follows cloudASRSendContext at legacy decode; localOnly never forwards foreground context to cloud LLM; cloudASRSendContext is a master gate AND cloudPolishSendContext, so turning the existing switch off forbids foreground routing through polish. Test real config-toggle transition.
- Add structured foreground argument/user-data message builder to LLMService; do not combine context with transcript text passed to literal validation. Bounded AX waiter does not join the synchronous producer; stale collection commit blocked by session ownership. Add actual settings toggle/copy. Existing user prompt remains authoritative but append clear no instruction execution/literal preservation requirements.
- Reject missing explicit code/path/URL/flags/version/numeric literals with token boundaries; allow prose/punctuation changes, use processed ASR on damage and mark polishFailed.

- [x] Write tests for redaction, secure parent, bounded timeout fallback, trusted prompt separation, and literal preservation/corruption.
- [x] Run self-test RED.
- [x] Implement context snapshot and refinement guard; reject damaged polish to processed text.
- [x] Run full build/self-test and commit `feat(accuracy): bound foreground context and protect coding literals`.

### Task 2: Target identity and delivery outcome contract

**Files:**
- Create: `Sources/flowtype/Services/Delivery/DeliveryContract.swift`
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce `DeliveryOutcome`, target snapshot/revalidation pure functions, and one-side-effect gate.
- Preserve Unicode default and distinguish typedDispatched/pasteDispatched/clipboard/uncertain/cancelled; explicit side-effect latch claimed only immediately before actual delivery.
- Capture target PID and comparable AX identity at stop (avoids preparation target races), revalidate at delivery; changed PID/known focus → clipboard. Switching app before stop selects the stop-time target; switching afterward routes clipboard. AX blind same PID preserves existing behavior. A synchronous gate plus Task checks surrounds each irreversible event dispatch.

- [x] Write pure tests for same target, changed target, secure/noneditable/AX-blind, duplicate delivery, and cancellation.
- [x] Run self-test RED.
- [x] Implement target snapshot/revalidation and explicit outcome propagation; do not claim paste confirmation from sleep.
- [x] Run full build/self-test and commit `feat(delivery): make target validation and outcome explicit`.

### Task 3: Clipboard transaction and persistence migration

**Files:**
- Modify: `Sources/flowtype/Services/KeyboardInjector.swift`
- Modify: `Sources/flowtype/Core/DictationHistory.swift`
- Modify: `Sources/flowtype/Core/Database/Records.swift`
- Modify: `Sources/flowtype/Core/Database/AppDatabase.swift`
- Modify: `Sources/flowtype/Core/SessionMetrics.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce injectable clipboard transaction preserving every available item/type Data representation and restoring only if current changeCount and content are still owned. Add `Configuration.deliveryMode` unicode default / pasteInSupportedApps explicit opt-in; settings label experimental.
- Support candidate bundle IDs for TextEdit/VSCode/Cursor/Chrome/Safari/Edge; other apps use Unicode. Snapshot before mutation; one Cmd+V event pair, 150ms nonblocking settling window; no blind repeated delivery after cancellation/failure/unknown target receipt. Plain fallback clipboard may remain new content only before any injection event is dispatched.
- Transaction phases prepare/write/eventDispatched/cleanup; cleanup task survives session cancellation for full settling interval. Snapshot enumeration checks changeCount before write; incomplete snapshot refuses destructive transaction. Serialize transactions; test cancelled after event and user-copy/overlap. Mark dispatched cancellation uncertain, not cancelled-with-no-side-effect.
- Add Optional deliveryOutcome and stopToDeliveryMs to history JSON; DB v5_delivery and Records init/read, save clipboard/notice terminal history once and include metrics even with transcript storage off. Report dispatch vs clipboard vs uncertain, no actual insertion success claim.
- Add Optional delivery metrics migration and report dispatch vs clipboard vs uncertain.

- [x] Write fake pasteboard tests for restore ownership, user change, multi-representation capture, legacy decode/migration, and metric reports.
- [x] Run self-test RED.
- [x] Implement paste transaction and v5 migration; keep plain text fallback and no automatic repeat after ambiguous dispatch.
- [x] Run full build/self-test and commit `feat(delivery): protect clipboard and persist delivery outcome`.

### Task 4: Accuracy validation and UI recovery copy

**Files:**
- Modify: `Sources/flowtype/CapsuleView.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Create: `docs/2026-10-14-flowtype-product-validation.md`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [x] Add copy for focus-changed, clipboard recovery, uncertain dispatch, and literal-preservation fallback.
- [x] Document coding speech evaluation cases and manual app matrix.
- [x] Add pure tests for outcome-to-copy mapping and old histories.
- [x] Run full build/self-test and commit `test(delivery): document accuracy and delivery validation`.
