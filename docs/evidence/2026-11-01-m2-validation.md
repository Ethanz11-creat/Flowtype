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
