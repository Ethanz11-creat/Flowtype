# C2 — Strict offline Whisper Core ML runtime

Base: `a36df21`. Implementation follows task-2-brief and controller dependency/metadata rulings. No upstream source edits, model downloads, Python, GUI launch, real configuration or credentials, or cache deletion.

## Implementation / C3 handoff

- `LocalASRRuntimeFactory.load(_:) async throws -> LocalASRLease` reinspects the selected directory and compares its fingerprint, engine, tokenizer directory and Qwen compatibility identity before runtime creation. Qwen uses only `local/Qwen3-ASR-{variant}-MLX-{bits}bit`, explicit selected directory, `offlineMode: true`; lease identity retains the imported name/path, never the synthetic constructor ID.
- `WhisperASRProvider.load(model:backendFactory:)` has a default real backend and an injectable `@Sendable (WhisperOfflineLoadOptions) async throws -> any OfflineWhisperBackend`. `WhisperOfflineLoadOptions` fixes `download=false`, `load=false`; both local folders are explicit. Provider routes through `ASRProviderID.local`; on-device / no-network capabilities; English-only graph disables language-hint capability. Prompt hints supported.
- `OfflineWhisperKit` overrides tokenizer loading without calling `super` or `ModelUtilities`. It only invokes `AutoTokenizer.from(modelFolder:)`. The real backend initializes with explicit model/tokenizer folders, `verbose=false`, `.none` logging, `prewarm=false`, `load=false`, `download=false`, then explicitly calls `loadModels()`.
- `WhisperRuntimeMetadata` derives graph family from logits and encoder dimensions, verifies decoder encoder-input dimension agrees, and sets `textDecoder.isModelMultilingual`. Upstream private-set `modelVariant` is never used for product identity or inference configuration. `large-v1/v2` and `large-v3` are graph families: these dimensions cannot distinguish v1 from v2, or v3 from turbo.
- **C3 success-only persistence API:** `LocalASRLease.whisperMetadata: WhisperRuntimeMetadata?` is immutable and defaults to nil for existing initializers. Its fields are `variant`, `logitsSize`, `encoderSize`, `isMultilingual`. The Whisper factory fills it from `WhisperASRProvider.verifiedMetadata`; use its `variant` to replace C1's `unverified` descriptor only after coordinator ownership/success checks. `lease.identity` already displays the verified Whisper family. No persistence is performed by C2.
- Product `LocalWhisperTokenizer` implements the public protocol / `SpecialTokens` initializer. Requires special tokens rather than defaulting; validates vocabulary IDs, language range and all 1,501 timestamps against graph vocabulary. Before invoking dependency constructors, bounded local JSON validation checks full contiguous vocabulary / sparse added IDs, complete byte alphabet, BPE merges, and the standard Whisper ByteLevel pipeline. This prevents upstream fatalError paths on missing merges or unknown tokenizer pipeline types. Optional postprocessing supports ByteLevel / valid TemplateProcessing; other tokenizer pipelines fail closed.
- All transcription result arrays and their ordered segments are retained, with aggregate-text fallback for an empty segment list. Audio is forwarded whole, including >30 seconds. Decode options use one worker and no framework logging. Language normalization accepts supported language names/codes and rejects unsupported hints; prompt encoding excludes special prefixes.

## Actual isolation / cancellation semantics

`WhisperInferenceQueue` is an actor holding an explicit predecessor-task chain. Actor isolation alone is **not** the exclusivity mechanism: every work task awaits the previous task's actual completion. Caller cancellation resolves a separately locked `CancellableContinuationBox` promptly but never releases the chain's permit. An already-running backend may complete late; its result is discarded. Cancelled queued work checks its box and never enters the backend. A following session waits for old compute to finish. Core ML / tokenizer objects are private to the backend actor; after construction, production access is through the provider's exclusive chain. No framework object is shared between replacement candidates. Existing Qwen provider retains its synchronous serial inference queue.

