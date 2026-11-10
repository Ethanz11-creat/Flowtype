# A3 registered batch adapters and loopback boundaries

Status: DONE. Base: `43f7d68`. No external services installed or contacted by tests; no real keys, user configuration, microphone, clipboard, permissions, model paths, or system trust stores changed. `Package.resolved` unchanged. No full suite run: controller reserves that for A6.

## Implemented

- Added `ASRServiceAdapter`, OpenAI-compatible and whisper.cpp factories, duplicate/unsupported protocol rejection, production static registration, and immutable local-service bindings. Service identities are `service:<profile UUID>`; descriptors preserve profile revision and captured credential generation, declare socket use independently from internet need, and omit a client model for whisper.cpp.
- `LocalASRServiceEndpoint.transcriptionURL(profile:)` accepts canonical HTTP(S) only for exact localhost, 127.0.0.1, and [::1]. Rejects userinfo, query/fragment, empty/out-of-range/noncanonical ports, percent encoding, backslashes, alternate IP notation, other hosts/IPs and case/trailing-dot confusion. Protocol suffix normalization avoids duplicate `/audio/transcriptions` or `/inference`.
- At upload, localhost resolves via getaddrinfo. Every returned numeric address must be exactly 127.0.0.1 or ::1; empty, mixed external, and failed results fail before upload. The outgoing URL uses the selected numeric address, preventing URLSession from doing a second hostname lookup. Original authority, explicit port and IPv6 brackets remain in Host. This is destination binding, not a string-only allowlist.
- Loopback sessions are ephemeral with empty proxy dictionary, no cache, cookies or credential storage. Every redirect is refused; audio/credentials are never resent to the Location target. Cloud keeps its existing HTTPS-only endpoint validator and existing session/proxy behavior, and uses the same redirect policy.
- For HTTPS localhost, the task policy accepts only a server-trust challenge matching the pinned numeric HTTPS origin and port. It sets SecPolicyCreateSSL(true, localhost), evaluates with normal system anchors, and uses a trust credential only after success. Numeric hosts and cloud use standard URLSession handling. No trust-all or certificate fallback. Synthetic challenges cover allowed/denied trust, wrong host, wrong port, wrong authentication method; an untrusted self-signed fixture fails the real normal-anchor evaluator. No trust store mutation.
- Shared `ASRMultipartRequest` uses existing WAVEncoder for PCM16, 16 kHz, mono, preserving known exact WAV bytes. Shared `ASRHTTPTransport` reads with URLSession.bytes incrementally, limits data to 2 MiB (including chunked/no-length responses), rejects malformed/NDJSON/HTML envelopes and whitespace-only text, cancels underlying work on exit, checks cancellation before and after transport, and sanitizes error bodies. Existing timeout/cancel/status classification is retained via CloudASRError.
- Actual multipart bodies for known OpenAI gpt-transcribe/whisper-1 profiles fail before send above 25,000,000 bytes. Unknown/custom and other providers receive no invented global limit. Audio is never truncated.
- `LocalASRServicePreset.makeProfile(baseURL:modelID:)` is creation-only: MLX Audio and WhisperKit use OpenAI-compatible plus JSON/language/prompt capabilities; whisper.cpp owns `/inference`, requires JSON and omits model; custom OpenAI-compatible starts with minimal fields. URL/model are supplied by the caller, with no guessed port or service lifecycle operations.
- OpenAI new-profile default is `gpt-transcribe`, with verified prompt support and no mapping from singular language to languages. Old whisper-1 values remain untouched and selectable, retain their existing verified JSON wire capability, and gain deprecated presentation metadata. No credential, routing/snapshot, discovery, UI or persistence implementation beyond the A3 registry was added.

## Source evidence

Used the existing verified artifact `build/asr-model-center-research/openai-speech-md.raw` and manifest `docs/superpowers/research/2026-11-09-asr-model-center-sources.json`, source `openai-speech-md`:

- https://developers.openai.com/api/docs/guides/speech-to-text.md
- Recorded status 200, 39,328 bytes, SHA-256 `bffa0b8c1fca2ac545a311cb32f7ae082898853a1347700f149462119017e4bb`.
- Guide explicitly recommends gpt-transcribe, documents prompt/keywords/languages and the replacement of singular language, 25 MB upload allowance, and deprecation of whisper-1 with shutdown February 26, 2027.
- Existing manifest also pins MLX Audio server, whisper.cpp server/readme and WhisperKit readme. No live account support claim is made. Initial direct model-page curl requests returned Cloudflare HTML; they were not treated as evidence or retried after the saved official artifacts were identified.

## TDD / verification evidence

All builds and runners were sequential. Logs live beside this report and are ignored task artifacts.

1. RED interfaces: wrote transport/profile/endpoint/limit tests and registered them in the backend runner before production implementation.

   `swift build > .superpowers/sdd/2026-11-09-asr-model-center/A3-red-build.log 2>&1`

   Exit 1; expected missing `LocalASRServiceEndpoint`, `ASRHTTPTransport`, adapters/registry interfaces.

