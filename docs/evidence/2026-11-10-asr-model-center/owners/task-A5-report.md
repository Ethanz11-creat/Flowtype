# A5 implementer report

Status: DONE. Base: d2f8d87. No full-suite claim; A6 owns the full suite/release gates.

## Implementation

- Added explicit local-service/cloud OpenAI-style discovery. Discovery does not invoke recognition or own any recognition/verification state. IDs are candidates, including text/TTS IDs; duplicates preserve first order. Model selection is not required before discovery. GET /models derives from the already validated transcription endpoint, preserving proxy prefixes.
- Local discovery uses strict loopback URL validation, numeric pinned destinations, original Host/TLS identity and the existing deny-all-redirect task policy. Cloud discovery retains HTTPS-only validation. No credential-store/configuration-store reads.
- Production discovery has 10-second request and resource budgets plus the per-request 10-second timeout. Streaming reads enforce 1 MiB before decoding; at most 1000 returned items are accepted before deduplication. Oversize lists fail explicitly and support manual entry. HTTP 404/405 return an empty candidate list; auth/other HTTP failures remain errors with no response body retained. whisper.cpp discovery returns no candidates without probing /models or /load.
- Added an application-owned ObservableObject validation coordinator for service and cloud profiles. Only explicit test calls send supplied ASRValidationSample PCM, with nil language/context and sendContext=false. No microphone, frontmost text, dictionary, clipboard or automatic probes.
- Configuration checks remain separate from recognition evidence. The DashScope test overload only checks configuration and never emits verified/record evidence. OpenAI-compatible cloud/service recognition requires a nonempty final transcript. Failure state contains stable codes, never arbitrary server/error descriptions.
- Ownership hashes full encoded profiles (all wire fields and revision) plus random credential-generation identity; no credential digest. Each profile has an independent owner token and child task. Invalidate immediately clears commit authority/state, requests cancellation and retains the slot until the producer drains. Changed profile/generation while testing also clears state/cancels without starting overlapping work. Caller cancellation suppresses late success. A stale completion releases only its own slot.
- Added ASRServiceValidationRecord: backendID, revision, credentialGeneration, validatedAt; no text/key/URL. The injected onVerified callback runs only for current owned nonempty real recognition. Transcription stays transient in ASRServiceValidationState. Persistence wiring belongs to C1/C4, as explicitly directed by the controller.
- Existing CloudASRConnectionCheck now retains its tasks, requests cancellation on invalidation, suppresses cancelled queued uploads/late publication, and keeps transport ownership until drain. Existing draft/settings/connection ownership regressions remain included in the focused runner.

## Exact API handoff for C1

```
ASRModelDiscoveryClient(session: URLSession? = nil,
                        resolver: LocalASRServiceEndpoint.Resolver = ...)
models(profile: LocalASRServiceProfile, credential: String?) async throws -> [String]
models(cloudProfile: CloudASRProviderConfig, apiKey: String) async throws -> [String]

@MainActor ASRServiceValidationCoordinator: ObservableObject
init(session: URLSession? = nil,
     resolver: LocalASRServiceEndpoint.Resolver = ...,
     onVerified: @MainActor (ASRServiceValidationRecord) -> Void = { _ in },
     serviceRecognition: ServiceRecognition? = nil,
     cloudRecognition: CloudRecognition? = nil)
state(profileID: UUID) -> ASRServiceValidationState
isTesting(profileID: UUID) -> Bool
invalidate(profileID: UUID)
checkConfiguration(profile: LocalASRServiceProfile, credential: String?,
                   credentialGeneration: UUID? = nil)
checkConfiguration(cloudProfile: CloudASRProviderConfig, apiKey: String,
                   credentialGeneration: UUID? = nil)
test(profile: LocalASRServiceProfile, credential: String?, sample: ASRValidationSample,
     credentialGeneration: UUID? = nil) async
test(cloudProfile: CloudASRProviderConfig, apiKey: String, sample: ASRValidationSample,
     credentialGeneration: UUID? = nil) async

enum ASRServiceValidationState: Equatable, Sendable {
    case idle, configurationValid, testing
    case verified(at: Date, text: String)
    case failed(code: String)
}
struct ASRServiceValidationRecord: Codable, Equatable, Sendable {
    let backendID: ASRBackendID
    let revision: UUID
    let credentialGeneration: UUID?
    let validatedAt: Date
}
```

Production C1 must pass generation from the same atomic credential snapshot as the supplied key. The default nil preserves the requested exact call form and uses in-memory equality/random-generation fallback only for manual/injected callers; it never hashes/logs/persists keys. Records retain the supplied optional generation (nil if absent), rather than inventing a persistent generation. C1 owns discovery list revision guards, invokes invalidate on edit/delete/close, disables another test while isTesting remains true, and persists only the record through onVerified. After restart this is historical evidence, never current readiness. Presentation owns the >60-second “last verified” wording and vendor-cost disclosure. No full model-center wiring was added.

