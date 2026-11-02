# Task 3 independent review — 43cc155..1a07557

## Spec Compliance

- ❌ Issues found: synchronous published-state callbacks can still let an old finish/cancel clear a newer session, and recovery-card publication is not atomic under reentrancy. Both violate the binding single-owner/current-card contract. See Important findings I1–I2.
- Verified all eight scoped files are represented in the supplied diff. Recovery state/effects, typed retry authorization, compatibility wrappers, current-card UI buttons, readiness refresh, persistent uncertainty, and runner integration are implemented.
- ⚠️ Cross-task limits: this task diff does not re-prove the complete Task 1 classification matrix or Task 2 first-failure mapping/startup boundary. Complete M3 clipboard restoration/changeCount protection, per-key target checking, and 150 ms settle remain whole-M4 integration checks; this task does not modify those implementations.
- ⚠️ GUI geometry/long-label rendering, true-device V1–V5, real cloud, microphone permissions/disconnection, acoustic calibration, and model inference remain Pending. Source dimensions and synthetic tests do not establish those passes.

## Strengths

- `Sources/flowtype/Core/PipelineOrchestrator.swift:317` gates every action on error state, current card UUID, session identity, and allowed actions; `:323` additionally requires an actual ASRStage, nonempty retained audio, an active context, no delivery event, and a fresh typed-policy check before retry. The legacy Boolean cannot grant authority.
- `Sources/flowtype/Core/PipelineOrchestrator.swift:372` revalidates card/session/context after the injected readiness callback; blocked refresh creates a new card and ready/degraded returns to idle without recording.
- `Sources/flowtype/Core/PipelineOrchestrator.swift:508` selects deliveryBlocked when uncertainty has no actual event; terminal resources are closed at `:513`, and explicit copy retains complete final text. `Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift:311` covers the distinct action sets and no resend.
- `Sources/flowtype/Core/Recovery/RecoveryEffects.swift:5` provides the requested injected effects; `Sources/flowtype/CapsuleView.swift:131` captures the displayed card ID in each button instead of invoking global effects.
- `Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift:396` exercises actual controller/history-callback reentrancy, alongside real ASR/InjectionStage/clipboard boundaries. The M3 intended-transient fixture correction retains its original PCM, preflight, handle and budget assertions (`Sources/flowtype/Testing/M3SpeechPreflightSelfTests.swift:395`, `:680`).

## Issues

### Critical (Must Fix)

- None identified.

### Important (Should Fix)

- **I1 — Summary publication is another synchronous callback boundary, but finish/cancel do not revalidate afterward.** `Sources/flowtype/Core/PipelineOrchestrator.swift:504` and `:305` call `recordLastDelivery`, whose `@Published` assignment at `:661` invokes Combine subscribers synchronously. Both callers validated ownership only before this call. Exact trigger: install a retained, one-shot `$lastDeliverySummary` subscriber (ignore its initial nil; set a fired flag before invoking any controller method); on the first uncertain summary, call `cancel()` and then `startRecording()`, with readiness now blocked on microphone permission so the new context/card exists synchronously. On return, the old `finish` executes `currentContext = nil`, clears the new subscriptions/card and presents its old terminal card (`:514`–`:522`); the old `cancel` instead sets the new active ID to zero and resets/cancels the new context (`:308`–`:312`). In addition, Combine publishes before storing the property, so the nested cancel can publish the same summary again while `lastDeliverySummary != summary` still holds. Fix terminal summary publication/claiming and ownership checks so reentrant publication cannot duplicate the summary or clean up another context. Add focused tests for both normal uncertainty and explicit cancellation using this subscriber trigger. The existing `historyReentrancy` test at `M4RecoveryControllerSelfTests.swift:418` triggers only from saveHistory and does not cover this boundary.

- **I2 — Recovery-card publication can overwrite a newer card and leave public/private authority inconsistent.** `Sources/flowtype/Core/PipelineOrchestrator.swift:398` sets private recoveryState, then independently publishes raw text, actions and card (`:400`–`:403`) before an unguarded transition (`:404`); `clearSuspension` likewise publishes in the middle of clearing (`:388`). Exact trigger: while showing a blocked card, retain a one-shot `$recoveryCard` subscriber that ignores nil and calls `startRecording()` on the next nonnil card; change readiness to a different blocked reason and invoke recheck on the original card. Recheck passes its callback guard and enters `presentRecovery`. The new nonnil card is sent in `@Published`'s willSet; the subscriber starts a newer blocked session and installs its card. After that returns, the outer assignment stores the old refresh card over the new published card, and `:404` overwrites the new error message. Private recoveryState/activeSessionID still belong to the newer session, so the displayed card's buttons fail their ownership gate. This violates both atomic clear/update and no stale UI replacement. Commit recovery presentation coherently before notifying subscribers, or otherwise defer/serialize public publication and protect its continuation; an after-assignment guard alone cannot undo the old property's willSet overwrite. Add a focused reentrant card-subscription test that asserts displayed card/message, private action authority (via an allowed action), and new context survive.

### Minor (Nice to Have)

- None identified independently of I1–I2.

## Checks and Evidence

- Read the provided review package once in sequential sections; no git diff/log derivations, test reruns, source edits, checkout/index/branch mutations, or subagents.
- Read cut-off controller functions to assess named risks: fresh-session invalidation, stage result ownership, terminal summary publication, and transition/reset callbacks. Read the omitted CapsuleView parent layout to confirm its frame consumes capsuleSize (`CapsuleView.swift:32`).
- Focused unchanged-interface check: `SessionContext.swift:138` claims history once; `:327` closes the event gate and cancels resources. This supports terminal cleanup/history semantics but does not protect controller callbacks after publication.
- Raw final evidence inspected: `task-3-green-final.log:20` reports 19,686/0; `task-3-m3-green.log:21` reports 990/0; `task-3-build-final.log:6` reports successful build; `task-3-full-final.log:6` reports 23,811/0. These existing runs do not exercise the two subscriber triggers above.
- Recompilation evidence retains the documented pre-existing AppLogger warning (`task-3-green-final.log:7`); the final full log has no reported failure/runtime warning. No introduced warning identified in the supplied diff.
- Runtime CFFIXED_USER_HOME isolation and inherited full-runner I/O limitations are recorded in the implementer ledger; this review does not claim complete isolation of historical tests.

## Assessment

**Task quality:** Needs fixes.

**Reasoning:** The typed recovery model, effect seams, action gate and resource-preserving retry are well scoped, with substantial synthetic integration evidence. The two remaining synchronous publication ownership holes can defeat the central guarantee that old completions/cards cannot overwrite a newer session, so the task should not pass its gate until those paths are fixed and tested.
