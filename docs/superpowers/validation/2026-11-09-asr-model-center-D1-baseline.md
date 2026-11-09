# ASR model center D1 — timer / CI baseline

Date: 2026-11-09. Implementation starts from `aacf49a` on the isolated `flowtype-local` worktree.

## Historical remote failure

[GitHub Actions run 41672136709](https://github.com/Ethanz11-creat/Flowtype/actions/runs/41672136709), source `288aa9a6d02ce966a05dbd3fe71a6e26f6a9ad21`, Sources tree `eeab631f159fc5ad0820e45fe03edaacbbb237b9`, clean, failed its code-full phase with `fullTestFailed` (exit 1). The code build and source checks passed. Self-test stdout reports **25,919 passed / 1 failed**; stderr names only `M5 actual health timer advances once per interval`.

The original assertion slept 110ms and required 2...4 ticks of a 30ms timer. It logged neither elapsed time nor actual tick count, so this evidence does not establish whether callback delivery, continuation scheduling, or timer ownership caused the count mismatch. The downloaded report, exact failure text, and SHA256 hashes of the source report / child stdout / child stderr are archived in [historical CI evidence](../../evidence/2026-11-09-asr-model-center/d1-historical-ci.json).

Instrumenting the old assertion locally produced a passing **58 / 0** run: 117.49ms / 3 ticks; after cancellation 188.44ms / 3 ticks. This local observation does not recreate or reclassify the historical failure.

## Regression and production behavior

`WindowManager` accepts a MainActor health scheduler. Production continues using `.main` `DispatchSourceTimer`, with the unchanged 5-second default interval, weak instance capture, single owned timer guard, UUID generation checks, and actual `windowHealthTicks`. Cancellation invalidates the generation, clears the handler, cancels the timer, and releases the owner token.

The manual scheduler proves one schedule after duplicate start, exactly one owning-window tick per explicit callback, one cancellation after duplicate stop, no tick from a captured cancelled callback, and no tick from an old generation after restart. A separate liveness test observes at least two callbacks from the actual production scheduler within a continuous-clock deadline of 2 seconds. Sleeping without ticks fails.

Independent mutation checks confirmed sensitivity: removing only the owner guard caused **64 passed / 6 failed**; removing only the generation guard caused **67 passed / 3 failed**. Both mutations were restored. Final focused tests passed **70 / 0**, with 2 actual callbacks observed at 70.93ms and no further tick after cancellation (141.00ms).

The existing artifact smoke contract remains unchanged: at least 6 seconds elapsed and both actual probe / window timers must advance. Missing callbacks still fail with `timerDeadline`; they do not become Skip.

## Local verification and remaining gates

The final sequential `swift build` and focused self-test passed. The first code-lane invocation passed code-build and code-full but failed source-end with `sourceChanged`: the baseline evidence document was created while the verification source snapshot was active. This is a workflow error, preserved in `build/verification/46AD161B-298D-469C-B634-025FAC270EC0/verify-report.json`. The source and current evidence were committed as `722e109b00a487073630fe1b2f745b49503d6967` before the stable-source rerun.

The stable rerun exited 0 with **all seven phases Pass** (source-start, platform-os, platform-arch, platform-swift, code-build, code-full, source-end), **25,932 passed / 0 failed**, and empty full-suite stderr. It binds the clean git SHA `722e109b00a487073630fe1b2f745b49503d6967` and Sources tree `6ef9813355c20da71c689bc0742cd325f06c257f`. The real timer produced 2 callbacks at 69.68ms and remained at 2 after cancellation (140.09ms). See [raw local code report](../../evidence/2026-11-09-asr-model-center/d1-local-code.json) and [identity / log hash summary](../../evidence/2026-11-09-asr-model-center/d1-local-code-summary.json). These evidence updates are a docs-only followup; they do not change the verified Sources tree.

D1 does not establish success for a newly pushed remote SHA. No push or publish was performed. The historical remote run remains failed; a future authorized push must be checked in D3. Existing 41-case manual results, artifact/release acceptance, actual model/vendor/service matrices, signing, notarization and distribution remain separate gates; Pending is not Pass.

All automation used isolated validation roots, synthetic configuration and injected effects. No user configuration, Keychain, models, permission prompts, microphone or clipboard were used. Large diagnostic logs remain in the ignored task workspace; only compact evidence and hashes are tracked.
