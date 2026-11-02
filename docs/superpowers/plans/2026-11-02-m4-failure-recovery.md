# M4 Failure Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给失败一个准确、安全、绑定当前会话的恢复入口，禁止自动重发和跨会话副作用。

**Architecture:** 纯 FailureClassifier/RecoveryPolicy 决定类别、文案与动作；阶段在错误原因丢失前显式分类。SessionController 保有唯一生命周期和动作执行权，SessionRecoveryState 只保存卡与可复制文本，RecoveryEffects 隔离系统操作。三项依赖顺序执行，每项可独立审查。

**Tech Stack:** Swift 6.2、macOS15+、现有 SwiftUI/Combine 和自测 runner。

**Spec:** `docs/superpowers/specs/2026-11-02-m4-failure-recovery-design.md`（含精确文案、分类和动作表，执行任务时同时读取；不得把 provider 文本当文案）。

## Global Constraints

- Swift 6.2、macOS15+；不新增/升级依赖，不运行 Python/转换，不下载模型，不访问真实配置、密钥、录音或模型缓存。
- 单一 SessionController/SessionContext 生命周期；旧 session、旧恢复卡、旧异步完成不能发起请求、复制、改设置或覆盖当前 UI/历史/摘要。
- 保留 M3 event/effect latch、一次 deliveryAttempt、逐键对目标复检、完整剪贴板/changeCount/用户新复制保护和150ms settle；任何 uncertain/cancel 均无重发动作。
- 原始 PCM、saved route、captured local lease、显式 ASR retry 的完整样本/新实时 handle/新20s预算保持；设置修复需要新录音，不偷偷改捕获路由。
- 可选 polish 失败继续完整 processed fallback；静音/空录音保持 notice，不走 provider/preview/health/交付/历史；非法音频不重试原 PCM。
- 用户界面和新增诊断只用稳定安全文案/枚举；不展示或记录 provider message、HTTP body、URL/query、NSError userInfo、原始文本或密钥。
- 自动化仅用合成数据、假系统/网络/剪贴板与隔离配置。验证顺序 swift build → swift run FlowType --self-test；不运行 swift test，不重复未变全套或30分钟 benchmark。
- 分支/worktree保留，不push、不merge；源码审查、固定产物与真机矩阵分别记账，未执行为 Pending。

## Review Focus

1. 混合候选：第一个401之后超时应仍要求修复配置；反向次序仍按第一失败；成功fallback正常完成（Task2）。
2. 设置变更不能重试旧捕获密钥，rerecord必须创建新session；旧卡每一种动作都必须无副作用（Task3）。
3. 不属于CoreAudio域的engine.start失败也要结束录音并保留常驻恢复，不成为静音（Task2/3）。
4. 用户取消与正常uncertain终态区别：前者idle，后者常驻；两者历史/摘要恰一次，均不重发（Task3）。
5. 隐私模式或历史保存失败不能虚构“已保存可恢复”，安全文案不能包含secret/URL/provider正文（Task1/3）。

---

### Task 1: Pure failure classification and recovery policy

**Files:**
- Create `Sources/flowtype/Core/Recovery/FailureKind.swift`, `FailureClassifier.swift`, `RecoveryPolicy.swift`.
- Modify `Sources/flowtype/Core/Pipeline/PipelineStage.swift`.
- Create `Sources/flowtype/Testing/M4RecoveryPolicySelfTests.swift`; modify `Sources/flowtype/Testing/SelfTest.swift` runner only.

