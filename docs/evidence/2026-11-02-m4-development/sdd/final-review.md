# Whole-M4 independent review

Reviewed base `68c72d4b7cb135279d813a43c1050c71921e4e73` through HEAD `24f2e517bc137769af07b77622ad0eed358b25b0`; latest product source commit `c292110`. Verdict: **one Important ownership gap remains; one deferred Minor warning/accounting item remains.** No Critical finding.

## Strengths

- The classifier is bounded and uses typed errors, HTTP status, and URL error domain/code. It neither parses arbitrary provider prose nor sends Error/text/audio into the published card (`Sources/flowtype/Core/Recovery/FailureClassifier.swift:4`, `Sources/flowtype/Core/Recovery/RecoveryPolicy.swift:38`). The legacy Boolean is retained for compatibility without granting execution authority.
- Real ASR failures retain the first classified cause before generic wrapping; both mixed-provider orders and later budget expiry have explicit tests. Cancellation is checked before fallback/health and before direct-typing clipboard fallback (`Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift:95`, `:150`, `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:164`).
- Recovery effects pass through one current-card/session/action gate. Retry additionally requires a real ASRStage, the retained audio payload, an active context and no posted event, and recomputes the typed policy (`Sources/flowtype/Core/PipelineOrchestrator.swift:337`). The original route, language, local lease, complete PCM, preflight, fresh realtime handle and fresh 20-second budget are retained rather than reconstructed from current settings.
- Normal uncertainty and explicit cancellation are deliberately different UI terminals. History and summary claims are guarded against synchronous save/publication reentry; terminal cards close the old context/event gate. Before-event clipboard ownership loss keeps the conservative uncertain outcome while presenting truthful deliveryBlocked copy (`Sources/flowtype/Core/PipelineOrchestrator.swift:312`, `:522`, `:695`).
- The committed private presentation, explicit publishers and per-subscriber generation filters repair the reviewed card/error-state publication races without introducing another lifecycle owner. Both product state consumers were migrated (`Sources/flowtype/Core/PipelineOrchestrator.swift:87`, `Sources/flowtype/App/StatusBarController.swift:24`, `:82`). The remaining caller-continuation gap is detailed below.
- Tests combine exhaustive pure policy checks with real ASRStage, InjectionStage, typing/clipboard transactions, retained Combine subscribers, and fake system/provider seams. The changed M3 retry fixture now expresses a typed transient failure while retaining its original PCM/handle/budget assertions; it does not weaken production retry authorization.

## Issues

### Critical — Must Fix

None found.

### Important — Should Fix

**I1. A superseded orchestration caller can overwrite the new session's task after synchronous state publication.**

- Primary locations: `Sources/flowtype/Core/PipelineOrchestrator.swift:460` and `:518`; related caller continuation at `:267`–`:268`.
- `executeStage(at:)` checks ownership at entry, then calls `transition(to: .injecting, ...)`. That transition now publishes synchronously to the explicitly supported `sessionStatePublisher`/`objectWillChange` callbacks. A one-shot subscriber can call `cancel()` and `startRecording()`, installing a new context and its recording task. When the subscriber returns, the old `executeStage` invocation continues, creates its obsolete injection task and assigns it to `currentTask` at line 518. The generation checks *inside* `transition` do not stop its caller.
- The obsolete context's event gate prevents old injection, but it does not protect the newer task handle. Subsequent `cancel()` or `endRecording()` cancels the obsolete task instead of the active RecordingStage task. RecordingStage's task-cancellation handler is the mechanism that immediately stops its owned recorder (`Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift:194`). The new recording can therefore continue running after a stop/cancel command, or remain stuck in processing rather than handing off its audio. This is an important lifecycle/cleanup gap in the M4 reentrant-publication contract, even though the reviewed card-refresh regressions pass.
- Related exact manifestation: a `.preparing` subscriber that calls `cancel()` leaves the canonical state idle and hides the window, but the returning old `startRecording()` still executes `effects.showWindow()` at line 268. No stage runs because the later ownership gate rejects it, yet an obsolete continuation reopens the cancelled capsule. This is the same missing caller-side revalidation, not a separate architecture request.
- Fix: after every synchronous transition/effect/publication boundary that has remaining lifecycle work, validate the captured context/session (and generation where a same-session commit matters) before proceeding. At minimum guard the pre-Injection transition before task creation/assignment, and the initial preparing transition before the trailing show effect. Review the recording-readiness callback's transition-then-timer continuation at lines 252–253 under the same rule. A transition result/owner predicate can keep this local; no new coordinator or state machine is needed.
- Focused regression trigger: use the real SessionController and a real InjectionStage, with a synthetic first stage that produces a polished payload for session A. Retain a one-shot `.injecting` subscriber that cancels A and starts session B. Have B's synthetic Recording stage mark readiness and suspend under a cancellable wait with an observable cancellation handler. After B has started, call `cancel()` and assert its task cancellation/cleanup occurs exactly once and no old injection/copy/history occurs. This avoids actual microphone, frontmost-app or provider access. Also subscribe once to `.preparing`, cancel synchronously, and assert the final window effect is hide, the state remains idle, and no stage starts. Existing tests cover error/card/summary subscriber replacement, not these nonterminal callers.
- Evidence level: deterministic source control-flow trace, not a newly executed reproduction. Per review constraints, no test source, product source, build or full suite was run/modified to reproduce it.

