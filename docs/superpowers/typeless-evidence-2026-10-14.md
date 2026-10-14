# Typeless evidence recheck for FlowType — 2026-10-14

Read-only audit. Base directory for all evidence paths below: `/Users/yiheng/pycode/typeless-re/`. `R` = `TYPELESS-2.8.1-REVERSE-ENGINEERING.md`; `Q` = `sources-recovered/renderer/static/js/qA149QP2.mjs`; `U` = `sources-recovered/renderer/static/js/UfR9-a2Z.js`; `M` = `sources-recovered/main/index.js`. Grades: O observed static code; D derived from observed facts; I inferred; U unknown. Recommendations are FlowType design choices, not Typeless facts.

## Most important corrections

1. **600ms is not evidence for normal hold-to-talk.** `LONG_PRESS_MS=600` is O (`Q:4655`, timer at `Q:6079–6086`). `awaiting_long_press_or_tap` receives LONG_HOLD and enters `long_pressing` (`Q:5491–5495`); its entry shows “do not hold just press”, stops recording and clears audio ID (`Q:5546–5555`); key release returns idle. Release before this transition selects hands-free (`Q:5519–5533`), including release during initialization (`Q:5354–5355`). `pushToTalk` exists and stops on key-up (`Q:5616–5637`), but existence alone does not establish its normal reachability. R's state diagram elides substate selection and its headline short/long/double-click description is too compressed to copy as a UX specification. `notes/p3-ux-pipeline.md:53` explicitly calls long hold invalid. Define FlowType gestures deliberately and test their event timelines.

2. **500ms is a wrapper delay, not a paste acknowledgement.** O: main wrapper sets `isInserting`, calls native function, only waits 500ms for return code 1, swallows exceptions, then clears guard (`M:11714–11726`; rich-text analogue `11728–11740`). There is no visible target-readback confirmation here. Native clipboard save/write/Cmd+V/restore sequence is D from symbols, not native behavioral proof (`R:216–218`, `R:693`). Exact delay meaning and native error codes are explicitly U (`R:739–740`). Do not mark delivered after arbitrary sleep or automatically retry an uncertain paste.

3. **“Pre-insertion editability check” is overstated.** O: `dr()` obtains context (`Q:3860`), awaits `g(refinedText)` (`3861`), then evaluates `is_editable` (`3862`) and chooses editing tracking/fallback (`3864–3869`). App/URL policy classification exists (`Q:3935–3959`), but this caller does not prove editability/target identity is validated before paste. The report's broader safety claim (`R:384–385`) requires deeper call-chain evidence. Native target identity checking, focus-change behavior, and actual paste acknowledgement remain U.

4. **WS/HTTP is a delayed result race, not proven streaming reconnect/resume.** O: `startRefineRace` creates per-audio WS and fallback promises, races, aborts fallback if WS wins, records completed ID, delivers once, cleans audio (`U:8301–8358`). Weak-network metadata can select immediate fallback; otherwise it sends primary logic and schedules fallback (`U:8359–8365`). Fallback waits for full-audio compression and configurable delay (`U:8381–8412`), posts full audio with reasons `chunk_processing_timeout`/`final_message_timeout` (`U:8414–8429`), and resolves only successful text/paywall paths (`U:8431–8462`). Cancellation and completed IDs exist (`U:8368–8379`, `U:8755–8775`). Do not equate transport reconnect with session continuity or copy “race every provider immediately”.

5. **Partial semantics and server refinement remain partly unknown.** O: partial handler appends `{text, chunk_index, audio_id: currentAudioId}` to an array (`U:8734–8748`); it does not replace an earlier index, reconcile revisions, or validate payload audio_id in that function. Final handler consumes separate `refined_text` and uses audio IDs for completion (`U:8750–8784`). Server ASR model, precise token/delta semantics, revision behavior, prompts, and generation timing are U/I (`R:722–732`, `R:760`). “ASR then refinement” is a client protocol distinction, not proof of a specific LLM or internal model pipeline.

## Useful evidence that survives recheck