**Interfaces:**
- `PermissionKind: Equatable, Sendable` = accessibility/microphone/speechRecognition.
- `ASRConfigurationIssue: Equatable, Sendable` = credentials/endpointOrModel/unsupportedLanguage/requestRejected.
- `RecordingFailure: Equatable, Sendable` = interrupted/invalidAudio/tooLarge.
- `FailureKind: Equatable, Sendable` exact cases from spec §4, using existing ReadinessIssue.
- `FailureClassifier.classify(_ error: Error) -> FailureKind`, bounded wrapper inspection, no text parsing; unknown internalFailure.
- `RecoveryTextKind: Equatable, Sendable` = none/raw/result.
- `RecoveryAction: Equatable, Hashable, Sendable` exact cases and existing labels + openSpeechRecognitionSettings="打开语音识别设置", rerecord="重新录音", viewHistory="查看历史". No "重试输入" action emitted by policy.
- `RecoveryResources(stage: String, hasAudio: Bool, textKind: RecoveryTextKind, deliveryEventStarted: Bool, routingPolicy: ASRRoutingPolicy, hasHistory: Bool)`.
- `FailurePresentation(kind: FailureKind, message: String, actions: [RecoveryAction])`; `RecoveryCard(id: UUID, sessionID: UInt64, presentation: FailurePresentation)`; read-only properties, Equatable. Neither owns transcript/Error/audio.
- `RecoveryPolicy.presentation(kind: FailureKind, resources: RecoveryResources) -> FailurePresentation`, exact spec §4 table/copy/order; cancelled empty message/actions.
- `ErrorRecoveryContext.init(failedStage: String, error: Error, rawText: String?, retryable: Bool, failureKind: FailureKind? = nil, textKind: RecoveryTextKind? = nil)` keeps original four fields, adds resolved nonoptional failureKind/textKind; inferred textKind raw iff rawText exists.
- Task3 will replace old nested ErrorAction with typealias. Task1 does not yet switch old controller/view, to keep this pure deliverable buildable.

- [ ] **Step 1: Add focused RED matrix** in `M4RecoveryPolicySelfTests.run(_ r: SelfTest.Reporter)` (MainActor if required by existing types). Add `--m4-recovery-only` early runner path and call same suite in full runner. Assert actual classifier/policy values, not fixture logic. RED may be compile failure before new types exist.
  - CancellationError, Cloud.cancelled, URLError.cancelled, ingress.cancelled → cancelled; nested Cloud/Speech wrappers including cancellation and depth limit.
  - All typed Cloud cases and statuses 301/400/401/403/404/408/413/429/500/599/other, hostile secret/provider body never appears in message/actions.
  - badURL/unsupportedURL/TLS/certificate vs offline/timeout, realtime config missing key vs transport config, Speech unavailable/permission/transcription, Whisper unsupported language/sample rate/local runtime errors; recorder permissions/start/format, invalid stage payloads, unknown NSError.
  - policy matrix covers every kind, readiness(noEngine) under automatic/localOnly/cloudOnly, text none/raw/result, audio yes/no, event yes/no. Retry only transient + stage "ASR" + audio + no event. deliveryUncertain never retry. Max4 actions, exact order/copy.
  - Contradictory legacy retryable=true + typed configuration stays configuration, retryable=false + explicit transient stays typed transient; rawText inference and explicit result inference.
- [ ] **Step 2:** `swift run FlowType --self-test --m4-recovery-only` capture RED log, implement only declared types/classifier/context defaults/policy. Read concrete existing errors before mapping; missing typed errors are not invented.
- [ ] **Step 3:** Re-run focused GREEN, then sequential `swift build` and `swift run FlowType --self-test`, all exit0/failed0. Capture commands/counts/raw logs in task report; no GUI/network/hardware.
- [ ] **Step 4:** self-review diff, scoped commit `feat: classify failures and define safe recovery policy`; report source/API decisions, TDD logs and full counts.

### Task 2: Preserve stage causes and propagate recorder startup failure

**Files:**
- Modify `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift`, `RecordingStage.swift`, `InjectionStage.swift`, `PostProcessStage.swift`, `PolishStage.swift` only where explicit boundary classification is required.
- Modify `Sources/flowtype/Services/AudioRecorder.swift` startup catch only; create `Sources/flowtype/Services/RecordingEngineStartup.swift` narrow boundary.
- Create `Sources/flowtype/Testing/M4StageFailureSelfTests.swift`; extend focused/full runner in `SelfTest.swift`; update only old fixtures whose meaning must change.

