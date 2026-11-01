# C1 implementation report

Status: DONE. Scoped commit `9e5dc57`.

## Implemented

- Added `LocalASREngine` and `ImportedASRModel` value descriptors, backward-compatible configuration decoding/encoding of the imported library and active UUID.
- Added pure `LocalModelLibrary.upserting/removing` configuration transformations. Inspection/upsert never activate or persist selection. Rescanning a canonical model path preserves UUID. Removing the active record clears stale legacy selection aliases, but never reads/writes/deletes weight files or invalidates a live lease.
- Added staged `inspectLegacyCandidate` APIs; invalid explicit paths throw rather than falling through to another cache. C3 owns actual success-only migration persistence.
- Added strict, local-only `ASRModelInspector` with separate Qwen MLX and Whisper Core ML paths. Legacy scanner/locator APIs remain available for C3 integration. Existing preset identity matching remains separate from imported compatibility identity.
- Qwen supports 0.6B/1.7B, affine/minmax 4/8-bit group64 with full required tensor inventory. The inventory was derived from speech-swift 0.0.15 `Qwen3AudioEncoder`, `QuantizedTextDecoder`, `WeightLoading`, `CommonWeightLoader`, and tokenizer/generation code, not the obsolete generic `AudioEncoderConfig.small` defaults. It checks all 18/24 audio layers and 28 text layers, every norm/bias/projection, NHWC convolution shapes, packed U32 weights and float scales/biases; extra unsupported tensors are rejected. The known converter may additionally export one floating `lm_head.weight` of exact `[151936, hidden_size]`; it is permitted only under the same tied-embedding contract. The actual runtime ignores this head and computes logits through quantized `embedTokens.asLinear`; no payload equality between head and embeddings is claimed. Untied configurations, wrong head shape/type and arbitrary extra tensors are rejected.
- Supports original HF `thinker_config` plus `quantization`, and the compatible converter schema `audio_encoder`/`text_decoder`/`quantization_config(minmax)` after the controller's separate real 1.7B static probe revealed that schema. Synthetic tests independently construct both schemas. Size labels, duplicate quantization descriptions, dimension conflicts, RoPE/norm constants and numeric types are checked.
- Qwen requires bounded readable vocab/config/merges and the exact IDs for every hardcoded generation token, including `<asr_text>`, newline and role tokens. Added-token overrides cannot conflict with the base vocabulary.
- Safetensors metadata/config/index reads are bounded at 16 MiB each. The reader never reads weight payloads. It checks JSON duplicate keys, shape-byte multiplication overflow, offsets, contiguous non-overlapping payload ranges, truncation, LFS pointers, missing shards, duplicate tensors, exact index coverage/mapping and declared total payload size. Direct-child index paths cannot escape; ordinary HF blob file symlinks are accepted and broken/replaced links rejected.
- Fingerprints combine metadata/header SHA-256 with resolved paths, size, inode/device and timestamps. Files are rechecked for identity changes during inspection. This is a stale-descriptor guard, not a full cryptographic payload checksum.
- Whisper validates required MelSpectrogram/AudioEncoder/TextDecoder and optional TextDecoderContextPrefill packages independently of safetensors. Compiled ML Program layouts require coremldata.bin/model.mil and readable referenced model-path resources. Source packages require a valid manifest, root model and declared resources. Local tokenizer.json/tokenizer_config.json are required in the selected directory or unique `tokenizer` child. Repo roots containing variants return chooseSubdirectory, even when root config.json exists.
- Whisper descriptors deliberately use variant `unverified`; no MLX/Core ML model was loaded in C1. Static package checks do not establish graph inputs/outputs, vocabulary compatibility, supported runtime variant or inference correctness.

## TDD evidence

All logs below are in `.superpowers/sdd/2026-11-01-m2-c-hf-import/`.