| Mechanism | Grade and evidence | FlowType implication |
|---|---|---|
| Explicit recording/error/retry state machine | O, R:223–226; Q:5175–5950 | Centralize transitions and cancellation; distinguish capture, finalization, delivery, recoverable error. Preserve session ID across callbacks. |
| 100ms audio flush; metadata before binary, sequence index | O, R:39–44, R:323–324; Q:3204; U:8136–8148 | Background transport is compatible with final-only UX. Actual codec/chunk format must follow each BYOK provider contract. |
| Audio encoding off UI thread | O static worker/config evidence, R:188–191; actual runtime process details bounded by R:770 | Keep capture/encoding/transport off MainActor; Swift implementation need not recreate Electron worker/FFI topology. |
| Partial not rendered in reviewed client | O limited to inspected sources, R:424–425; R:348–349 | Background streaming need not expose live text or perform incremental insertion. Recovery/result arbitration still required. |
| Local history supports retranscription retry | O report call-chain, R:223–225 | Preserve complete audio for local Qwen fallback/retry and recoverable result presentation. Cloud failure must not discard recording. |
| Context fields and mode parameters passed separately | O fields/channels/encryption, D native AX mechanism, R:358–359, R:379–380 | Snapshot bounded app/selection/nearby-text context at capture start. Keep ASR hints distinct from optional refinement; provider support varies. |
| Native paste helper and plain/rich text IPC | O bindings/channels, D internal clipboard behavior, R:216–218 | One final delivery action with explicit result state, serialized clipboard ownership, and user copy fallback. |
| Early no-speech detector; 9-minute ceiling | O reported constants/code, R:181–183 | Adopt explicit duration/capture-health limits; do not mistake one-time volume probe for endpoint VAD. Choose thresholds for FlowType microphones. |

## Actionable constraints for the three plans

### 1. Session interaction and recovery

- Specify tap, hold, key-up-before-initialization, repeated key-down, double-tap, Escape, interruption, permission denial, and finishing reentry in a transition table. Typeless names/600ms do not decide FlowType semantics.
- Create a session generation/ID and one terminal completion gate; all capture, provider, refinement, fallback and delivery callbacks must prove current ownership. Cancellation invalidates pending work and must never paste late results.
- Distinguish “recording safely captured”, “recognition failed”, “text ready”, “delivery attempted”, “delivery confirmed/uncertain”. Retain recoverable text/audio and support explicit retry/copy.
- UI remains native Swift and responsive; status/waveform may update, final text appears once. Local Qwen remains available.

### 2. Background realtime cloud ASR with local fallback

- Use a provider capability boundary: streaming upload/events versus whole-recording API, accepted codec/sample rate, finalization signal, revision identity, auth and timeout behavior. OpenAI-compatible HTTP settings alone do not establish realtime WS support.
- Start background recognition during capture where actually supported; retain a complete local audio buffer/file throughout. Local-only mode must never require cloud access.
- Treat partials as provisional internal state; normalize replacement/delta semantics per provider. Use an explicit final result after finish; optional text refinement is separate and can fail back to recognized text.
- Define bounded streaming-final timeout and when local Qwen starts. Pick one winning final by session ID; cancel/ignore losers; never insert twice. A delayed fallback can improve latency without duplicating every request from the outset.
- Full-recording local fallback is a FlowType requirement, not a Typeless reverse-engineered feature. HTTP cloud fallback may be an additional provider feature, not a substitute.

### 3. Delivery and context accuracy

- Capture target identity and context at start; revalidate app/PID, focused element and editability immediately before delivery. Focus movement must resolve to explicit recoverable text/copy rather than blind paste.
- Clipboard transaction must preserve supported clipboard representations and restore only if still owned (change-count/token), so user clipboard writes are not overwritten. Guard both duplicate delivery and concurrent insertion.
- Separate attempted injection from confirmed insertion; AX readback may provide evidence in supported fields, while unsupported/ambiguous applications need an honest uncertain result. Never auto-repeat uncertain delivery.
- Context is bounded input data, not trusted instruction. Do not scrape indiscriminately or treat app whitelist membership as proof that a specific element is writable. Preserve local/BYOK policy.
- Refinement must preserve meaning and terminology; raw ASR text remains a recovery fallback. Dictionary hints and optional postprocessing should remain provider-independent.

## What not to copy blindly

Do not copy Typeless endpoints, hardcoded crypto keys/query-auth design, Electron renderer AudioWorklet/FFI layout, cloud-only/no-model architecture, fixed 600ms/500ms/100ms constants, close-code lists, app blacklist contents from 2.5.0, append-only partial handling, opaque native success codes, or unconditional server-side context/refinement assumptions. FlowType's native Swift + local Qwen + BYOK requirements intentionally differ.

## Evidence limits

Report is 2.8.1 static analysis; some runtime corroboration is explicitly 2.5.0 (`R:7`). No TLS capture and no native behavioral disassembly were performed (`R:8–9`). Recovered source covers 11/83 JS inputs; negative searches over that subset do not prove absence everywhere (`R:800–805`). “No VAD”, “no incremental display”, and exact server pipeline claims must retain this scope. Do not invent paste confirmation, streaming revision logic, backend model identity or reconnection continuity to fill those gaps.
