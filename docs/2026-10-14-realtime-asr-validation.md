# Realtime ASR validation

Design: [realtime ASR](superpowers/specs/2026-10-14-realtime-asr-design.md).
Wire contract: [Paraformer protocol](superpowers/paraformer-protocol-2026-10-14.md).
Updated: 2026-10-15.

## Automated scope

`swift build` and `swift run FlowType --self-test` verify compiled production
code with pure health state, injected router dependencies, URLProtocol fixtures,
and an in-process fake WebSocket transport. They do not use real credentials,
microphones, paid silence, cloud ASR, or production TLS probes.

Health checks cover one atomic capture-start recovery reservation per 60
monotonic seconds; cooldown boundaries despite wall-clock jumps; failure keeping
slow evidence; successful real recovery replacing the old slow EWMA and failure
streak; separate realtime stop-to-final and batch latency; slow/failed probes
vetoing fast EWMA; fast probes preserving slow actual inference evidence; and
endpoint/model/protocol/provider UUID or network changes rejecting old request
and probe tokens. Injected router tests exercise concurrent capture calls and
configuration changes while a fake probe is suspended. Forced cloud/local
policies do not probe or reserve recovery. Expensive, constrained, and offline
probe gating is checked with pure path signatures. HTTPS/WSS endpoint parsing
checks default/custom ports and rejects zero/out-of-range ports and userinfo.

The existing codec/adapter/pipeline checks cover ack-before-PCM ordering,
bounded ingress and sequential sends, revisions/finals/null timestamps, wrong
task IDs, finish/drain races and deadlines, cancellation, final-only delivery,
full saved audio on local fallback, WSS/HTTP isolation, and total stop budgets.
These fixtures establish regression behavior, not live service compatibility.

## Manual acceptance matrix

All rows below are **Pending**. No real microphone, service, network-shaping,
AX permission, or CGEvent run was performed for this task. Enter actual date,
build commit, macOS/device, service region/model, observed content-free timings,
and pass/fail evidence when executing a row. Never include API key values,
audio, foreground context, or transcript content in shared evidence.

| Scenario | Procedure and expected observation | Status |
| --- | --- | --- |
| Local configuration validation | Add Paraformer WSS preset and ASR key; use validate configuration. It reports local validity and that a real recording will verify service; no paid silence/socket request. | Pending |
| Real key / normal network | With local model ready and auto policy, dictate and stop. Observe official `task-started` before binary PCM, `finish-task` followed by `task-finished`, and exactly one final insertion. Measure stop-to-final separately from recording time. | Pending |
| Invalid/revoked key | Real recording returns a structured service error; auto falls back once to local using the complete recording. Cloud-only returns a retryable error. Never log the key. | Pending |
| Weak network / slow inference | Add delay or bandwidth restriction. Stop-time cloud attempt is bounded by min(5 s, remaining) with local ready; local receives the remainder of the 20 s budget. No intermediate cloud text appears. | Pending |
| Offline before capture | Disconnect before recording. Auto uses local; no recovery request or handshake probe starts while the observed path is offline. | Pending |
| Disconnect during streaming | Disconnect after task ack while speaking. Cloud closes/fails; complete accepted audio reaches local after stop; one final result is delivered. | Pending |
| Long recording / backpressure | Dictate beyond five seconds, including a throttled socket. Streaming drains in order; queued plus in-flight audio stays bounded. Overflow terminates cloud and preserves the full local recording. | Pending |
| Network switch with in-flight work | Switch Wi-Fi/hotspot/VPN during a probe and recording. Old network-generation results cannot write new health. The active recording keeps its captured service configuration. | Pending |
| Profile change with in-flight work | Change endpoint, model, protocol, or provider UUID during recording/probe. New health starts clean; old results cannot update it. HTTP remains HTTP and WSS never uses multipart. | Pending |
| Real half-open recovery | First establish failed/slow cloud health. Trigger user recordings within and beyond 60 s: one capture gets a cloud recovery slot, others retain local priority. Failure stays conservative; a successful fast real request restores cloud priority. No background audio upload occurs. | Pending |
| Metered / constrained network | Mark the current link expensive or enable low-data mode. No TLS probe starts; routing keeps the explicit policy rather than guessing fee preferences. | Pending |
| Explicit policies | In localOnly, record/stop/retry: no cloud socket, probe, audio, or context transmission. In cloudOnly, cloud remains selected even when health is poor and no recovery slot is consumed. | Pending |
| Cancel and late events | Cancel during start, streaming, stop/final wait, and fallback; then reconnect. No fallback/replay begins after cancellation, no late result inserts text, and the next session owns its own completion. | Pending |
| Actual macOS delivery | Verify microphone readiness, AX/CGEvent insertion, recording feedback, and focus behavior in supported apps. Final text appears once; ASR/LLM partials remain hidden. | Pending |
