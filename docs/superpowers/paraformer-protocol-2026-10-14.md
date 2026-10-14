# Verified DashScope Paraformer realtime protocol for FlowType

Fetched 2026-10-14 (local task date). Public official HTML only; no credentials, microphone, paid ASR call, or repository edits were used.

## Sources

1. https://help.aliyun.com/zh/model-studio/websocket-for-paraformer-real-time-service — endpoint, authentication, ordering.
2. https://help.aliyun.com/zh/model-studio/paraformer-client-events — exact run-task and finish-task structures and supported parameters.
3. https://help.aliyun.com/zh/model-studio/paraformer-server-events — exact server events, partial/final/heartbeat fields.
4. https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide — binary audio examples, PCM16 mono, s16le ffmpeg conversion.
5. https://help.aliyun.com/zh/model-studio/asr-model — model/language support, single-channel input.
6. https://help.aliyun.com/zh/model-studio/improve-asr-accuracy — Paraformer precompiled vocabulary support, model match constraint, no Paraformer context/immediate vocabulary support.

The proposed /use-paraformer-to-recognize-speech-from-real-time-audio-streams URL now returns an Aliyun 404 content page despite HTTP 200. The working guide is source 4.

Cached HTML/text copies are /tmp/flowtype-paraformer-websocket.*, /tmp/flowtype-paraformer-client-events.*, /tmp/flowtype-paraformer-server-events.*, /tmp/flowtype-real-time-speech-recognition-user-guide.*, /tmp/flowtype-asr-model.*, /tmp/flowtype-improve-asr-accuracy.*.

## Chosen production adapter

Implement the documented DashScope task protocol with model `paraformer-realtime-v2` and 16,000 Hz mono signed 16-bit little-endian raw PCM. This model is officially available in Beijing only and supports Chinese (multiple dialects), English, Japanese, Korean, German, French and Russian. Current official model selection guide describes Paraformer as an older generation and recommends Fun-ASR/Qwen-ASR where migration is possible; Paraformer remains a documented production API and satisfies the requested Chinese/English adapter. Do not confuse this protocol with Qwen realtime `/api-ws/v1/realtime` session.update/base64 APIs.

Endpoint supported today: `wss://dashscope.aliyuncs.com/api-ws/v1/inference`.
New officially recommended workspace endpoint: `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`; replace WorkspaceId with actual ID, never transmit the braces literally. Official guide explicitly says the existing dashscope.aliyuncs.com domain still works. Both are WSS. The public endpoint removes the need to require an additional Workspace ID in the first integration.

WebSocket upgrade header: `Authorization: Bearer <user API key>` (Beijing API key). Authentication happens at upgrade; missing/invalid key fails with HTTP 401/403. Optional `user-agent` and `X-DashScope-WorkSpace` are documented. No token endpoint, access-key signing or server proxy is needed for this user BYOK app.

## Lifecycle and send framing

1. Open socket with authorization header; start receiving.
2. Send a TEXT `run-task` JSON frame.
3. Await the matching task_id `task-started` before sending any audio binary frames.
4. Send mono PCM as BINARY frames while concurrently receiving results. No base64, JSON wrapper or WAV header for format=pcm. Official examples use 3200 bytes per 100 ms at 16 kHz PCM16. Smaller application chunks are not explicitly forbidden; sample framing must remain complete (even byte count).
5. On user stop, drain all queued audio, then send exactly one TEXT `finish-task` with the same task_id.
6. Keep receiving and accepting results during this drain. `finish-task` is not final recognition; `task-finished` is the task completion event.
7. Close normally after task-finished (connection reuse is documented but one task per connection is simpler).
8. `task-failed` closes the connection and makes reuse unavailable. Premature transport close must not silently return success. Cancellation closes socket and must unblock pending waits.

Recommended application timeouts: bounded connect/start and final-drain deadlines. Exact timeout budgets are application decisions; documentation example error mentions 23 s but this is not a universal contractual timeout. A connection probe should validate configuration locally by default; connecting/running a silence task is an actual cloud call and may cost money.

## Exact client fixtures

Task ID below is a valid UUID-shaped test constant. Official event docs use UUID format (example with hyphens); user guide uses uuid4().hex[:32]. Use a fresh UUID per real task, matching every frame.

