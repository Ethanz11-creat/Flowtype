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