**Interfaces:**
- Consumes Task1 FailureClassifier, FailureKind, ErrorRecoveryContext typed initializer; no controller change yet.
- `RecordingEngineStartup.run(prepare: () -> Void, start: () throws -> Void, onFailure: () -> Void, finish: () -> Void)` executes prepare/start; on throw calls onFailure then finish exactly once; on success neither failure nor finish. No hardware/async dependencies. AudioRecorder uses existing onRecordingFrozen and spectrum finish via this seam.
- ASR firstFailureKind retained alongside first error; every catch classifies original error before wrapping; terminal `.suspend` explicitly passes kind. Unknown remains internalFailure; empty candidate list readiness(noEngine); budget-only transientASR. Existing captured route and health accounting, one pass fallback, local lease, cancellation, preflight unchanged.
- invalid PCM recording(invalidAudio); startup error recording(interrupted); stage invalidPayload internalFailure. pre-event injection failure deliveryBlocked + result textKind. Actual uncertain remains existing outcome at finish, not inferred from Error.

- [ ] **Step 1:** RED tests execute real ASRStage with fake providers, no network. `M4StageFailureSelfTests.run(_:)` called by focused/full runner.
  - 401 vs timeout through actual batch/realtime terminal suspension, assert typed kind and policy action (config no retry, transient original audio retry).
  - Two failed candidates both orders (401→timeout and timeout→401), later budget expiry with known401, fallback success still success, no candidates readiness. Cancellation no further provider/health failure.
  - invalid PCM never provider/preview/health. Local directory/runtime and Apple preview ID "apple-preview" classification; no nonexistent `.apple` constant. Optional preview failure remains optional.
  - Synthetic startup prepare→start(throws arbitrary domain)→failure→finish order and count; successful start no failure/finish. Test startup failure path cannot reach ASR as empty recording where the narrow seam permits without accessing real AudioRecorder hardware.
- [ ] **Step 2:** run focused command RED, implement stage annotations and narrow startup boundary; preserve optional Polish degradation, do not broadly rewrite recorder. Do not expose provider localizedDescription in new UI/logs.
- [ ] **Step 3:** focused GREEN, sequential build/full self-test once stable; capture logs. If fixture intent was transient retry, make explicit and provide actual synthetic audio instead of weakening policy.
- [ ] **Step 4:** self-review, scoped commit `fix: preserve stage failure causes for safe recovery`, report all changed contracts and test evidence.

### Task 3: Current-card action ownership, terminal recovery and UI

**Files:**
- Create `Sources/flowtype/Core/Recovery/SessionRecoveryState.swift`, `RecoveryEffects.swift`.
- Modify `Sources/flowtype/Core/PipelineOrchestrator.swift`, `Sources/flowtype/CapsuleView.swift`.
- Create `Sources/flowtype/Testing/M4RecoveryControllerSelfTests.swift`; extend focused/full runner and update legitimate old controller expectations in SelfTest/M3 tests.

