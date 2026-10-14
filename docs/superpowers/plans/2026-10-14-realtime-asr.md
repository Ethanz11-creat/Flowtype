# Background Realtime ASR and Local Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upload audio during capture to a verified BYOK realtime ASR provider while retaining complete local audio and a bounded final-only fallback.

**Architecture:** Add a transport-agnostic realtime session contract and a DashScope Paraformer adapter backed by injectable WebSocket transport. RecordingStage owns capture fan-out and the session context owns the winning result; ASRStage finalizes or falls back to local/batch. Existing OpenAI-compatible batch configuration remains unchanged unless explicitly marked realtime.

**Tech Stack:** Swift 6.2, Foundation URLSessionWebSocketTask, AVAudioEngine, async/await, existing ASR contracts and self-tests.

**Spec:** `docs/superpowers/specs/2026-10-14-realtime-asr-design.md`; wire authority `docs/superpowers/paraformer-protocol-2026-10-14.md`.

## Global Constraints

- Paraformer realtime uses WSS, Bearer API key, `run-task`, matching `task-started`, binary PCM16 LE mono 16 kHz, `finish-task`, then `task-finished`.
- Do not send WAV, Float32 bytes, Opus, arbitrary prompt/context, or undocumented vocabulary fields.
- Partial sentences are provisional and never rendered/injected; final text is delivered once per session.
- Keep complete Float32 capture for local fallback; localOnly never opens a cloud socket.
- Stop-to-delivery budget is 20 seconds; auto cloud first attempt is bounded to 5 seconds when local is ready.
- Run `swift build` and `swift run FlowType --self-test` before each commit.

## Review Focus

- No binary audio may be sent before the matching task-started event.
- Final Paraformer sentence with `end_time: null` must decode and not duplicate.
- Cancellation and wrong task IDs must not resume a wait or deliver late text.
- Legacy batch cloud profiles must decode and route exactly as before.
- A full realtime queue must drain before finish-task; local fallback must use the complete recording.

### Task 1: Realtime contracts, config, and PCM/assembly pure logic

**Files:**
- Create: `Sources/flowtype/Services/Speech/RealtimeASR.swift`
- Modify: `Sources/flowtype/Services/Speech/ASRContract.swift`
- Modify: `Sources/flowtype/Core/Configuration.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Define `RealtimeASRSession: Sendable` with `func start() async throws`, `func append(samples: [Float]) async throws`, `func finish() async throws -> ASRResult`, `func cancel() async`. Immutable session config snapshots credentials/model/language.
- For nonblocking capture, add a bounded synchronous enqueue/fan-out wrapper instead of one unbounded Task per audio callback.
- Define protocol-kind Codable config with legacy default `.openAICompatible`; expose exact Paraformer model/endpoint preset.
- Produce pure `encodePCM16LE(_ samples: [Float]) -> Data` and `ParaformerSentenceAssembler`; use begin_time as replacement key (official protocol has no sentence_id), final sentence_end controls commitment, nullable end_time accepted.
- `CloudASRProviderConfig.protocolKind` uses `.openAICompatible` or `.dashScopeRealtime`; explicit init/decode defaults preserve all existing callers and JSON.

- [ ] Write fixture tests for signed PCM endpoints/NaN, exact run/finish envelopes, sentence revisions, null end_time, heartbeats, and foreign task IDs.
- [ ] Run self-test and capture expected RED output.
- [ ] Implement contracts/config/fixtures without opening a socket.
- [ ] Run full build and self-test.
- [ ] Commit `feat(asr): add realtime session contract and Paraformer wire models`.

### Task 2: Injectable WebSocket transport and DashScope adapter

**Files:**
- Create: `Sources/flowtype/Services/Speech/DashScopeRealtimeASR.swift`
- Create: `Sources/flowtype/Services/Speech/WebSocketTransport.swift`
- Modify: `Sources/flowtype/Services/Speech/ASRProviderRegistry.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Produce an injectable transport with text/binary send and async receive; production implementation wraps URLSessionWebSocketTask.
- Adapter must enforce start ack before audio, ordered queue/drain, finish once, task ID filtering, start/final timeouts, task-failed/close errors, and cancellation.
- Synchronous capture ingress `seal()` closes accepted-buffer sequence; `finish()` awaits all prior accepted buffers and in-flight send before finish-task. One serial send pump avoids actor reentrant sends; queued+inflight count to 5s bound.
- Validate endpoint WSS/host/port/no credentials/no unresolved placeholder before connection; do not log request key. Test startup timeout-before-waiter, cancel-before-start and stop during suspended last binary send.