2. Compiling runtime RED:

   `swift build > .superpowers/sdd/2026-11-09-asr-model-center/A3-build2.log 2>&1`

   Exit 0. Then:

   `swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A3-red-backends.log 2>&1`

   Exit 1; 759 passed / 15 failed. Four intended new-OpenAI-default/capability/catalog/draft assertions failed against old whisper-1 defaults. Eleven wire failures identified URLProtocol body-stream capture missing in the test fixture, corrected before interpreting wire assertions as production evidence.

3. RED new preset/TLS interfaces:

   `swift build > .superpowers/sdd/2026-11-09-asr-model-center/A3-red2-build.log 2>&1`

   Exit 1; expected missing LocalASRServicePreset and task-owned trust-evaluator injection. Implemented those interfaces and retained real normal-anchor trust evaluation as the production default.

4. Initial GREEN:

   `swift build > .superpowers/sdd/2026-11-09-asr-model-center/A3-build4.log 2>&1`

   Exit 0, Build complete (35.39s), no warnings. Then:

   `swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A3-green1-backends.log 2>&1`

   Exit 0, 791 passed / 0 failed.

5. Behavioral mutation RED for actual size protection: strengthened oversized-response fixture to valid JSON, added exact-2MiB acceptance, actual local redirect delivery/no resend, and bearer cases. Temporarily changed response ceiling to 3 MiB and OpenAI upload limit to nil.

   `swift build > .superpowers/sdd/2026-11-09-asr-model-center/A3-mutation-red-build.log 2>&1`

   Exit 0 (32.76s). Then:

   `swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A3-mutation-red-backends.log 2>&1`

   Exit 1, 796 passed / 3 failed. Both intended mutations were caught: “response: malformed/oversize rejected” and “upload: actual OpenAI multipart over 25000000 bytes rejected”. The third failure was an overly specific expectation that refused synthetic URLProtocol redirects surface HTTP 307; the fixture can instead finish with a transport error. The assertion now requires request failure and independently verifies exactly one pinned request and zero requests to the external target. The direct delegate test verifies nil redirect continuation. Restored both production limits.

6. Final GREEN:

   `swift build > .superpowers/sdd/2026-11-09-asr-model-center/A3-final-build.log 2>&1`

   Build complete (30.94s), no compiler warnings/errors. Then:

   `swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A3-final-backends.log 2>&1`

   Exit 0, **799 passed / 0 failed**. This includes all existing backend/credential/draft/settings/connection-ownership checks, plus existing CloudProvider configuration and real injected URLSession transport checks (HTTPS-only, required key/model, WAV bytes, optional fields, malformed responses, status, timeout, cancellation, redirect and sensitive-log exclusion). `git diff --check` clean. A final unchanged-source `swift build` recheck also exited 0 (see A3-final-recheck-build.log).

## Changed files

- Sources/flowtype/Core/Configuration.swift
- Sources/flowtype/Services/Speech/ASRProviderRegistry.swift
- Sources/flowtype/Services/Speech/CloudASRProvider.swift
- Sources/flowtype/Services/Speech/CloudProviders/CloudASRVendor.swift
- Sources/flowtype/Services/Speech/CloudProviders/CloudTranscriptionRequestBuilder.swift
- Sources/flowtype/Services/Speech/Backends/ASRHTTPTransport.swift
- Sources/flowtype/Services/Speech/Backends/ASRMultipartRequest.swift
- Sources/flowtype/Services/Speech/Backends/ASRServiceAdapter.swift
- Sources/flowtype/Services/Speech/Backends/LocalASRServiceEndpoint.swift
- Sources/flowtype/Services/Speech/Backends/LocalASRServicePreset.swift
- Sources/flowtype/Services/Speech/Backends/OpenAICompatibleASRAdapter.swift
- Sources/flowtype/Services/Speech/Backends/WhisperCppASRAdapter.swift
- Sources/flowtype/Testing/ASRBackendSelfTests.swift
- Sources/flowtype/Testing/ASRBackendTransportSelfTests.swift
- Sources/flowtype/Testing/CloudProviderSelfTests.swift
- Sources/flowtype/Testing/ProviderDraftSelfTests.swift

## Self-review / limitations

- Read the complete task diff, kept production modules focused (12–90 lines each), retained cloud safe logging, restored existing cloud proxy/session behavior, and verified no old profile rewrite or dependency changes.
- Found and corrected body-stream capture, non-discriminating malformed oversized fixture, synthetic redirect result assumption and session lifetime cleanup. Both body-limit mutations now fail tests; no mutation remains in production.
- Test evidence is synthetic URLSession/URLProtocol and resolver/TLS challenge injection, not an installed server, live socket/TLS service, vendor account, microphone or signing check. Those manual/live checks remain Pending; no external upload or service install occurred.
- No outstanding correctness concern identified. Fresh controller review and A6 integration/full-suite gates remain scheduled.

## Commit

`d5867ad feat: add registered local ASR protocol adapters` — 16 explicit task files. Post-commit worktree clean.