1. Initial RED: `swift build > task-1-red.log 2>&1`, exit 1. Expected missing `ASRModelInspector`, `ImportedASRModel`, library/config interfaces before implementation.
2. First GREEN: sequential `swift build` then `swift run FlowType --self-test`, exits 0; build 38.25s; 2078 passed, 0 failed. Later files were amended for self-review regressions, so final log paths will contain the final validation.
3. Token RED: `swift build > task-1-token-red-build.log 2>&1` exit 0; `swift run FlowType --self-test > task-1-token-red.log 2>&1` exit 1, 2086 passed/2 failed: missing ASR text token and wrong prompt role ID were incorrectly accepted. Fixed by checking the actual hardcoded generation token IDs.
4. Index/root RED: `swift run FlowType --self-test > task-1-index-red.log 2>&1` exit 1, 2089 passed/2 failed: wrong index total_size accepted; root with variant directories plus config returned unsupportedFormat instead of chooseSubdirectory. Both fixed.
5. Converted-schema RED: `swift run FlowType --self-test > task-1-converted-red.log 2>&1` exit 1, 2039 passed/1 failed: independent synthetic converter-schema fixture rejected as unsupportedFormat. Added the explicit supported schema mapping, retaining the same tensor/token checks.
6. Metadata consistency RED: `swift run FlowType --self-test > task-1-consistency-red.log 2>&1` exit 1, 2103 passed/2 failed: conflicting duplicate quantization metadata and a string RoPE value accepted. Both fixed with explicit consistency/type validation.

7. Optional-head RED: `swift run FlowType --self-test > task-1-head-red.log 2>&1` exit 1, 2039 passed/1 failed: synthetic compatible converter export with a correctly shaped floating output head was rejected as an extra tensor. Added only the documented optional head under the runtime’s tied-embedding contract; malformed/untied/unknown extras stay rejected.

Final GREEN (sequential, after all implementation changes and actual static probe3):

- `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-1-build.log 2>&1` — exit 0, `Build complete! (30.40s)`.
- `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-1-self-test.log 2>&1` — exit 0, `=== self-test: 2109 passed, 0 failed ===` (75 additional passing checks above baseline 2034).
- `git diff --cached --check` — exit 0, no output before commit.
- Final owned fixture-directory check: 0 remaining `flowtype-import-*` directories.

No `swift test` or unchanged repeat suite/probe was run.

Fixtures are isolated under random system temporary directories and removed with defer. Sparse files contain small synthetic headers and logical payload lengths, with no allocated/loaded model tensors. The suite covers both scales × both bit widths × both metadata schemas, folder renames, complete sharded indexes, metadata fingerprint changes, missing/invalid/full inventory cases, bounded metadata, malformed offsets, legal HF links and broken links, compiled/source Core ML static packages and traversal, explicit legacy staging, config round trips, deduplication, non-activation and record-only removal. A blocking Foundation URLProtocol probe observes zero URL-loading requests during inspection.

## Files

New:
- Sources/flowtype/Services/Speech/LocalModelManager/ImportedASRModel.swift
- Sources/flowtype/Services/Speech/LocalModelManager/LocalModelLibrary.swift
- Sources/flowtype/Services/Speech/LocalModelManager/ASRModelInspector.swift
- Sources/flowtype/Services/Speech/LocalModelManager/SafetensorsManifest.swift
- Sources/flowtype/Services/Speech/LocalModelManager/WhisperModelInspector.swift
- Sources/flowtype/Testing/LocalModelImportSelfTests.swift

Changed:
- Sources/flowtype/Core/Configuration.swift
- Sources/flowtype/Services/Speech/LocalModelManager/CustomModelScanner.swift
- Sources/flowtype/Services/Speech/ModelLocator.swift
- Sources/flowtype/Testing/SelfTest.swift (registration only)

## C2/C3/C4 handoff

- `ASRModelInspector.inspect(directory:) throws -> ImportedASRModel` is a synchronous local metadata inspection. Use it off the UI thread. `ASRModelInspectionError.code` distinguishes unsupported/incomplete/invalid metadata, invalid tensor/index, changed file, unreadable, oversized metadata and chooseSubdirectory.
- `ImportedASRModel.qwenCompatibilityModelID` is `local/Qwen3-ASR-{0.6B|1.7B}-MLX-{4|8}bit`, for the dependency constructor's size/bit selection only. Never use it to fetch anything. Always pass descriptor.directory explicitly with offline mode.
- Before loading, reinspect descriptor.directory and compare fileFingerprint/engine/variant/bits. Preserve the library's UUID, and do not interpret any descriptor as a loaded runtime.
- Whisper C2 must determine variant from the actual loaded Core ML graph, validate dimensions/inputs/outputs and special-token/vocabulary compatibility, and load tokenizerDirectory explicitly. C1 sets variant `unverified` and provides no ready state.
- `LocalModelLibrary.upserting(_:in:)` returns a value and preserves an existing canonical path's UUID; it never selects/loads/saves. Set `activeImportedASRModelID` and persist the library only inside the successful, current owned-load transaction in C3.
- `LocalModelLibrary.inspectLegacyCandidate(in:)` / `ModelLocator.inspectLegacyCandidate(config:)` inspect the first explicit custom/legacy path and throw on failure; no caches/downloads/persistence. C3 must decide when to stage/commit migration after successful runtime loading.
- `CustomModelScanner.inspectModelDirectory(_:)` is the new strict multi-format API. The old size-based scanner/locator APIs remain for integration compatibility; do not use them to authorize newly imported candidates.
- `LocalModelLibrary.removing(id:from:)` removes only records and stale selection aliases. It must not unload/invalidate an already captured provider lease or delete files. Active record removal clears legacy selectedLocalModelID/customLocalModelPath/localModelPath to prevent resurrection.

