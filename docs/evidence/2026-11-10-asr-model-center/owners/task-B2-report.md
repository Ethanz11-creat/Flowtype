# Task B2 report — compatible native installation planning

Status: DONE. Base: `0a26778`. Implementation frozen after required GREEN. No full suite (controller explicitly reserves it for B6).

## Implemented

- Added the exact spec `ASRInstallPlan` schema with pinned per-file source/commit/endpoint/digest, byte total, recipe identity/version and captured credential reference.
- Added `ASRInstallPlanner`, operating on original B1 resolver results. Qwen closure contains required config/vocab/merges/tokenizer configuration plus the sole supported safetensors index and every referenced shard, or the selected single weight file. Alternate root `*.safetensors.index.json` names are supported because the existing detector supports them; nested shard references are explicitly rejected because the current loader only reads direct children. Unrelated weights/docs are excluded.
- Whisper planning selects one model directory, rejects an unselected multi-variant root, retains all files recursively inside each selected required Core ML package and optional ContextPrefill, checks compiled MIL references / package Manifest resources, and obtains its unique local tokenizer from the model or an explicit second resolved source. Known mismatched OpenAI variant tokenizers are rejected. Unknown models never borrow tiny or access a local/global cache. Tokenizer assets map to the local `tokenizer/` directory; tokenizer-source model weights are never included.
- Added strict native registry and Qwen/Whisper adapters. Duplicate engine registration fails, zero metadata matches fail with local-service guidance, multiple matches fail without ordered guessing. Qwen architecture and quantization checks were extracted verbatim from the existing inspector into shared `NativeASRFormatSupport.qwenMetadata`; all tensor/tokenizer validation remains in the original inspector. Whisper component/package constants are shared with its inspector.
- `LocalASRRuntimeFactory.load` retains the original complete on-disk dispatcher reinspection, fingerprint/engine/tokenizer/compatibility checks, then calls the injected/default registry adapter. It uses newly inspected resource metadata while preserving library identity. Qwen adapter inspection calls the internal Qwen-specific entry, never the dispatcher, so there is no recursive dispatch.
- Added four versioned candidate recipes: existing Qwen 0.6B/1.7B 4-bit and multilingual Whisper tiny/base with exact matching tokenizer commits. Every candidate remains `verified: false`; metadata prechecks never claim successful native graph/tensor loading or transcription. Existing presets can obtain their pinned installation recipe.
- Metadata reads enforce the 16MiB per-file cap and one 32MiB cumulative budget across both source contexts, including initial info/tree bytes. Before reads, advertised length must fit; after reads, actual size and remaining aggregate budget are checked. Only lowering test limits is supported. Context IDs deduplicate an identical source context's initial bytes. Case/canonical-Unicode destination collisions, unsafe/absolute paths, missing dependencies, excessive file counts and Int64 sums are rejected.
- Missing license information remains unknown in the B1 repository result; no license acceptance or authorization state is synthesized.

## Approved API handoffs / rulings

Controller approved `plan(repository:variant:tokenizer:credentialID: String? = nil)` to preserve the required three-argument call form while supporting the plan's credential field. Production initialization is:

```swift
let planner = ASRInstallPlanner(client: sameHFRepositoryClient)
let plan = try await planner.plan(repository: originalResolvedResult,
                                  variant: explicitVariant,
                                  tokenizer: originalTokenizerResult)
```

`HFRepositoryClient.preflightContext(for:) throws -> HFRepositoryPreflightContext` exposes only captured `credentialID: String?` and `receivedBytes: Int`, after validating original context identity, source selection, commit, endpoint, full manifest and license metadata. It does not expose token values or mutable context state. Planner defaults to the original credential ID; an explicit nonnil ID must be `asr.hf.official` and match the source context(s). An anonymous/official mixture captures the official reference; B3 must continue enforcing official-origin-only auth and anonymous mirrors, as approved. All `readMetadata` calls retain the original resolver result, rather than reconstructing it.

`ASRInstallPlanner` also has an internal metadata/context closure initializer for controlled tests. `LocalASRRuntimeFactory.load(_:registry:)` defaults to `.standard`, preserving existing callers. Registry exposes required `engine(config:paths:)` and `load(_:)`, plus an engine-specific inspection method. `LocalASREngineAdapter` has the exact engine / metadata assessment / inspection / load contract from spec §6.

Recipe source commits:

- Qwen 0.6B: `bc441bd1e4295c1f42d9879f056049a925b6e013`
- Qwen 1.7B: `d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6`
- Whisper Core ML: `0f63a7800b00dd0226abd051b906c246e1907482`
- Whisper tiny tokenizer: `169d4a4341b33bc18d8881c4b69c2e104e1cc0af`
- Whisper base tokenizer: `e37978b90ca9030d5170a5c07aadb050351a65bb`

