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