```json
{
  "header": {
    "action": "run-task",
    "task_id": "2bf83b9a-baeb-4fda-8d9a-123456789abc",
    "streaming": "duplex"
  },
  "payload": {
    "task_group": "audio",
    "task": "asr",
    "function": "recognition",
    "model": "paraformer-realtime-v2",
    "parameters": {
      "format": "pcm",
      "sample_rate": 16000
    },
    "input": {}
  }
}
```

Optional language hints are `parameters.language_hints: ["zh"]` or `["en"]`; omit in automatic mode. Both are documented strings, not `language` and not locale `zh-CN`. Omit for Chinese-English mixed dictation to permit auto recognition; mixed-language quality has not been live-tested.

```json
{
  "header": {
    "action": "finish-task",
    "task_id": "2bf83b9a-baeb-4fda-8d9a-123456789abc",
    "streaming": "duplex"
  },
  "payload": {
    "input": {}
  }
}
```

Other documented v2 parameters: `semantic_punctuation_enabled` default false (VAD instead of semantic splitting); `max_sentence_silence` default 1300, range 200...6000 ms, applies only with semantic false; `multi_threshold_mode_enabled` default false; `punctuation_prediction_enabled` default true; `inverse_text_normalization_enabled` default true; `disfluency_removal_enabled` default false; `heartbeat` default false. For a minimal adapter preserve defaults. Heartbeat true allows sustained silence to keep the connection alive, not an app-generated JSON ping contract.

## Exact server fixtures and assembly

```json
{"header":{"task_id":"2bf83b9a-baeb-4fda-8d9a-123456789abc","event":"task-started","attributes":{}},"payload":{}}
```

Partial fixture derived from documented shape:

```json
{"header":{"task_id":"2bf83b9a-baeb-4fda-8d9a-123456789abc","event":"result-generated","attributes":{}},"payload":{"output":{"sentence":{"begin_time":170,"end_time":null,"text":"好，我","heartbeat":false,"sentence_end":false,"words":[]}},"usage":null}}
```

Final official fixture (task ID sanitized only). Note that official server-event example surprisingly has `end_time: null` even when sentence_end is true; user-guide example uses end_time 920. Decoder must tolerate null. Never infer finality from end_time.

```json
{
  "header": {
    "task_id": "2bf83b9a-baeb-4fda-8d9a-123456789abc",
    "event": "result-generated",
    "attributes": {}
  },
  "payload": {
    "output": {
      "sentence": {
        "begin_time": 170,
        "end_time": null,
        "text": "好，我知道了",
        "heartbeat": false,
        "sentence_end": true,
        "words": [
          {"begin_time":170,"end_time":295,"text":"好","punctuation":"，"},
          {"begin_time":295,"end_time":503,"text":"我","punctuation":""},
          {"begin_time":503,"end_time":711,"text":"知道","punctuation":""},
          {"begin_time":711,"end_time":920,"text":"了","punctuation":""}
        ]
      }
    },
    "usage": {"duration":3}
  }
}
```

`usage` is under payload, sibling to output in actual JSON, despite the rendered field hierarchy looking confusing. It is irrelevant for transcript assembly. Text already contains punctuation; do not append word punctuation on top of sentence.text.

```json
{"header":{"task_id":"2bf83b9a-baeb-4fda-8d9a-123456789abc","event":"task-finished","attributes":{}},"payload":{"output":{},"usage":null}}
```

```json
{"header":{"task_id":"2bf83b9a-baeb-4fda-8d9a-123456789abc","event":"task-failed","error_code":"CLIENT_ERROR","error_message":"request timeout after 23 seconds.","attributes":{}},"payload":{}}
```

The documented Paraformer sentence has begin_time, end_time, text, heartbeat, sentence_end and words; no sentence_id is documented in its server schema. Other models on the shared guide use sentence_id, so do not require it for Paraformer. Treat partial sentence text as a full replacement, never append each partial. A practical assembler can store finalized sentences indexed by begin_time, and one current partial; finalized result replaces the current partial, repeated final for the same begin_time replaces rather than duplicates. Ignore heartbeat=true. Task ID mismatches cannot mutate this task. `task-finished` is terminal and does not itself contain transcript text. Unknown fields should be tolerated. Same-begin-time revisions are plausible; guarantee of stable begin_time is not explicit in these docs, so this indexing policy is an application inference to test rather than a documented sentence-ID promise.

## Audio conversion in this app