The first four are from the supplied research snapshot. Base was frozen from exactly one bounded, verified-TLS public API metadata read on 2026-11-10: `https://huggingface.co/api/models/openai/whisper-base`, HTTP 200, 8598 bytes. No weight requests. Added that source record to the research JSON. Planning itself always reads the supplied pinned resolver metadata; it does not refetch a floating revision.

## TDD evidence

All build/self-test commands were sequential; no competing processes. Output lives beside this report.

Initial RED, compiling interface stubs before production implementation:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-red-build.log 2>&1
# exit 0; Build complete! (31.05s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-red-selftest.log 2>&1
# exit 1; HF install self-test: 137 passed, 18 failed
```

Expected failures included:

```text
FAIL: B2 Qwen plan failed: unsupportedArchitecture
FAIL: B2 Whisper plan failed: unsupportedArchitecture
FAIL: B2 root multiple variants need selection
FAIL: B2 absent tokenizer needs explicit source
FAIL: B2 aggregate model/tokenizer budgets enforced
FAIL: B2 duplicate engine registration rejected
FAIL: B2 registry/factory failed: ... unreadable ...
```

Additional boundary RED before final fixes:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-boundaries-red-build.log 2>&1
# exit 0 after correcting an Int/Int64 fixture literal compile error
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-boundaries-red-selftest.log 2>&1
# exit 1; HF install self-test: 195 passed, 2 failed
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-factory-red-build.log 2>&1
# exit 0
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-factory-red-selftest.log 2>&1
# exit 1; HF install self-test: 195 passed, 3 failed
```

Exact relevant RED:

```text
FAIL: B2 injected adapter cannot bypass real file recheck
FAIL: B2 alternate index failed: incompleteModel
FAIL: B2 index cannot broaden loader direct-child layout — got ... incompleteModel, want ... invalidPath
```

These caught an initial engine-specific adapter inspection bypass of the factory's original dispatcher check, and an overly narrow index filename assumption. The final factory uses actual filesystem inspection even with an injected load stub; the test mutates a real isolated tokenizer config and asserts loading is blocked before reaching the runtime adapter.