### Minor — Nice to Have

**M1. Two introduced Sendable-capture test warnings are still missing from the implementation's final warning accounting.**

- `Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift:459`: `c` is mutated after capture by a Sendable closure.
- `Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift:557`: `armed` is mutated after capture by a Sendable closure.
- Both diagnostics occur in `task-3-fix1-green-final.log:6` and `:28`. The later standalone build recompiles StatusBarController, so its absence of these diagnostics does not prove they were removed. `task-3-report.md:182` and `:192` account for the existing AppLogger warning without accounting for these newly introduced test diagnostics. The validation/ledger correctly acknowledges the deferred item.
- These are test-fixture/compiler-hygiene and evidence-accounting issues; no demonstrated product race is inferred from the warnings. Use a MainActor fixture holder for mutable state and record the warnings/fix accurately. Do not recategorize them as pre-existing or claim a warning-clean source build from an incremental log.

## Integration and five ReviewFocus checks

| Required behavior | Independent source/test assessment |
| --- | --- |
| 1. Mixed failures, both orders; successful fallback | ASRStage keeps the first original kind, including credentials before later budget expiry; cancellation exits before fallback/failed health. `M4StageFailureSelfTests.swift:87` onward exercises both failure orders, expiry and successful fallback. No new issue found. |
| 2. Settings capture immutability, rerecord, stale actions | Settings only invokes the injected effect. Configuration kind cannot unlock retry after configuration changes. New capture creates a new context and production RecordingStage captures a new route; transient retry uses saved context/route/lease/PCM. Stale card IDs are rejected before effects; noEngine refresh invalidates its old card. `M4RecoveryControllerSelfTests.swift:96`, `:138`, `:212`, `:351` cover action families and resources. I1 is the remaining ownership gap after nonterminal publication, not a failure of card-ID validation. |
| 3. Non-CoreAudio engine.start failure | AudioRecorder now always calls the frozen callback before finishing the spectrum stream; the narrow synchronous seam tests both domains. RecordingStage checks frozen before returning audio and maps it to persistent interrupted/rerecord recovery. This proves propagation, not real-device startup/unplug acceptance. Existing optional preview initialization before the frozen-result check is not evidence of successful capture or downstream preview promotion. |
| 4. Explicit cancel versus normal uncertain | Actual-event normal uncertain closes resources and leaves copy/history/dismiss; explicit cancel saves uncertain once and stays idle. Context history claim and pre-publication summary claim suppress duplicates; save/summary callbacks are ownership-checked on return. Tests use real InjectionStage/ClipboardTransaction and repeated cancellation. No resend action is emitted or accepted. I1 separately affects ownership of a replacement recording task. |
| 5. Privacy / failed storage / unsafe provider text | Cards carry stable category/message/actions, never arbitrary error, URL, key, transcript or PCM. Copy text stays session-owned and only the valid explicit copy action uses it. Terminal message does not promise successful persistence or transcript retention; history action means navigation only. No-op storage plus storeTranscriptText=false tests cover the non-promise. No new privacy defect found in the changed failure/presentation paths. |

Additional boundaries checked:

- The M3 event/effect latch, single deliveryAttempt, balanced per-pair target revalidation, full pasteboard contents/changeCount protection, and 150 ms uncancelled settling implementation are unchanged. Injection changes preserve those paths, including the fixed typed-cancellation zero-copy guard. The terminal controller distinguishes pre-event clipboardChanged from posted-event uncertainty using the actual latch, not the Error type.
- Invalid PCM cannot unlock saved-audio retry or reach provider/preview promotion; silence/empty remain notices. The actual ASR retry reruns preflight; tests preserve new realtime-handle and budget assertions. Optional polish still delivers the full processed fallback rather than becoming a blocking M4 card.
- Readiness recheck and automatic routing remain explicit, refresh the current blocker, and clear to idle for ready/degraded without recording/sending. Missing AX remains an eligible menu/clipboard degradation. Rerecord clears the previous suspended data; configuration repair does not rebind a captured request.
- No dependency/schema change or model-download path is introduced. The design changes to persistent uncertainty cards, safe pre-event wording and committed explicit publishers are recorded rulings rather than undocumented deviations.

## Verification evidence inspected

- Read the supplied whole diff in bounded sections for all changed source/tests and research/validation documents; read the complete design and plan, progress/final-checks ledgers, prior task review/fix reports, and surrounding controller/stage/context/keyboard code needed to trace ownership. Recovered truncated output with narrower reads rather than treating it as complete evidence.
- `task-3-fix1-green-final.log:60`: **19,730 passed / 0 failed**. The two new capture warnings above are present earlier in that same log.
- `task-3-fix1-build.log`: successful build, **24.48s**, with the existing AppLogger annotation warning. It only recompiles the consumer file after module emission and is not a clean rebuild proof for every source diagnostic.
- `task-3-fix1-full.log:6`: **23,855 passed / 0 failed**. This is existing evidence for source `c292110`, not a run performed by this reviewer and not evidence against the uncovered I1 input.
- Task2's known cancellation clipboard-fallback finding and Task3's prior summary/card publication findings are addressed in the final source at their exact reviewed triggers. The new Important finding is a different caller continuation outside those test inputs.
- No build, full/focused test rerun, network/provider/hardware access, user configuration/key/model-cache access, checkout/index/branch mutation or subagent dispatch was performed. This requested report is the only authored file.

## Declined to judge

- Actual permission denial → System Settings → recheck behavior: no real permission/desktop interaction; source seams do not establish OS behavior. Remains Pending.
- Real cloud authentication, offline/weak-network recovery and provider service response semantics: synthetic providers only; no live credentials/network access. Remains Pending.
- Actual microphone startup, unplug/replug, device repair and acoustic behavior: no hardware access; the narrow startup callback test does not substitute for device acceptance. Remains Pending.
- Actual recovery-card readability, two-column clipping, window animation, accessibility and click/focus behavior: source layout/model dimensions are inspected, but no GUI rendering/interaction was executed. Remains Pending.
- Actual cross-application typing/paste, clipboard interoperability, old-card races and V1–V5 acceptance: fake targets/boards/events establish source invariants only. Remains Pending.
- M3 silence thresholds, quiet/short/noisy speech and device calibration: unchanged acoustic calibration work, not established by synthetic M4 inputs. Remains Pending.
- M2 full model load/inference/runtime compatibility: no model/cache access; M4 preserves leases but cannot certify inference. Remains Pending.
- Broader recorder conversion/dropout handling and optional preview initialization ordering: inherited behavior outside the approved narrow engine-start propagation; no broader recorder rewrite is proposed or approved by this source review.
- Complete historical runner I/O isolation and normal-user-directory launch behavior: task1/older full-run limitations are explicitly recorded; later CFFIXED_USER_HOME evidence does not retroactively certify earlier runs or normal startup. Remains a recorded limitation/Pending real-environment check.
- Final fixed app packaging, exact source/binary identity and artifact verification: not yet performed in the supplied final-checks record; no new artifact approval is inferred. Remains Pending.
- Deep/strict signing of the known unsigned mlx.metallib and distribution/notarization: existing M5 limitation; neither fixed nor newly tested here. Standard main-code verification is not claimed to have run for a new artifact.

## Assessment

**Ready to merge / declare source-ready? No — fix I1 first.** The classification, resource-gated recovery, privacy, delivery boundaries and reviewed publication fixes are well integrated and have substantial synthetic verification. The remaining synchronous-publication caller can still lose ownership of the new recording task; the existing 23,855/0 suite does not exercise that trigger. Resolve it with narrow real-controller regressions, account for the Minor warnings, then perform the scoped rereview and remaining authorized closeout. Source approval must remain separate from the explicitly Pending GUI/cloud/hardware/model/artifact evidence; this review does not authorize merge or push.