**Interfaces:**
- Consumes Tasks1/2. `SessionController.ErrorAction` becomes `typealias ErrorAction = RecoveryAction`; old methods source-compatible wrappers, same single action handler.
- `SessionRecoveryState` stores optional current RecoveryCard and optional copyText (no Error/audio/lifecycle authority). Controller privately owns value; exposes `@Published private(set) var recoveryCard: RecoveryCard?` for View/tests; clear/update atomically with errorActions/lastErrorRawText.
- `@MainActor struct RecoveryEffects`: `openAccessibilitySettings`, `openMicrophoneSettings`, `openSpeechRecognitionSettings`, `openASRSettings`, `openHistory` each `@MainActor @Sendable () -> Void`, `copyText: @MainActor @Sendable (String) -> Void`. `.live` uses existing PermissionHelper/settings(.settings)/settings(.history)/pasteboard. Add `recoveryEffects: RecoveryEffects = .live` to controller init; injected tests never call globals.
- `performRecoveryAction(_ action: RecoveryAction, cardID: UUID)` validates current error/card ID/sessionID/allowed action before any effect. All UI buttons capture current card ID, no direct singleton actions in View.
- Stage retry verifies typed policy again plus actual currentContext/retained nonempty audio/actual ASR index/no event, never legacy retryable. Clear card before work. Original route/audio/lease, fresh handle/new20s budget. No retry injection or hidden polish opt-in.
- Rerecord uses startRecording fresh identity; settings only opens. Recheck refreshes blocked card with new UUID/current reason/actions, ready or degraded idle. Automatic routing only changes policy and refreshes; still blocked stays new card. New session/clear invalidates all old buttons.
- Normal uncertain finish saves history/summary once while owner, closes context and event gate then shows terminal-only card, retaining full final text for explicit copy; viewHistory if entered save path only. Explicit cancel unchanged idle with M3 uncertain saved once. No raw text in published card/log.
- Error capsule380×156, two-column LazyVGrid/rows up to4 actions, two-line safe text; no transcript preview, current theme. Notices remain240×70.

- [ ] **Step 1:** RED integration tests use real controller with synthetic stages and injected SessionEffects/RecoveryEffects/configuration/readiness; real ASR/InjectionStage for meaningful boundaries. Add suite to focused/full runner.
  - Old card after new recording and after refreshed blocked card: iterate every old allowed action (retry/copy/settings/history/rerecord/recheck/route/dismiss across representative cards); counters, clipboard/config, session state/history/summary unaffected. Disallowed current action also no effect.
  - transient retry preserves original PCM/route/lease/language; new realtime handle and20s budget; actual ASR stage only. Conflicting legacy retryable cannot unlock. No saved audio → no retry; configuration no retry even after settings change; rerecord new ID and fresh capture. No implicit requests on settings/recheck.
  - noEngine constrained→auto still blocked mic updates message/actions; ready/degraded clears and remains idle, no AX degrade stays eligible menu path. Two permissions map correct settings and recheck.
  - Startup/invalid audio failures stay error with rerecord, not temporary notice. Optional polish and silence original notices unchanged.
  - Real uncertain typing/paste terminal: persistent card, complete explicit copy via fake board, history navigation only, no retry/double attempt/save/summary. Explicit cancel after actual event saves once then idle, late complete ignored; repeat cancel/dismiss do not save again.
  - Privacy recordTranscript=false and failing/no-op storage: safe uncertain message does not claim stored transcript; no secret/URL/body in card; copy returns complete text only on click. Card has no raw preview. Error size and max4 action layout model.
- [ ] **Step 2:** capture RED, implement pure recovery state/effects then controller-owned validation/transitions and card rendering. Keep lifecycle fields private; no new coordinator/parallel state machine. Clear subscriptions/tasks/gates consistently with M3.
- [ ] **Step 3:** focused GREEN, sequential build/full self-test once stable, preserving all M3 coverage with updated deliberate uncertain-card expectations. Report counts and GUI Pending explicitly.
- [ ] **Step 4:** self-review, scoped commit `feat: bind recovery cards to the current session` with TDD/full evidence.

## Whole-M4 closeout

After task reviews, one independent whole-M4 review uses baseline68c72d4 and checks deferred findings, integration and all five focus cases. Consolidate any findings into one fix wave and one scoped rereview. Build fixed app with existing script without Python/dependency installation; record source tree, commit, binary SHA and honest signing limitations. Archive ledger/reports/tests/reviews to `docs/evidence/2026-11-02-m4-development/`; update `docs/evidence/2026-11-02-m4-validation.md` and remaining audit. True-device V1–V5, real cloud, GUI, acoustic calibration remain Pending unless actually executed. Preserve branch/worktree; no merge/push.