Final required GREEN:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-green-build.log 2>&1
# exit 0; Build complete! (27.99s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-green-selftest.log 2>&1
# exit 0; HF install self-test: 211 passed, 0 failed
swift run --skip-build FlowType --self-test --m2-review-inspection-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-green-inspection.log 2>&1
# exit 0; M2 inspection self-test: 43 passed, 0 failed
swift run --skip-build FlowType --self-test --m2-review-packages-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-green-packages.log 2>&1
# exit 0; M2 package self-test: 34 passed, 0 failed
git diff --check
# exit 0, no output
```

Final build output has no warnings/errors. Focused logs contain only the self-test headers and passing summaries.

Tests include all four required named methods plus package/MIL dependencies, alternate index names, selected source subdirectories, direct-child shard layout, actual 16MiB limit, lowered cross-source cumulative budget tests, initial resolver bytes, total byte overflow, explicit credential mismatch, four pinned candidate recipe plans, injected URLProtocol integration with the real B1 resolver/client, unchanged authorization context, zero model-weight GETs, and altered resolver-context rejection. The new native test fixture lives in a UUID-named temporary directory and is removed at completion.

## Files changed

New:

- Sources/flowtype/Services/Speech/ModelInstallation/ASRInstallPlan.swift
- Sources/flowtype/Services/Speech/ModelInstallation/ASRInstallPlanner.swift
- Sources/flowtype/Services/Speech/ModelInstallation/ASRModelRecipes.swift
- Sources/flowtype/Services/Speech/LocalModelManager/NativeASRFormatSupport.swift
- Sources/flowtype/Services/Speech/LocalModelManager/LocalASREngineAdapter.swift
- Sources/flowtype/Services/Speech/LocalModelManager/LocalASRRuntimeRegistry.swift
- Sources/flowtype/Services/Speech/LocalModelManager/QwenMLXEngineAdapter.swift
- Sources/flowtype/Services/Speech/LocalModelManager/WhisperCoreMLEngineAdapter.swift
- Sources/flowtype/Testing/HFInstallPlannerSelfTests.swift

Modified:

- Sources/flowtype/Services/Speech/LocalModelManager/ASRModelInspector.swift
- Sources/flowtype/Services/Speech/LocalModelManager/WhisperModelInspector.swift
- Sources/flowtype/Services/Speech/LocalModelManager/LocalASRRuntimeFactory.swift
- Sources/flowtype/Services/Speech/LocalModelManager/ModelPreset.swift
- Sources/flowtype/Services/Speech/ModelInstallation/HFRepositoryClient.swift
- Sources/flowtype/Testing/HFInstallSelfTests.swift
- docs/superpowers/specs/2026-11-09-hf-model-installation-design.md
- docs/superpowers/plans/2026-11-09-asr-model-center-b-hf-installation.md
- docs/superpowers/research/2026-11-09-asr-model-center-sources.json

## Self-review / limitations

Read the entire new native/plan/recipe implementation and changed-file diffs. Compared the extracted Qwen metadata block against its original inspector, including every exact dimension, normalization, optional override and quantization guard. Checked all metadata read paths preserve original B1 contexts, indices agree with the actual loader, Core ML references cannot traverse, plan destinations are unique and safe, actual disk changes block injected loading, and recipe identity only stamps exact source commits. No unresolved self-review findings.

No dependency/Package.resolved change. No child agents, push, merge, real secrets, user configuration/model/cache/permission/microphone/clipboard writes, or weight downloads. Aside from the explicitly authorized small base-tokenizer API metadata request, networking uses injected synthetic URLProtocol. Native compatibility is still a candidate precheck: actual model payload/tensor, graph runtime loading, offline sample recognition and recipe verification remain B5/B6 acceptance work. Installer/download/publisher/activation/UI are later tasks. No manual or real-runtime Pass is claimed.

Commit: `5200d7e feat: plan complete compatible ASR model installations`. Staged diff check passed; post-commit `git status --short` empty (clean).

## Review fix round 1 — I1 normalized file/directory ancestor collisions

Review finding: Important I1. Comparing only complete normalized file names accepted a file `AudioEncoder.mlmodelc/weights` together with `AudioEncoder.mlmodelc/Weights/weight.bin`; default macOS volumes cannot materialize both because the first path must be both a file and a directory.

Implemented one focused `ASRInstallPlanner.validateFilePaths` helper, reused by per-source manifest validation and by the entire final mapped destination list. It validates lexical paths, normalizes each component with locale-stable Unicode case folding and canonical Unicode normalization, rejects duplicate complete paths, collects the complete normalized file set, then rejects any file whose ancestor is also in that set. Checking the complete set makes rejection independent of enumeration order. Shared directories with distinct child files remain accepted. Added a specific collision explanation: this model layout cannot safely install on macOS's default filesystem; the conservative portable-layout restriction also applies on case-sensitive volumes.

Regression tests exercise the review's selected compiled-package example in both source enumeration orders; NFC/decomposed Unicode ancestors; Straße/STRASSE folding; Unicode/case-equivalent complete names; two individually safe source records whose mapped tokenizer destinations collide (full-name and file/directory cases, both orders); and a real two-source planner result with case/Unicode-equivalent directory names and distinct child files that must remain accepted. The cross-source mapped-file cases invoke the exact helper used for the final destination set, because the present fixed package/tokenizer mapping itself separates their namespaces.

Exact sequential RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-fix1-red-build.log 2>&1
# exit 0; Build complete! (29.99s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-fix1-red-selftest.log 2>&1
# exit 1; HF install self-test: 219 passed, 6 failed
```

Before the production fix the shared helper contained the previous complete-name equality check only. Actual relevant RED output:

```text
FAIL: B2 normalized source file/directory collision rejected in either order
FAIL: B2 normalized source file/directory collision rejected in either order
FAIL: B2 normalized source file/directory collision rejected in either order
FAIL: B2 normalized source file/directory collision rejected in either order
FAIL: B2 mapped paths across sources cannot collide
FAIL: B2 mapped paths across sources cannot collide
=== HF install self-test: 219 passed, 6 failed ===
```

Exact final sequential GREEN:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-fix1-green-build.log 2>&1
# exit 0; Build complete! (27.23s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B2-fix1-green-selftest.log 2>&1
# exit 0; HF install self-test: 225 passed, 0 failed
git diff --check
# exit 0; no output
```

Final build has no warning/error lines. No shared inspectors changed, so the controller-authorized fix gate is build + HF focused only; unchanged legacy inspection/package checks were not repeated. Full suite remains B6. Read the full three-file fix diff for self-review: both gates call the same implementation, normalized components retain directory boundaries, duplicate and ancestor rejection are independent of iteration order, and valid siblings retain both source mappings. No unresolved self-review finding. No dependency, network, weights, user-state, or native-runtime change. Code frozen after this GREEN.

Fix files:

- Sources/flowtype/Services/Speech/ModelInstallation/ASRInstallPlanner.swift
- Sources/flowtype/Services/Speech/ModelInstallation/ASRInstallPlan.swift
- Sources/flowtype/Testing/HFInstallPlannerSelfTests.swift

Fix commit: `8b47f62 fix: reject normalized ASR file directory collisions`. Staged diff check passed; post-commit worktree clean.