## TDD and verification

Logs all under `.superpowers/sdd/2026-11-01-m2-c-hf-import/`.

1. RED: `swift build > task-2-red.log 2>&1`, exit 1. New runtime fixture references failed with missing `WhisperASRProvider` / `OfflineWhisperBackend` before implementation.
2. Tokenizer/metadata RED: `swift build > task-2-red-tokenizer.log 2>&1`, exit 1. Missing `WhisperRuntimeMetadata`, backend and offline error APIs while tokenizer/graph tests were introduced.
3. Integration iteration: build succeeded; `swift run FlowType --self-test > task-2-self-test-1.log 2>&1`, 2137 passed / 1 failed. Synthetic tokenizer omitted ByteLevel pretokenizer, so fixture correctly failed whitespace validation. Fixture repaired; not a production success claim.
4. Behavioral RED: `swift run FlowType --self-test > task-2-self-test-2.log 2>&1`, 2151 passed / 1 failed: `Whisper split preserves literal replacement character — got ���A, want �A`. Fixed Unicode split boundaries using scalar offsets plus suffix decoding stability. This avoids using indices from unrelated Swift strings and preserves literal U+FFFD bytes.
5. Interim GREEN: `swift build` then `swift run FlowType --self-test` (`task-2-build-3.log`, `task-2-self-test-3.log`), 2160 passed / 0 failed.
6. Self-review behavioral RED: added sparse out-of-range token to otherwise complete local tokenizer. `swift build` then `swift run FlowType --self-test` (`task-2-red-sparse-build.log`, `task-2-red-sparse.log`) failed `Whisper rejects sparse added token beyond graph vocabulary`. Added complete bounded inventory validation before dependency parsing.
7. Corruption guard RED: `swift build > task-2-red-metadata.log 2>&1`, exit 1 for missing `validateTokenizerMetadata` while adding the missing-merges regression. Source audit found dependency `fatalError` for missing BPE merges and unchecked pair indexing; added product validation before calling that dependency, without triggering an intentional app crash.
8. Final sequential verification: `swift build > task-2-build-final.log 2>&1`, exit 0, `Build complete! (22.58s)`; followed by `swift run FlowType --self-test > task-2-self-test-final.log 2>&1`. Final result recorded below.

Fixture coverage includes selected folder/options; real offline override with synthetic encoder/decoder shapes and actual locally parsed synthetic tokenizer; absent/corrupt tokenizer; zero intercepted network requests on failure/success; non-tiny and English/v3 graph identity; inconsistent dimensions/vocabulary; required specials; literal U+FFFD, ASCII/CJK/emoji split tokens; all framework result arrays/segments; 61-second synthetic array retained; non-English/context forwarding; empty output; wrong sample rate; prompt cancellation while running/queued; late old completion; new session waiting; maximum actual backend concurrency one. Cancellation test waits have bounded deadlines. Fixtures remove only their own temporary directories.

## Dependency diff and compatibility audit

`Package.swift`: exact WhisperKit 0.18.0, plus only required WhisperKit / Tokenizers / Hub products. Direct swift-transformers range is 1.1.6..<1.2.0, matching the exact WhisperKit requirement.

`Package.resolved` (`task-2-dependencies.diff`):
- add WhisperKit 0.18.0 `e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef`;
- targeted swift-transformers downgrade 1.3.2 → 1.1.9 `150169bfba0889c229a2ce7494cf8949f18e6906`;
- remove now-unreachable `swift-huggingface` 0.9.0 and its `EventSource` 1.4.1 dependency;
- all other existing pin revisions unchanged.

Initial `swift package resolve` updated checkouts but emitted a transient default-traits diagnostic for transformers. `swift package --skip-update resolve` subsequently exited 0 using those checkouts; no manifest patch to dependencies, cache deletion, fork, or version substitution. Logs `task-2-resolve.log` / `task-2-resolve-2.log` preserve this.