Stable failure codes: auth, invalidModel, uploadTooLarge, rateLimit, http, timeout, invalidURL, invalidResponse, unsupportedProtocol, audioEncoding, unavailable, cancelled, network. Cancellation of a test publishes idle rather than failed(cancelled). Discovery limits are ASRModelDiscoveryError.responseTooLarge / tooManyModels with safe localized manual-entry guidance; other discovery failures use CloudASRError.

## TDD evidence: initial discovery/validation behavior

Tests were written first in ASRBackendValidationSelfTests, with only executable API scaffolds (discovery=[], coordinator=idle/no-op) to observe behavioral failures rather than compiler errors.

Command:
```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A5-red-build.log 2>&1
```
Exit 0, `Build complete! (30.61s)`.

Command:
```
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A5-red-backends.log 2>&1
```
Exit 1, exact relevant output:
```
  ✗ FAIL: discovery: candidates retain order without claiming ASR compatibility — got [], want ["tts-model", "text-model"]
  ✗ FAIL: discovery: one explicit list request — got 0, want 1
  ✗ FAIL: discovery: never uploads recognition audio — got nil, want Optional("GET")
  ✗ FAIL: discovery: normalized models endpoint — got nil, want Optional("/v1/models")
  ✗ FAIL: discovery: pinned loopback destination — got nil, want Optional("127.0.0.1")
  ✗ FAIL: discovery: configured authority preserved — got nil, want Optional("localhost:8123")
  ✗ FAIL: discovery: ten second request budget — got nil, want Optional(10.0)
  ✗ FAIL: discovery: auth/HTTP error is not an empty successful list
  ✗ FAIL: discovery: auth/HTTP error is not an empty successful list
  ✗ FAIL: discovery: auth/HTTP error is not an empty successful list
  ✗ FAIL: discovery: auth/HTTP error is not an empty successful list
  ✗ FAIL: discovery: auth/HTTP error is not an empty successful list
  ✗ FAIL: discovery: exact item cap accepts then deduplicates — got [], want ["candidate"]
  ✗ FAIL: discovery: malformed/oversize list rejected without truncation
  ✗ FAIL: discovery: malformed/oversize list rejected without truncation
  ✗ FAIL: discovery: malformed/oversize list rejected without truncation
  ✗ FAIL: discovery: malformed/oversize list rejected without truncation
  ✗ FAIL: discovery: malformed/oversize list rejected without truncation
  ✗ FAIL: discovery: exact 1MiB accepted — got [], want ["x"]
  ✗ FAIL: discovery: timeout cannot succeed
  ✗ FAIL: discovery: external DNS refused
  ✗ FAIL: discovery: cloud list before model selection — got [], want ["cloud-model"]
  ✗ FAIL: discovery: full transcription path normalized — got nil, want Optional("/proxy/v1/models")
  ✗ FAIL: discovery: captured cloud credential — got nil, want Optional("Bearer fixture-only")
  ✗ FAIL: discovery: cloud HTTP rejected
  ✗ FAIL: validation: user action owns testing state — got idle, want testing
  ✗ FAIL: validation: double-click sends once — got 0, want 1
  ✗ FAIL: validation: cancelled transport retains drain slot
  ✗ FAIL: validation: edited owner cannot overlap draining request — got 0, want 1
  ✗ FAIL: validation: fresh call captures edited model — got nil, want Optional("edited-model")
  ✗ FAIL: validation: fresh call captures edited credential — got nil, want Optional("fixture-B")
  ✗ FAIL: validation: supplied sample captured — got nil, want Optional("4d5bc6295487a269f3b40912e5c8f838aa810911854875b1c14ef8fc6919f0a7")
  ✗ FAIL: validation: fresh recognition verified
  ✗ FAIL: validation: configuration check is not recognition — got idle, want configurationValid
  ✗ FAIL: validation: cloud explicit recognition verified
  ✗ FAIL: validation: DashScope configuration cannot become recognition evidence — got idle, want configurationValid
  ✗ FAIL: validation: safe stable failure code — got idle, want failed(code: "auth")
  ✗ FAIL: validation: empty recognition never verifies — got idle, want failed(code: "invalidResponse")
=== ASR backend self-test: 887 passed, 38 failed ===
```
These failures were expected because the scaffold never discovered candidates, classified HTTP/limits, owned recognition, or published verified states.

