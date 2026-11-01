# Whole M2 final fix wave

Base: `73d5e744dd661b70d97126df605dfb20d7aea674`. Authoritative findings: `whole-m2-review.md` (three Important, two bounded minor fixes). One implementation worker; no implementation subagents or worker-dispatched reviewers. Controller owns a fresh scoped rereview after commit. No final review Pass is claimed.

## Changes by finding

1. **Ordinary retry preserves the original selection request.** `QwenModelState.selectionRequest` is separate from mutable presentation/attempt `target`. Shared `ModelRecoveryActions.retry` replays original target+origin with the current store download source. Automatic 1.7B retry again permits one 0.6B fallback; success keeps `selectedLocalModelID == nil`. Explicit selection remains explicit and never auto-falls back. Reset/failed import/configured selection clears stale request intent. Regression runs through real shared action, real coordinator, isolated persisted `ConfigurationStore`, restart and installed-local fallback; only compute/preflight are injected.

2. **Whisper raw graph contract precedes every unsafe dependency dimension accessor.** New focused `WhisperGraphContract.swift` captures Core ML `MLModelDescription` feature name/type/shape/optionality/shape constraints without calling WhisperKit dimension helpers. `OfflineWhisperKit.loadTokenizerIfNeeded` validates mel, encoder, decoder and optional prefill before installing a tokenizer/verified metadata. Pinned `WhisperKit.loadModels` calls this override before setting `.loaded`; failed validation cannot return a ready candidate, and coordinator integration regressions preserve the previous ready lease/config.
   - Required named MultiArray inputs and outputs, exact ranks and fixed output extents; unknown required inputs rejected, omitted optional inputs allowed, always-provided optional inputs accepted.
   - 480000 Float32 audio samples, 3000 mel frames, 1500 encoder frames; 80 vs 128 mel bins follows old/v3 vocabulary. Encoder/mel interfaces agree in shape and dtype. Fixed raw output extents are required; enumerated output shapes must all equal the default and ranged outputs must be singleton defaults. Inputs may advertise flexibility: this runtime always supplies the checked default shapes (including full cache/masks; only their contents change).
   - Logits are **[1,1,vocabulary]**, following actual `TextDecoder.logitsSize` axis 2 and `LogitsFilter` rank-three indexing, not stale generated rank-four comments.
   - Float16 key/value caches and updates, matching widths and context, masks, optional alignment [1,1500] and prefill [1,width,1,3] checked. Context 224...448 covers pinned loop/native Whisper context; width is hidden size × 1...32 decoder layers. Tiny/base/small/medium English and multilingual, large-v1/v2, large-v3, reduced-layer distil/turbo remain accepted. Identity remains family-level where dimensions cannot distinguish checkpoints.
   - All unsafe pointer consumers require Float16 outputs (logits, key/value updates, alignment, prefill). Intermediate feature dtype equality and Float16 cache input requirements remain strict. Current contract after the scoped-review continuation below: **Int32-only update masks**, Float16 padding masks. Initial acceptance of Float16 update masks inferred too much from a hand-written upstream fixture and is corrected in the continuation. No generalized Core ML input numeric-coercion claim. Unknown exports and actual full graphs remain Pending.
   - Controller-approved additional safety ruling: pinned 0.18 allocates Float16 caches but uses `MemoryLayout<FloatType>.size` for copies; x86_64 defines FloatType as Float. Runtime ABI guard rejects that mismatch before model allocation in backend load and again in graph validation. Hardware admission and import help specifically explain current WhisperKit 0.18 Intel limitation, not a Core ML format restriction. Architecture/stride tests and spec document this; controller ruling archived verbatim.

3. **Qwen complete tokenizer validation.** Base vocab must contain every ID 0...151642 and the complete 256-byte alphabet; every ordinary token consists of byte alphabet symbols. Added/special IDs 151643...151704 must exist, with exact existing critical token/role IDs. Added tokens can be in vocab or tokenizer_config and cannot conceal a missing base row. Padding 151705...151935 remains legally absent. Merge rules must have two nonempty base-vocab operands available in rank order, a base-vocab result, no duplicate pair/result, and reach every base token (151387 merges). `#` is a valid byte; only the explicit version header is skipped. Synthetic fixtures generate complete byte-BPE vocab/merges, independent of installed metadata; converted fixtures separate added tokens as the actual format does. Static checks establish structure/completeness, not semantic equality to weight payloads or transcription accuracy.