## Self-review / limits

- Self-review found and fixed missing hardcoded ASR text/role token validation, index metadata total-size consistency, multi-variant roots containing config.json, dual quantization conflicts, numeric metadata type checking, and canonical root fingerprint stability.
- Controller separately compiled the exact current four inspector/descriptor source files for macOS 15 and exercised the existing working 1.7B directory read-only. Initial probe exposed converter schema; second probe exposed the known optional ignored output-head export. Third probe PASS at UTC 2026-11-01T18:23:17Z (`actual-17-static-probe-3.log`): engine=qwenMLX, variant=1.7B, bits=4, sizeBytes=2225411512, fingerprint=135f5b023e282e0c860d7b10a893487c5274dd012af5a203293d353eed3b1f22. This is separate real static acceptance, not a test fixture or runtime/inference proof. It read local metadata/headers/tokenizer only and did not modify/load weights, use GPU, infer speech or make network requests.
- No real user model/config/credential served as a fixture; no downloads, package changes, build-app, app relaunch, GUI control, push/merge or file deletion outside owned temporary fixtures occurred.
- Existing build warnings are unrelated (`AppLogger` unnecessary nonisolated(unsafe); initial broader rebuild also reported AppleSpeechProvider unused withLock return). No new warning is intentionally introduced.
- Real 0.6B/8-bit and Whisper runtime/inference remain unverified. C2/C3 success-only loading and C4 presentation are subsequent tasks.

Commit: `9e5dc57` — `feat: inspect local ASR formats and persist imported model library` (10 scoped source files, 806 insertions/1 deletion). Report/logs remain in the ignored SDD workspace for controller review; no unrelated files committed.

## Review fix round 1 — immutable first observation

Status: DONE. Commit `a36df21` — `fix: preserve first model file inspection identity` (base `9e5dc57`, two scoped source files).

Addressed the Important finding from `task-1-review.md`: `LocalInspectionFiles.record` previously replaced an earlier recorded identity with a later one. Whisper's parsed MIL/manifest metadata could therefore remain associated with its old content hash while a later package walk overwrote the identity, allowing final verification to pass after a file replacement.

The helper now compares every repeated observation against the first identity before any record/hash mutation, throws `changedDuringInspection` for a mismatch, and only inserts an identity when that path has not been observed. An unchanged repeated record remains valid. The first fingerprint and final verification baseline remain intact after rejecting a replacement.

Added a deterministic test using the real helper and real temporary files: read model.mil, record it again unchanged, replace it with a separately created file of different length, capture the replacement's actual identity, then attempt to record it. The test checks rejection, unchanged first fingerprint, and final verification still rejecting the replacement. No timing sleeps, GPU/model loading, or mocked identity implementation is used.

RED:
- `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-1-fix1-red.log 2>&1` — exit 1, 2110 passed/3 failed.
- Expected failures: replacement was accepted; first fingerprint was overwritten; final verification no longer compared against the first observation. The unchanged repeated-record check already passed.

Final GREEN, sequential after the fix:
- `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-1-fix1-build.log 2>&1` — exit 0, `Build complete! (23.86s)`.
- `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/task-1-fix1-self-test.log 2>&1` — exit 0, `=== self-test: 2113 passed, 0 failed ===`.
- `git diff --cached --check` — exit 0 before commit. No additional unchanged suite was run.

Changed files:
- `Sources/flowtype/Services/Speech/LocalModelManager/SafetensorsManifest.swift`
- `Sources/flowtype/Testing/LocalModelImportSelfTests.swift`

Self-review: the identity comparison occurs before mutating either record or hash state, checks both the first observation and current file identity, and preserves existing API/error codes. No other review items were included; the minor `__metadata__` shape finding remains deferred to whole-M2 triage as directed. The actual 1.7B PASS probe3 above predates this fix; no new actual-directory, runtime, inference or GUI acceptance is claimed in this round.
