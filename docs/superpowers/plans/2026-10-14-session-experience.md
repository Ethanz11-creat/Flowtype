# Session Experience and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make capture readiness, stop/cancel, final-only delivery, and recoverable errors feel like one native session.

**Architecture:** Keep the existing pipeline but make session ownership and presentation explicit. RecordingStage publishes readiness only after a real PCM buffer; the controller owns terminal transitions and cancellation; PolishStage returns complete postprocessed text on failure. UI reads stable state labels and never renders token previews.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, AVAudioEngine, async tasks, existing self-test harness.

**Spec:** `docs/superpowers/specs/2026-10-14-session-experience-design.md`

## Global Constraints

- SessionController remains `@MainActor`; active session IDs gate every late callback.
- Intermediate ASR/LLM text is never rendered or injected.
- Stop does not wait for the double-tap window; Escape cancels and late results must not deliver.
- Polish failure delivers complete postprocessed text; cancellation delivers nothing.
- Existing audio contract and local Qwen behavior remain available.
- Run `swift build` and `swift run FlowType --self-test` before each commit.

## Review Focus

- Stop during microphone initialization must stop the future task without producing a late result.
- Cancelled session callbacks must be ignored after a new session starts.
- Polish stream failure/empty output must deliver the complete processed text exactly once.
- A timer/state transition must not replay start/stop feedback or steal focus.
- Existing onboarding demo and toggle/double-tap compatibility must remain intact.

### Task 1: Session ownership and readiness contract

**Files:**
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift`
- Modify: `Sources/flowtype/Core/Pipeline/PipelineStage.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce `SessionState.preparing`, `SessionContext.isCancelled`, and a readiness event that occurs after the first valid audio buffer.
- Preserve `StageResult` and add no provider-specific casts.

- [x] Write pure tests for state transitions: preparing before first buffer, recording after ready, stop/cancel ownership, and stale session event rejection.
- [x] Run `swift run FlowType --self-test` and observe the new tests fail for missing state/contract.
- [x] Implement the minimal controller/context/stage contract; ensure stop during preparation cancels capture and no result advances.
- [x] Run focused self-test, then full `swift build` and self-test.
- [x] Commit `feat(session): gate recording on audio readiness and session ownership`.

### Task 2: Gesture stop/cancel and stable presentation

**Files:**
- Modify: `Sources/flowtype/WindowManager.swift`
- Modify: `Sources/flowtype/CapsuleView.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Modify: `Sources/flowtype/App/StatusBarController.swift`
- Modify: `Sources/flowtype/Core/Configuration.swift`
- Modify: `Sources/flowtype/Settings/SettingsPage+Recording.swift`
- Modify: `Sources/flowtype/Settings/OnboardingView.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Observers/AudioFeedbackObserver.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Make the first clean stop action immediate once active; preserve idle double-tap/toggle start behavior and modifier chord suppression.
- Add stable presentation mapping for preparing/processing and remove polish preview content.
- Produce `Configuration.polishOnStop: Bool` default true, `decodeIfPresent` legacy true; settings toggle “停止后自动整理”; all stop paths including max-duration use it. Active modifier release stops immediately; idle start detector remains compatible; nonmodifier key repeat cannot extend holds.

- [x] Add event timeline tests for first tap/stop, double tap start compatibility, Escape cancel, and repeated stop.
- [x] Run self-test to verify the new timeline assertions fail before implementation.
- [x] Implement immediate active-session stop, cancellation of pending tap timers, stable capsule/status titles, and readiness-based recording timer.
- [x] Run full build and self-test; manually record the required gesture matrix as pending where hardware is needed.
- [x] Commit `feat(session): make stop immediate and capsule states stable`.

### Task 3: Complete-text degradation and recovery actions

**Files:**
- Modify: `Sources/flowtype/Core/Pipeline/Stages/PolishStage.swift`
- Modify: `Sources/flowtype/Core/PipelineOrchestrator.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift`
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- Modify: `Sources/flowtype/Services/LLMService.swift`
- Modify: `Sources/flowtype/CapsuleView.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Add pure `polishFallbackText(processed:raw:)` and explicit recovery action mapping by failed stage.
- Keep one terminal delivery gate; Polish failure must continue with processed text, cancellation must suspend without delivery.
- Use a cancellable 3-second whole polish deadline; an underlying producer must be cancelled on timeout/stream termination (do not await uncooperative task-group losers). Preserve full processed text, never partial tokens. Configure available-LLM detection before optional polish so missing Key is pass-through.
- Add context completion notice rendered only after delivery, remove 5-second error dismissal, expose retry/copy/dismiss buttons only for actionable error. Stage-specific retry must not force polish for ASR retry.
- InjectionStage must check Task/context cancellation before sleep, after sleep and before clipboard/CGEvent side effects; terminal save history exactly once when completing through idle or notice.

- [x] Write tests for empty/same/error polish results, cancellation, one delivery, and retry action labels.
- [x] Run self-test and capture RED output.
- [x] Implement bounded polish fallback and cancellation-aware stream cleanup; make recovery UI retain actionable state until explicit dismissal.
- [x] Run full build and self-test.
- [x] Commit `fix(session): deliver processed text when polish degrades`.

### Task 4: Plan validation and manual matrix

**Files:**
- Create: `docs/2026-10-14-flowtype-product-validation.md`
- Modify: `Sources/flowtype/Testing/SelfTest.swift`

- [x] Add a reproducible manual matrix for readiness, short/long speech, silence, quick cancel, focus changes, permissions, and local cold/warm runs.
- [x] Add assertions for unchanged legacy configuration decode and onboarding demo behavior.
- [x] Run `swift build` and `swift run FlowType --self-test`.
- [x] Commit `test(session): document and pin interaction validation matrix`.