4. **Bounded minor fixes.** Safetensors optional `__metadata__` must be string→string; valid string map is present throughout positive sparse fixtures and numeric value is rejected. New Whisper forced NSDictionary bridge is replaced with explicit NSString→String key conversion. The inherited AppLogger warning is unchanged.

## Initial-wave RED / GREEN commands and logs

All paths below are under `.superpowers/sdd/2026-11-01-m2-c-hf-import/`. No `swift test` was run.

- Initial test-only build `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-red-build.log 2>&1` failed on Swift 6 Reporter region isolation after placing a new MainActor fixture too early. Moving it into the existing MainActor group fixed the fixture ordering; this is not behavioral RED. `whole-m2-red-build-2.log` then built in 33.83s. A final complete-added-token fixture adjustment was followed by `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-red-build-3.log 2>&1`, exit 0, 28.42s.
- Behavioral RED: `swift run FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-red-self-test.log 2>&1`, exit 1, **164 passed / 54 failed**. Seven tokenizer/metadata failures, 42 raw-graph rejection/verified-readiness assertions, five retry/fallback/persistence assertions. Example failures: ordinary missing vocab accepted; rank-one logits accepted and published verified metadata; retry attempts `[0.6B,0.6B]` instead of `[1.7B,0.6B]`; persisted selected ID changed to explicit 0.6B. All were expected against the compiled pre-fix behavior. No fatal crash was needed to demonstrate the unsafe raw-rank path: synthetic graph adapters report bad raw descriptions while legacy scalar accessors still look plausible.
- `whole-m2-green-build-1.log` caught a Core ML SDK API spelling issue (`sizeRangeForDimension` is an array property, not a function), corrected using actual SDK header. Build 2 passed; admission-test strengthening then built in `whole-m2-green-build-3.log`, exit 0, 28.10s.
- Focused GREEN: `swift run FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-green-self-test-1.log 2>&1`, exit 0, **267 passed / 0 failed**. Subsequent self-review narrowed mask types and added optional-output/numeric-mask regressions; final full verification below covers those edits.
- Final sequential `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-final-build.log 2>&1`: exit 0, **30.08s**, inherited `AppLogger.swift:27` warning only.
- Final `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-final-self-test.log 2>&1`: exit 0, **2427 passed / 0 failed** (product build 4.64s). This GREEN covers the initial 5be1b4f checkpoint; the later narrow mask correction and its changed-source verification are recorded below. `git diff --check` clean.

Focused entry `--self-test --m2-fix-only` executes the normal import/Whisper suites plus new shared retry/graph admission cases. All cases also run in the full self-test; this is a selectable self-test scope, not a replacement test implementation.

## Separate actual static compatibility acceptance

No synthetic fixture result is presented as real model compatibility. After validator changes, compiled **exact four product inspector files** and the existing probe harness, with no MLX/Whisper runtime link:

```sh
swiftc -parse-as-library Sources/flowtype/Services/Speech/LocalModelManager/ImportedASRModel.swift Sources/flowtype/Services/Speech/LocalModelManager/ASRModelInspector.swift Sources/flowtype/Services/Speech/LocalModelManager/SafetensorsManifest.swift Sources/flowtype/Services/Speech/LocalModelManager/WhisperModelInspector.swift .superpowers/sdd/2026-11-01-m2-c-hf-import/inspect-probe-c3.swift -o .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-inspect-probe
.superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-inspect-probe '/Users/yiheng/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit'
```

Compile exit 0 (`whole-m2-actual-static-build.log`); probe exit 0 (`whole-m2-actual-static-probe.log`), at **2026-11-01T20:20:39Z**:

```
STATIC PASS engine=qwenMLX variant=1.7B bits=4 sizeBytes=2225411512
fingerprint=135f5b023e282e0c860d7b10a893487c5274dd012af5a203293d353eed3b1f22
reservationBytes=860225536
```