ASRProvider.swift explicitly defines existing `ASRRequest.samples` as 16 kHz mono Float32 raw samples. These Float32 bytes cannot be sent directly with format=pcm. Clamp finite floats to [-1,1], map to Int16 and serialize little endian, handling NaN/infinity as silence and avoiding overflow at +1. The exact rounding choice is local; test endpoints and total bytes. No WAV wrapper is needed.

Official guide demonstrates PCM16 16 kHz mono and `ffmpeg -i your_audio.mp3 -ar 16000 -ac 1 -f s16le your_audio_file.pcm`, substantiating little-endian signed PCM format. 1600 float samples -> 3200 byte PCM chunk -> 100 ms audio.

## Vocabulary and context support

- `parameters.vocabulary_id` is explicitly supported, and refers to a precompiled server-side vocabulary. Create it separately targeting exactly `paraformer-realtime-v2`; docs say model mismatch does not error but vocabulary silently has no effect. Status must be OK before use.
- Paraformer permits at most 500 vocabulary entries per list (official improve-accuracy guide). Lists are persistent resources, account limit 10 across all models.
- Paraformer is NOT listed among models supporting immediate per-request `vocabulary` or context enhancement. Do not invent `prompt`, `input.context`, `continue-task`, direct `hotwords`, or arbitrary user dictionary arrays in this adapter.
- Existing generic cloud capabilities claim supportsContextHint=true because multipart passes `prompt`; that must not be carried over to the Paraformer realtime adapter. Mark context hints unsupported unless implementing the separately documented vocabulary-resource workflow. Rewriting/postprocessing remains a different stage.

## Existing integration surface (source inspection only)

- `Sources/flowtype/Services/Speech/CloudASRProvider.swift` is an actor conforming to batch `ASRProvider`; it buffers samples into WAV, posts multipart to OpenAI-compatible transcription, reads effectiveCloudASRConfig per call, and retries batch network/server failures. Its `testConnection` sends generated silence remotely. Do not route realtime WebSocket settings through its HTTP builder.
- `Sources/flowtype/Services/Speech/ASRProvider.swift` has only `transcribe`, no realtime session lifecycle. A separate session protocol/start-append-finish-cancel abstraction is needed for real streaming capture.
- `CloudASRProviderConfig` in Configuration.swift currently has id/name/provider/baseURL/model/isActive with no transport/provider-kind discriminator. Default SiliconFlow uses https://api.siliconflow.cn/v1 and no model. New decoding must preserve old profiles as batch HTTP; do not infer protocol exclusively from display name.
- `CloudASRConfig` holds per-provider API keys. Research read only source declarations, never configuration files or stored key values. Adapter should snapshot configuration at session creation rather than change credentials mid-session.

## Offline test plan (no microphone, network or key)

Inject a fake WebSocket transport exposing connect/sendText/sendBinary/receive/close and a deterministic clock/deadline or short injected budgets. Record outgoing messages and feed fixtures explicitly; credentials should be a hardcoded fake test value only.

1. Connect request uses WSS + Authorization, and run-task exact envelope/model/PCM parameters. Assert no binary send until matching task-started, and early captures are queued in order.
2. PCM conversion fixtures [-1, -0.5, 0, 0.5, 1, NaN, infinity] have known little endian bytes, two bytes/sample, no WAV/Float32 payload, bounded queue limit.
3. Revisions partial `你好` -> partial `你好世界` -> final `你好世界。` produce one phrase, and subsequent sentence is combined once. Final with null end_time must decode. Repeated final for same start does not duplicate. Heartbeat and foreign task_id are ignored/rejected consistently.
4. Stop sends queued audio before one finish-task and accepts final result sent after finish; returns only upon task-finished. An empty successful task yields an explicit empty result policy.
5. task-failed surfaces code/message, cleans transport and resumes pending start/final waits once. Invalid/malformed event, socket close, startup timeout and finish timeout do not hang or leak pending continuations.
6. Cancellation during handshake, queued audio, active receive and final drain closes promptly; late callback cannot restore state or insert text. No batch retry/replay of an active stream by default.
7. Legacy provider config decodes to batch transport; valid realtime config has correct endpoint/model and cannot be selected on missing key. Tests operate on in-memory configuration only.

No live service behavior was measured; docs verify the wire contract, not latency, recognition quality, availability for a particular user account, or production handshake implementation. Validate those with an explicit user-triggered real session after implementation.