Initial GREEN:
```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A5-green-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A5-green-backends.log 2>&1
```
Sequential commands, each exit 0. Build: `Build complete! (30.06s)`. Focused result: `=== ASR backend self-test: 925 passed, 0 failed ===`.

Self-review then capped production discovery resource timeout (not only resetting request timeout), checked cancellation before interpreting a discovery response, and suppressed a cancelled queued legacy connection check. A sequential build succeeded (`A5-final-build.log`, exit 0, `Build complete! (30.82s)`). These changes are included in the final focused GREEN below.

## TDD evidence: explicit historical record handoff

Controller requested the minimal persistable record contract after initial GREEN, leaving storage wiring to C1/C4. Added the record type/callback signature and tests before callback behavior.

```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A5-record-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A5-record-red-backends.log 2>&1
```
Sequential build exit 0 (`Build complete! (33.41s)`); runner exit 1, exact relevant output:
```
  ✗ FAIL: validation: current recognition emits one record — got 0, want 1
  ✗ FAIL: validation: record uses stable backend identity — got nil, want Optional("service:3A0995F8-85AF-4283-913F-FE98357ED82C")
  ✗ FAIL: validation: record binds captured revision — got nil, want Optional(9BD7845B-D228-4E1D-802C-C71EB1240C36)
  ✗ FAIL: validation: record binds atomic credential generation — got nil, want Optional(699D946D-9197-4264-95D8-E9E93B125B99)
  ✗ FAIL: validation: edited/generation/cancelled completions emit no record — got 0, want 1
  ✗ FAIL: validation: cloud recognition emits record — got 0, want 1
  ✗ FAIL: validation: cloud record stable identity — got nil, want Optional("cloud:8DB2070B-9448-4057-BA24-10BCDEBD6CF4")
  ✗ FAIL: validation: DashScope configuration check emits no record — got 0, want 1
=== ASR backend self-test: 927 passed, 8 failed ===
```
Expected because the callback signature existed but no current owned recognition emitted a record yet. The serialization assertions run after successful emission and are included in final GREEN.

Final GREEN commands:
```
swift build > .superpowers/sdd/2026-11-09-asr-model-center/A5-record-green-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-backends-only > .superpowers/sdd/2026-11-09-asr-model-center/A5-record-green-backends.log 2>&1
git diff --check
```
Executed sequentially. Build exit 0: `Build complete! (41.37s)`; build log contains no warning/error diagnostics. Focused runner exit 0:
```
=== ASR backend self-test: 937 passed, 0 failed ===
```
Whitespace check exit 0, no output. No source edits after this final GREEN sequence.

## Coverage and self-review

Focused tests exercise candidate vs recognition distinction; no-body GET and pinned authority; missing-list manual fallback vs auth/status failure; malformed/oversize and exact byte/item boundaries; timeout classification; DNS refusal before credential send; cloud full-path normalization/HTTPS; whisper.cpp no probes; idle/configurationValid/testing/verified/failed distinction; double-click reservation; edit/delete/close invalidation semantics through the shared invalidate API; drain ownership; captured edited model/key/sample; changed wire/generation ownership; caller cancellation; safe auth code; empty transcript rejection; current-only cloud/service records; encoded records exclude transcript/key/URL and round-trip date/identity. The combined backend runner also executes prior A1–A4 transport/routing/credentials/draft/settings/connection-ownership tests.

Reviewed full new discovery/coordinator source and legacy diff: strict endpoint separation, no credential hash, all wire fields in hash, independent transport ownership, bounded streaming response and real recognition-only callback. No additional feature waves after the requested record handoff.

## Files changed

- Sources/flowtype/Services/Speech/Backends/ASRModelDiscoveryClient.swift (new)
- Sources/flowtype/Services/Speech/Backends/ASRServiceValidationCoordinator.swift (new)
- Sources/flowtype/Settings/CloudASRConnectionCheck.swift
- Sources/flowtype/Testing/ASRBackendValidationSelfTests.swift (new)
- Sources/flowtype/Testing/ASRBackendSelfTests.swift

## Limits / remaining planned work

C1/C4 must wire app ownership, atomic credential snapshots, record persistence, historical presentation, samples/cost disclosure, and model-list completion revision guards. A6 owns full-suite/final gates. Actual cloud/service/live microphone/signing/release/manual checks were not performed and are not claimed Pass. All automated audio is synthetic, HTTP uses injected URLProtocol, and recognition ownership uses injected cancellation-resistant continuations. No real keys, real uploads, real user state, child agents, push/merge/release, dependency edits or Package.resolved changes.

## Commit

`009ba44 feat: discover and validate ASR service models explicitly` (five explicit source/test files, 539 insertions, two deletions). Cached whitespace check passed before commit. Final `git status --short`: clean. Report/logs remain in the ignored task workspace.