Same prior fingerprint, size and packed-U32 reservation. Read-only structural inspection found 151643 base IDs, 62 added tokens and 151387 merges; no metadata copied into committed fixtures. Reads were metadata/vocab/merges/safetensors headers and file identity only. No weight payload read, runtime/GPU load, inference, networking, real config/keys or model changes. Inspector/harness SHA256s are in `whole-m2-actual-static-source-hashes.txt`. This source was not changed after the static acceptance.

## Source/API evidence

`whole-m2-pinned-source-hashes.txt` preserves SHA256 of inspected pinned files; `whole-m2-final-source-hashes.txt` captures changed product/helper/test files. Dependency directories remain clean, Package.resolved untouched.

- WhisperKit 0.18 `Core/WhisperKit.swift` lines 361...452: load components, call override, then `.loaded`; no dimension helper occurs before override on this production path. Explicit model/tokenizer folders, download=false and local-only tokenizer override remain.
- `Core/FeatureExtractor.swift` lines 24...37: raw names and unchecked shape[1]/shape[0]. `Core/AudioEncoder.swift` lines 24...36: output shape[1]/shape[3]. `ArgmaxCore/ModelUtilities.swift` lines 13...28: unchecked arbitrary `shape[position]`.
- `Core/TextDecoder.swift` lines 270...278: actual Float16 cache/alignment/prefill allocations and Int32 update mask. Lines 390...439 and 455...475: optional prefill outputs and raw cache/alignment copies using FloatType byte width. Lines 501...518: logits axis2/cache width axis1/cache context and encoder frames axis3. Line 543: pinned 1500-frame alignment indexing. `Core/Models.swift` maxTokenContext=224, provider input/output names and prefill three-token contract. `Core/Text/LogitsFilter.swift` rank-three [0,0,token] and FloatType buffer operations. `ArgmaxCore/FloatType.swift` defines Float16 on ARM, Float on macOS x86_64.
- Core ML SDK headers inspected read-only: `MLMultiArrayConstraint.h` defines required/default shape, **required dataType**, and detailed shapeConstraint. `MLMultiArrayShapeConstraint` supplies enumerated shapes/ranges; snapshot handles these without unchecked indexing. No general numeric input coercion was inferred.
- speech-swift `Sources/AudioCommon/Tokenizer.swift` lines 36...106: separate vocab/added tokens/merge parser, and lines 111...146: unknown token IDs skipped by decode, explaining required complete coverage. No dependency edits/fork/version/cache changes.

## Scope, self-review and remaining acceptance

New focused helper files: `Services/Speech/WhisperGraphContract.swift` (raw graph contract and ABI gate) and `Testing/WholeM2FixSelfTests.swift` (real shared action/persistence and graph admission regressions). Existing inspector/coordinator remain in place; no general refactor. Changed existing files include ASRModelInspector, SafetensorsManifest, OfflineWhisperKit, QwenModelState, ModelRecoveryActions, LocalModelHardwareAssessment, import help, relevant self-tests and evidence/spec/remaining-work/rulings docs.

Self-review checked original vs mutable request ownership, latest-source retry, reset paths, explicit selections, persisted restart, no unsafe dependency accessor before raw validation, every named graph I/O and optional prefill, fixed output constraints, compatible family coverage, static byte alphabet/merge completeness, padding handling, and actual converted tokenizer acceptance. The graph admission fixture would return a successful candidate if validation passed; it does not hide failure behind an independently throwing fake loader. Full-model compute is deliberately replaced in tests and cannot establish actual Core ML graph/payload execution.

**Pending:** controller scoped whole-M2 rereview; GUI/current-binary checks; actual full Qwen/Whisper graph imports/inference and per-variant/hardware memory/accuracy; actual cloud services/devices and V1–V5. Historical checkpoints retained. Native URLSession delegate callback fixture and credential-only bounded router-health reset remain explicit nonblocking follow-ups; neither expanded into this wave. No GUI/relaunch, package downloads, Python installation/scripts, automatic conversion, GB model downloads, deletions of models/caches, push/merge/history reset or key operations occurred. Existing temporary synthetic fixture cleanup remains test-owned only.

