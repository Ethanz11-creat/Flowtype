# M2 validation evidence — 2026-11-01

## M2-A Task 3 source identity

- Base commit: `964b616af43987361e55f025d675fb4c695ad25a`.
- Validated `Sources/flowtype` tree SHA: `8c73e9b6e5c2a926e61a87c42ed04723d7747d50`. This Git tree identifies the exact Swift source used by the final sequential build/self-test; evidence/report prose does not change that source tree.
- Initial Task 3 commit: `c74daaf58dbbbc45e59946bdee8ea05a19111d2a`. Review-fix validation is against the subsequent commit titled `fix: persist recovered model imports and clear cancelled fallback`, containing this updated evidence file.

## Offline fixture verification

Final commands, executed sequentially in the existing `flowtype-local` worktree:

```sh
swift build
swift run FlowType --self-test
```

Logs: `.superpowers/sdd/2026-11-01-m2-a-model-recovery/logs/task-3-fix1-green-build.log` and `task-3-fix1-green-self-test.log`.

Fixture coverage includes capture-start lease retention across a replacement (all 3,207 samples reach the old provider; only the next capture uses the new provider), retained usable lease readiness after candidate failure, truthful 1.7B repository/command/source/destination, custom endpoint identity, offline folder import and invalid-folder retention, manual 0.6B override path clearing, deferred onboarding readiness, Apple-basic gating, terminal downloader ownership, terminal stalls, and future engine history labels. Existing coordinator retry, cancellation/draining, local-first bootstrap, and metadata fixtures also run in the full self-test. Final result: `swift build` exit 0 (26.95s); `swift run FlowType --self-test` exit 0, **1,559 passed, 0 failed**. The build retains the pre-existing `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning; no new warnings were introduced.

## Public metadata-only probe (controller)

Probe UTC: `2026-11-01T16:17:00Z`; compiled against base `964b616af43987361e55f025d675fb4c695ad25a` with the product `ModelMetadataPreflight`, `DownloadSource`, and error types. No model weights were downloaded. Log: `.superpowers/sdd/2026-11-01-m2-a-model-recovery/metadata-probe.log`.

| Source | Repository | Observed metadata result |
| --- | --- | --- |
| hf-mirror.com | aufklarer/Qwen3-ASR-0.6B-MLX-4bit | metadataInvalid, HTTP 308 |
| hf-mirror.com | aufklarer/Qwen3-ASR-1.7B-MLX-4bit | metadataInvalid, HTTP 308 |
| huggingface.co | aufklarer/Qwen3-ASR-0.6B-MLX-4bit | PASS, HTTP 200 after allowed same-origin relative redirects |
| huggingface.co | aufklarer/Qwen3-ASR-1.7B-MLX-4bit | PASS, HTTP 200 after allowed same-origin relative redirects |

This establishes metadata behavior only. It does not establish weight-download, model-load, GPU-inference, or GUI success. The standalone compiler's legacy `regionCode` deprecation came from its deployment target; the package targets macOS 15.

## Pending actual acceptance

V1–V5 remain **Pending**; offline fixtures do not replace them. Actual model download, switching download sources, choosing a real directory, model loading/inference, automatic downgrade, recording during a real replacement, recovery UI rendering/copying/actions, and onboarding GUI cases were not run by the worker. GUI verification belongs to the controller and must use CUA. No user configuration, keys, audio, or models were used as fixtures, and no existing models or caches were removed.

## Task 3 review fix round 1

Both Important findings were reproduced through the actual shared UI action/coordinator path before fixes: RED sequential build passed; self-test reported 1,553 passed and 6 failed. Four failures covered successful folder B retry leaving folder A/legacy/preset configuration and restart selection unchanged; two covered cancelling an automatic fallback while retaining an old 0.6B lease and falsely displaying “已退回 0.6B”. Logs: `logs/task-3-fix1-red-build.log` and `logs/task-3-fix1-red-self-test.log` in the SDD evidence directory.

Both folder pickers and card Retry now call ModelRecoveryActions. Offline retry uses the same verified import and successful ConfigurationStore.save action as initial import; failed/cancelled retries preserve folder A and its available lease. Cancellation clears the attempted fallback flag, so retaining an old 0.6B lease cannot imply a successful downgrade. The regression uses an isolated real ConfigurationStore and checks a re-created store after saving, with only model I/O replaced. GREEN result: sequential build exit 0; self-test exit 0, 1,559 passed and zero failed. No actual GUI/model cases or V1–V5 were promoted from Pending.

## M2-B Task 3 — cloud setup and revision-owned checks

- Base commit: `042706e9ad698688ee8d493db9388c6e3a33d061`.
- Validated `Sources/flowtype` tree SHA: `92ab669df4373da9113a83c29b1f7ee91482715d`. The evidence/report prose does not change this source tree.
- Final sequential commands: `swift build` exit **0** (29.61s), then `swift run FlowType --self-test` exit **0**, **1,957 passed, 0 failed** (product build 4.57s).
- Logs: `.superpowers/sdd/2026-11-01-m2-b-cloud-providers/task-3-build.log`, `task-3-green.log`; full worker report: `task-3-report.md` in the same directory.

The new fixtures exercise the actual settings action/tracker and actual `CloudASRProvider`, with only HTTP transport replaced by an ephemeral URLProtocol fixture. They cover per-profile revision ownership; URL/model/Key/name/vendor/protocol/activation/all custom-field edits; deletion and shifted UUID bindings; late success/failure and cancellation; duplicate clicks while an obsolete request remains in flight; synchronous click ownership before queued work starts; zero upload when an edit precedes queued work; pure configuration checks with zero HTTP calls; honest WSS local-only state; rejection of invalid endpoint/blank model/blank Key by readiness; and immutable recording URL/model/Key after UI edits. These fixtures use synthetic hosts, credentials and samples, not real user configuration or audio.

TDD RED first established the missing tracker API. Self-review then reproduced a separate queued-click race through the real async action: **1,954 passed, 1 failed**, with an edited profile incorrectly marked connected. The synchronous shared button action now reserves revision/busy ownership before queuing transport. Final regression coverage is included in the GREEN result above. Only the pre-existing `AppLogger.swift:27` warning remains.

**GUI Pending:** vendor selection/defaults, URL editing, advanced fields and zero-network configuration checks await controller CUA on the newly built revision. The worker did not use GUI automation; the already running old PID 10836 is not evidence for this source revision.

**V1 Pending:** actual SiliconFlow and OpenAI model/field acceptance, each under normal network, weak network, offline and cancellation conditions. No authorized live configuration was used, no paid vendor request was made, and fixture success does not establish live support. Actual WSS handshake/recognition also remains Pending; the settings check explicitly performs local validation only, with real connection verification at recording. Existing V2–V5 Pending status is unchanged.
