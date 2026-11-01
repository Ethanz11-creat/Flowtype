# M2-B staged review fix report

Base: `2d3b99e`. Scope: exactly the two Important findings in `stage-review.md`.

## Implementation

1. Realtime capture boundary: `isValidRealtimeEndpoint`, used by the actual `RealtimeASRConfiguration` constructor and WebSocket transport, now delegates to `CloudASREndpoint.validateRealtimeURL`. Its existing rejection of raw whitespace remains before that call, so settings and runtime share the strict WSS contract without silently trimming saved URLs. Queries (including empty queries), userinfo, fragments, malformed/empty/out-of-range/overflowing explicit ports, placeholders and encoded whitespace are rejected before the session factory receives configuration. Diagnostics describe these constraints without printing the supplied URL. Valid IPv6, explicit ports and percent-encoded path separators remain accepted and intact.
2. Advanced model selection: restored a `模型预设` picker alongside the editable model ID. The read-only vendor/protocol catalog offers SiliconFlow SenseVoiceSmall and TeleSpeechASR, OpenAI whisper-1, or DashScope Paraformer for the matching protocol; custom services or mismatched protocols get no misleading presets. An existing unlisted model has its own current-selection tag and is not overwritten while rendering. Both the picker and model text field use the shared UUID-based `selectModel` action, which changes only the model and delegates invalidation to existing `updateProfile`. No migration/default application was added.

No changes to capture bytes, ASR routing, health recovery, cancellation, immutable recording snapshots, delivery, Apple authorization or LLM configuration. The credential-only health-reset follow-up explicitly deferred in `progress.md` remains outside this fix.

## TDD evidence

The repository exposes a single self-test runner, so behavior checks use that runner rather than an invented test filter. All added fixtures are in memory with synthetic credentials and URLs; only session/HTTP transport boundaries use the existing fakes.

### RED: actual runtime boundary

Command: `swift run FlowType --self-test > /tmp/m2b-stage-wss-red.log 2>&1` (exit 1).

Stable copied log: `stage-fix-wss-red.log`.

Relevant output:

```text
FAIL: capture endpoint: constructor rejects wss://capture.invalid/ws?token=synthetic-secret
FAIL: capture endpoint: constructor rejects wss://capture.invalid:999999999999999999999/ws
FAIL: capture endpoint: constructor rejects wss://[::1]:999999999999999999999/ws
FAIL: capture endpoint: invalid URLs never reach capture or retry session factory — got 6, want 0
FAIL: capture endpoint: invalid URLs never start a session — got 6, want 0
=== self-test: 1992 passed, 26 failed ===
```

These failures reproduced the constructor bypass and actual capture/session-start side effects. The tests also execute `ASRStage` after capture rejection to exercise saved-audio retry validation and verify complete `[0.25, -0.5]` fallback audio. Credential, fragment, invalid port and raw whitespace cases that already passed stay covered as regressions, as do valid IPv6/escaped paths.

### RED: model catalog and shared selection action

First command: `swift build > /tmp/m2b-stage-model-red.log 2>&1` (exit 1). Stable log: `stage-fix-model-api-red.log`. Expected API-first errors: `CloudASRVendor` had no `modelPresets`; `CloudASRConnectionCheck` had no `selectModel`. This compile failure alone was not treated as behavioral proof.

Added temporary empty catalog/no-op action implementations, then ran `swift run FlowType --self-test > /tmp/m2b-stage-behavior-red.log 2>&1` (exit 1). Stable log: `stage-fix-behavior-red.log`.

```text
FAIL: model selection: presets belong to selected vendor — got [], want ["FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR"]
FAIL: model selection: shared picker action selects TeleSpeechASR — got user/custom-asr, want TeleAI/TeleSpeechASR
FAIL: model selection: preset selection invalidates prior connection result
FAIL: model selection: shared action accepts custom IDs — got user/custom-asr, want my/new-custom-model
=== self-test: 2001 passed, 33 failed ===
```

Seven additional behavioral failures demonstrated missing catalog/action behavior. Replaced the temporary scaffolds with the final implementation. Coverage checks vendor/protocol choices, migrated custom model retention, TeleSpeech selection, UUID/URL/key/other-profile preservation, custom input, unchanged-model revision preservation, and stale deleted-profile no-op behavior. Tests call the actual catalog/action used by UI; they do not mirror view layout or inspect source strings.

## Final validation

Final commands executed sequentially:

1. `swift build > .superpowers/sdd/2026-11-01-m2-b-cloud-providers/stage-fix-build.log 2>&1` — exit 0, `Build complete! (30.47s)`.
2. `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-b-cloud-providers/stage-fix-green.log 2>&1` — exit 0, `Build of product 'FlowType' complete! (4.62s)` and `=== self-test: 2034 passed, 0 failed ===`.

`git diff --check` passed. Build output retains the inherited `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning; no new warning was introduced. No `swift test`, unchanged-source repeat suite, release rebuild, GUI launch, paid request, real configuration/key/model fixture read, push, merge or cache deletion was performed.

## Files changed

- `Sources/flowtype/Services/Speech/RealtimeASR.swift`
- `Sources/flowtype/Services/Speech/CloudProviders/CloudASRVendor.swift`
- `Sources/flowtype/Settings/CloudASRConnectionCheck.swift`
- `Sources/flowtype/Settings/CloudASRProviderList.swift`
- `Sources/flowtype/Testing/CloudProviderSelfTests.swift`
- `Sources/flowtype/Testing/SelfTest.swift`

This report and its five logs remain in the existing ignored SDD directory.

## Self-review and concerns

Read the complete production/test diff. Confirmed validation has no recursion; the constructor and retry use the stricter helper before factory creation; no captured values are rewritten. Confirmed model catalog lookup cannot write configuration, custom picker tags remain representable, and shared selection resolves the current profile by UUID and preserves all other fields. Every new catalog/action behavior has coverage that fails under empty/no-op mutations. The existing large `SelfTest.swift` was extended only beside its realtime pipeline integration fixtures, without restructuring.

No unresolved implementation concerns. Actual GUI rendering/interaction, live WSS handshake/recognition, SiliconFlow/OpenAI account/model/field support and V1–V5 acceptance remain **Pending** under the controller's mainline acceptance process. Local fixtures do not establish online vendor support. The controller's existing `2d3b99e` release bundle has not been rebuilt or launched by this worker.

## Commit

`6fc1973` — `fix: enforce realtime endpoints and restore ASR presets`.

Exactly the six source/test files listed above were staged. Cached diff whitespace check passed. Final source validation preceded the commit; no unchanged test rerun was performed.