## Commit / handoff

Commit: **5be1b4f** — `fix: preserve model retry intent and validate complete runtime contracts` (17 files, focused on these findings plus the approved pinned ABI guard/docs). Initial checkpoint verification was **2427/0**, source build 30.08s; latest narrow continuation follows below. Expected actual-acceptance and controller-review Pending items above are not waived. No new unresolved implementation concern identified during self-review. Scratch report/logs/hashes remain in the C workspace, as requested.

## Scoped-review continuation: production update-mask type

The same scoped reviewer identified a remaining part of Important finding 2 in `5be1b4f`: allowing a graph to declare Float16 `kv_cache_update_mask` was not justified by the production path. Pinned `TextDecoder.swift:275` always allocates an **Int32** update mask; `Models.swift:1016–1017,1033` wraps/stores that exact array without converting it. The Core ML SDK calls `MLMultiArrayConstraint.dataType` the required type. Upstream `UnitTests.swift:553` manually supplies a Float16 array to prediction and therefore does **not** prove production coercion. That earlier inference is withdrawn.

The narrow correction accepts **only Int32** for the raw update-mask feature. The canonical positive graph fixture now matches the production constructor, while a new Float16-negative case exercises the real offline tokenizer/graph validation entry and verifies no detected metadata is published. Other graph type/shape policies, Qwen inspectors, selection intent, dependency versions and runtime code remain unchanged. No conversion adapter is invented.

Current compatibility explicitly **excludes exports declaring Float16 update masks** until an adapter or contract-specific actual conversion evidence establishes support. Import help/spec/evidence state this limitation; “WhisperKit compatible” does not mean all WhisperKit exports. Controller's new narrow continuation ruling is archived verbatim. Initial release bundle `5be1b4f` completed before any follow-up source mutation and is an intermediate artifact only; no updated GUI/inference claim.

Commands/results for this changed source:

- RED test-only `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-mask-red-build.log 2>&1`: exit 0, **29.27s**.
- `swift run FlowType --self-test --m2-fix-only > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-mask-red-self-test.log 2>&1`: exit 1, **274 passed / 2 failed**. Exact failures: Float16-declared raw graph accepted; detected metadata wrongly published instead of nil. The production validator was unchanged until both failures were observed.
- Final sequential `swift build > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-mask-final-build.log 2>&1`: exit 0, **30.35s**, inherited AppLogger warning only.
- `swift run FlowType --self-test > .superpowers/sdd/2026-11-01-m2-c-hf-import/whole-m2-mask-final-self-test.log 2>&1`: exit 0, **2430 passed / 0 failed** (product build 4.56s). This full changed-source run is the GREEN verification for the same regression; no redundant second focused run.
- Latest source SHA256s: `whole-m2-mask-final-source-hashes.txt`, including graph contract, help, runtime/coordinator/action and all relevant fixture files. Pinned-source evidence remains in `whole-m2-pinned-source-hashes.txt`.

Actual Qwen static acceptance is **not rerun**: all four product inspector sources are unchanged from the already recorded exact-product PASS and source hashes. No graph/model execution or new network/configuration/model access was added. This continuation changes only the residual admission rule, its fixtures/help and evidence; the same reviewer will inspect the incremental commit. GUI/full models/services/devices/V1–V5 and that review remain Pending.

Continuation self-review: the single admitted update-mask datatype now exactly matches the production allocation and direct forwarding. Positive fixtures use Int32, the Float16 negative fails without publishing metadata, and all existing regressions pass. No product/test source edits after this GREEN. `git diff --check` clean; unchanged inspector static acceptance was not rerun.

Continuation commit: **3a34a51** — `fix: require production Int32 Whisper update masks`. Six narrowly scoped files. Latest full result **2430/0**, build 30.35s; tracked worktree clean at handoff. Current contract excludes Float16-declared update-mask exports unless adapted/evidenced; same-reviewer incremental review and actual acceptance remain Pending.