- [ ] Add fake transport tests for handshake ordering, bounded queued audio, finish drain, final after finish, timeout, malformed events, and cancellation.
- [ ] Run self-test RED before adapter implementation.
- [ ] Implement production transport and adapter; keep API key in an in-memory session snapshot and never log it.
- [ ] Run build/self-test and commit `feat(asr): implement DashScope realtime Paraformer adapter`.

### Task 3: Capture fan-out, routing, budget, and fallback

**Files:**
- Modify: `Sources/flowtype/Core/Pipeline/SessionContext.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/ASRStage.swift`
- Modify: `Sources/flowtype/Services/Speech/ASRRouter.swift`
- Modify: `Sources/flowtype/Core/Configuration.swift`
- Modify: `Sources/flowtype/Settings/CloudASRProviderList.swift` (or actual editor file discovered via rg)
- Modify: `Sources/flowtype/Settings/SettingsPage+ASR.swift`
- Modify: `Sources/flowtype/Services/Speech/CloudASRProvider.swift`
- Modify: `Sources/flowtype/Core/Pipeline/Stages/PolishStage.swift`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

**Interfaces:**
- Add session-scoped realtime handle and result snapshot; RecordingStage appends every valid buffer without blocking audio callback.
- Add monotonic `CompletionBudget` with `remainingSeconds` and per-stage timeout; create at stop for 20 seconds; auto cloud attempt max 5 seconds with local ready; polish min(3, remaining). Respect user cancel.
- Registry cloud identity remains ASRProviderID.cloud; dispatch protocolKind via capabilities/factory, no provider runtime casts. Batch provider sees immutable request config and no third-party WS URL sent to HTTP multipart.
- Capture explicit ordered PCM closure before engine starts, retain all complete samples; allow realtime start in parallel with capture/context. Extend stopped cleanup to distinguish finish vs cancellation.
- Settings expose protocol kind and Paraformer preset; save Key in cloudASRConfig.providerAPIKeys (actual existing ASR key location, separate from LLM keys). Test button must not send paid silence for realtime; label configuration validation honestly.
- If stop budget expires after full ASR exists, deliver full raw. No text means error. Retry creates a new realtime task or uses stored batch/local samples, not stale finish handle.
- For a WSS profile without a live handle, implement saved-audio transcription by fresh session + bounded sequential chunks/drain; never send WSS config to HTTP and never bulk overflow live queue.
- Deadline completion uses single-resume owner/unstructured cancellable producer, not task-group join on synchronous Qwen/AX. LLM receives deadline and termination cancellation; no next-provider attempt after cancelled.
- Snapshot capture-start route once; carry it through stop/final rather than reserving half-open twice.

- [ ] Test localOnly/no-key no socket, cloud start during capture, queue overflow, bounded stop, realtime failure to local, and one winner.
- [ ] Run self-test RED.
- [ ] Implement fan-out and ASR final selection; use batch/local fallback with complete samples and enforce 20s/5s budgets and cancellation.
- [ ] Run full build/self-test and commit `feat(asr): stream capture in background with bounded local fallback`.

### Task 4: Health recovery and protocol validation

**Files:**
- Modify: `Sources/flowtype/Services/Speech/ASRRouter.swift`
- Modify: `Sources/flowtype/Services/Speech/CloudProbe.swift`
- Create: `docs/2026-10-14-realtime-asr-validation.md`
- Test: `Sources/flowtype/Testing/SelfTest.swift`

- [ ] Add pure half-open recovery tests, endpoint/model identity invalidation, and no probe on forced/local modes.
- [ ] Document real Key/weak network/offline/cancel/manual protocol matrix without claiming unrun results.
- [ ] Implement one bounded real request recovery attempt per 60 seconds; preserve conservative slow evidence.
- [ ] Run full build/self-test and commit `fix(asr): bound realtime health recovery and validation`.