Read-only 1.1.9 API audit: local `AutoTokenizer.from(modelFolder:)` calls local `LanguageModelConfigurationFromHub.loadConfig`, reads local tokenizer files and has no remote fallback. Hub metadata still sends HEAD with identity encoding, reads `X-Repo-Commit`, `X-Linked-Etag`/`ETag`, `X-Linked-Size`/`Content-Length`, follows relative redirects and preserves absolute redirect metadata. Existing product `ModelMetadataPreflight` fixtures run in the full self-test after downgrade; no actual network probe was repeated. Qwen / existing preflight APIs build against 1.1.9.

## Files / self-review / limitations

Created: `Services/Speech/WhisperASRProvider.swift`, `OfflineWhisperKit.swift`, `LocalWhisperTokenizer.swift`, `Services/Speech/LocalModelManager/LocalASRRuntimeFactory.swift`, `Testing/WhisperRuntimeSelfTests.swift`.
Modified: Package.swift, Package.resolved, `ModelProvisioning/LocalASRLease.swift` (authorized additive metadata), `Testing/SelfTest.swift` (registration).

Self-review caught and fixed literal replacement-character splitting, sparse vocabulary acceptance, and dependency constructor fatalError exposure. `git diff --check` is clean. Build emits the existing AppLogger `nonisolated(unsafe)` warning and the C2 test-source always-succeeding forced-cast warning (initial report omission corrected in fix 1 below); clean dependency rebuild additionally showed existing AVFoundation/dependency warnings.

**Actual full Whisper Core ML model load/inference remains Pending.** Synthetic graph/tokenizer and backend coverage does not prove GPU/Neural Engine execution, real model quality, every checkpoint/tokenizer package, English/non-English audio, or actual long audio. C1's separate actual Qwen 1.7B static inspection remains static-only. No desktop/updated GUI claim. C3 persistence and C4 UI are outside this commit.

## Final result / commit

Final `swift run FlowType --self-test` exited 0: **2162 passed, 0 failed** (product build 4.50s).

Commit: `d12f6d0` — `feat: run imported Whisper Core ML models strictly offline`. Nine scoped files, 741 insertions / 21 deletions. No verification rerun after unchanged commit. Tracked workspace clean after commit.

## Review fix 1 — standard unknown token and no-speech alias (base d12f6d0)

Review finding: swift-transformers BPE `convertTokenToId` returns `unknownTokenId` for absent token names. Standard Whisper config has `unk_token=<|endoftext|>`; a missing Cantonese token therefore polluted the language inventory with 50257 and also appeared to be a supported requested language. The old synthetic config omitted `unk_token` and missed this behavior.

Changed `LocalWhisperTokenizer` to require exact token→ID→token round-trips for its language inventory and exposed token lookup. The real backend now uses a shared production `languageCode` helper that independently requires that same round-trip before constructing decoding options. Synthetic fixtures include the standard unknown-token configuration; tests cover absent `yue` / `Cantonese`, supported English / Chinese / automatic selection, English-only rejection of Chinese, and v3's genuine Cantonese token.

The separate public metadata check found a second compatibility issue: standard Hugging Face Whisper tiny uses `<|nocaptions|>` at 50362 instead of `<|nospeech|>`. Controller authorized including this in the same fix round. The adapter now resolves either explicit spelling through exact lookup, requires exactly one unique no-speech ID, rejects conflicting aliases, and still validates the resulting ID against the model graph vocabulary. No guessed/default special-token ID was introduced.

TDD evidence:

- Initial RED: `swift build > task-2-fix1-red-build.log 2>&1` exit 0, then `swift run FlowType --self-test > task-2-fix1-red.log 2>&1` exit 1: **2136 passed, 5 failed**. Failures included language count `100` versus `99`, end token in language inventory, absent Cantonese returning `Optional(50257)` versus nil, and both tokenizer/local override validation rejecting the standard config.
- First fix GREEN: `swift build` (`task-2-fix1-build-final.log`, 32.10s) then `swift run FlowType --self-test` (`task-2-fix1-self-test-final.log`), **2177 passed, 0 failed**.
- Public manual RED: a scratch standalone harness compiled the exact product `LocalWhisperTokenizer.swift`, with exact error/graph-metadata declarations extracted from `OfflineWhisperKit.swift`, against existing resolved dependency objects. It read the already-downloaded public tiny tokenizer metadata using local `AutoTokenizer.from(modelFolder:)`. First execution failed `incompatibleTokenizer` because `<|nocaptions|>` was not accepted; the scratch main's uncaught thrown error produced exit 133. No model graph/weights were loaded. The initial harness link attempt also required removing Swift response-file quoting from paths used by the linker's file-list format; this was harness setup only, not a product change.
- Alias synthetic RED: `swift build` (`task-2-fix1-alias-red-build.log`) then `swift run FlowType --self-test` (`task-2-fix1-alias-red.log`), **2177 passed, 1 failed**, `Whisper standard no-captions spelling must load: incompatibleTokenizer`.
- Public manual GREEN after alias fix: compile command is the same `swiftc -parse-as-library -target arm64-apple-macosx15.0 -I .build/arm64-apple-macosx/debug/Modules -Xcc -fmodule-map-file=.build/arm64-apple-macosx/debug/yyjson.build/module.modulemap Sources/flowtype/Services/Speech/LocalWhisperTokenizer.swift .superpowers/sdd/2026-11-01-m2-c-hf-import/task-2-fix1-public-types.swift .superpowers/sdd/2026-11-01-m2-c-hf-import/task-2-fix1-public-main.swift -Xlinker -filelist -Xlinker .superpowers/sdd/2026-11-01-m2-c-hf-import/task-2-fix1-public-objects.txt -o .superpowers/sdd/2026-11-01-m2-c-hf-import/task-2-fix1-public-probe`. Compile exit 0 (`task-2-fix1-public-build-final.log`), probe exit 0 (`task-2-fix1-public-probe-final.log`): `PUBLIC TOKENIZER CONTRACT PASS: 99 languages; raw absent yue=Optional(50257); exact yue=nil; zh=50260`. Source/artifact hashes in `task-2-fix1-public-source-hashes.txt`.

The public acceptance check is **actual tokenizer metadata compatibility only**, separate from synthetic self-tests; public metadata was not added as a model test fixture. It supplies expected tiny graph dimensions to the validator, so it proves neither actual graph loading nor GPU/inference. Full model acceptance remains Pending. No network request or model download was needed for this check.

Warning correction: the original report's warning accounting omitted `WhisperRuntimeSelfTests.swift:67` — `forced cast from '[NSString : Any]' to '[String : Any]' always succeeds; did you mean to use 'as'?`. This is a new test-source warning from C2, distinct from the inherited `AppLogger.swift:27` unnecessary `nonisolated(unsafe)` warning. Both are present in this fix's build logs. The forced-cast cleanup remains deferred per controller instruction; no warning-free output claim.

Scope: three existing files only — `LocalWhisperTokenizer.swift`, `OfflineWhisperKit.swift`, `WhisperRuntimeSelfTests.swift`. No dependency, queue/cancellation, persistence, or UI changes. Final sequential verification / commit recorded below.

Fix 1 final sequential GREEN: `swift build > task-2-fix1-build-final-2.log 2>&1`, exit 0, **22.71s**; then `swift run FlowType --self-test > task-2-fix1-self-test-final-2.log 2>&1`, exit 0, **2179 passed, 0 failed** (product build 4.55s). `git diff --check` clean. Commit **`9f0c92e` — `fix: validate exact Whisper language and no-speech tokens`**, three scoped files, 97 insertions / 25 deletions. Tracked working tree clean; no unchanged verification rerun after commit.
