# Independent M2 review

Range: `878725c..9fa57bf`; final production checkpoint `3a34a51`. Read-only checkout review, 2026-11-02. No checkout/index/branch changes, subagents, real configuration/key/audio/model access, network requests, GPU inference, model downloads, or unchanged full-suite rerun. Scratch artifacts are outside the checkout.

## Strengths

- A single coordinator owns model operations, retains the previous usable lease, serializes process-wide endpoint changes, and commits selection only after successful owned loading. Capture snapshots retain their provider through later model switches and record removal.
- HTTP tests and dictation share request construction, response parsing, redirect policy and sanitized errors. Settings checks use UUID/revision ownership and retain the in-flight slot after edits, preventing obsolete success from validating changed credentials or endpoints.
- Import admission checks full Qwen tensor inventory, tokenizer structure, file identity and manifest boundaries. Whisper overrides the upstream tokenizer fallback, validates raw graph descriptions before unsafe dimension accessors, and checks the pinned decoder allocation types and Intel ABI explicitly.
- The evidence distinguishes synthetic tests, tokenizer-only/static-model probes and actual inference. The documented Pending acceptance cases are not silently reported as passed.

## Issues

### Important — P2: accepted Whisper `.mlpackage` sources have no matching source-to-runtime preparation

**Product locations:** `Sources/flowtype/Services/Speech/OfflineWhisperKit.swift:179` (through the call at 185); `Sources/flowtype/Services/Speech/LocalModelManager/WhisperModelInspector.swift:34`.

**Trigger:** choose an otherwise supported Whisper export whose three components are source `.mlpackage` bundles rather than compiled `.mlmodelc` bundles. The inspector explicitly admits these bundles and reads each Manifest root path. Loading forwards the original folder directly to the pinned WhisperKit `loadModels()` without preparing compiled components.

**Evidence:** pinned `WhisperKit/Sources/ArgmaxCore/ModelUtilities.swift:69` only checks `Name.mlpackage/Data/com.apple.CoreML/model.mlmodel`; it does not read the Manifest. A valid package whose manifest root is another legal relative `.mlmodel` path is accepted by our inspector but deterministically resolves to a nonexistent `Name.mlmodelc`, and `WhisperKit/Core/WhisperKit.swift:377` throws “Model file not found.” Even for the fixed conventional source path, `WhisperKit/Core/Models.swift:19` directly passes that source `.mlmodel` to `MLModel.load(contentsOf:)`; there is no `compileModel` call in the product or this pinned path. The installed Core ML SDK `MLModel.h:50` defines that asynchronous load URL as a `.mlmodelc` directory, and `MLModel+MLModelCompilation.h:48` describes compiling a source model and loading the returned directory.

**Effect:** the advertised source-package import branch can pass static preview but cannot fulfill its load-and-use contract through the implemented runtime path. This is a concrete source/runtime contract gap, separate from the broader Pending full-Whisper inference acceptance. The standard-path failure has not been executed with a real graph in this review; the alternate-root missing-file branch follows directly from the actual lookup code.

**Fix:** prepare accepted source packages locally using Core ML compilation into an application-owned temporary/cache location, preserve the package’s manifest/resource layout, and load the resulting compiled components while leaving user sources untouched. Alternatively, explicitly reject source packages and revise the supported-format promise, if the owner approves that reduced scope. Add a focused contract test that reaches actual component path resolution/preparation; current `LocalModelImportSelfTests.swift:122–129` only creates three-byte fake model sources and proves static manifest acceptance, while runtime tests substitute graph/compute adapters.

### Important — P2: full Qwen reinspection blocks the main actor on every import load and restore

**Product location:** `Sources/flowtype/Services/Speech/QwenModelState.swift:365`; the legacy/offline entry also performs the same synchronous work at `:276`.

**Trigger:** click “加载并使用” for a valid Qwen preview, restore a selected imported Qwen on startup, or retry a legacy/custom directory. `QwenModelState` is `@MainActor`; its injected `inspect` closure is synchronous and defaults to `ASRModelInspector.inspect`. Thus `provision` performs the complete 151643-base-token/151387-merge validation, JSON duplicate-key scan, file inspection and tensor checks without yielding the main actor. Making the surrounding function `async` does not move this synchronous call off the main actor. The detached preview inspection does not protect this subsequent pass.

**Evidence:** a separate optimized (`swiftc -O`) scratch executable compiled the exact four product inspector files and used the existing complete synthetic Qwen fixture helpers. Two inspections took **1.424 s and 1.452 s**, each successfully inspecting a 708236553-byte sparse fixture; no payload inference, user model access or network occurred. Artifacts: `inspection-timing.swift`, `inspection-timing-result.txt`, and `inspection-timing` in this report’s directory. A legacy-path operation has two synchronous coordinator inspections before its runtime path, increasing the blocked interval further.

**Effect:** an ordinary supported model causes a visible UI/input freeze, and the main-actor cancel action cannot run while this validation is executing. This contradicts the intended responsive cancellation/recovery interaction and can delay recording controls during model replacement. No claim is made that a specific real audio session was lost; that would require the separate device/GUI acceptance.

**Fix:** make inspection an asynchronous off-main operation, retaining the provisioning gate and operation token across it; recheck cancellation/ownership before publishing assessment or constructing the runtime. Move the legacy initial inspection off-main too. Existing lifecycle tests inject a trivial inspector and suspend the loader for cancellation, so they do not verify inspection responsiveness. A targeted test should suspend the inspector, prove main-actor/cancel progress, and ensure its eventual result cannot commit after cancellation.

### Critical / P1

None confirmed.

### Minor / P3

No new actionable P3 raised. Existing explicitly tracked native-redirect-delegate-fixture and credential-only router-health-reset follow-ups were not reclassified as new defects without contrary evidence.

## Verification and coverage

Reviewed production changes in bounded passes: recovery/preflight/locator, lease routing/readiness, cloud endpoint/vendor/request/setting ownership, import/library/preview, Qwen metadata and pinned weight-loader contracts, Whisper graph/tokenizer/backend contracts, and relevant lifecycle/transport/graph fixtures. Read approved specs/plans. Consulted the archived previous whole-M2 findings only after the initial implementation pass; prior PASS was not used as authority.

The recorded final build/self-test remains **30.35 s / 2430 passed, 0 failed** at production `3a34a51`; `9fa57bf` is documentation closeout. This review did not independently rerun those unchanged checks. The separate exact-inspector timing compile exited 0 and both runs completed successfully. Synthetic fixture strengths are actual coordinator/configuration/restart/capture behavior and URLProtocol transport contracts; they do not establish model execution. In particular, graph mocks exercise rejection and admission, not Core ML compilation, real buffer strides or decoded speech.

A suspected short decoder-cache overflow was investigated and **rejected**: the pinned `Core/Models.swift:1420` defines `maxTokenContext = Int(448 / 2)` (224), so the accepted minimum 224 slots matches the actual decode/reset loop bound. No finding depends on an assumed 448-token loop.

Scratch verification commands (executed from the repository root; outputs/binary stayed under `/tmp`):

```sh
swiftc -O -parse-as-library Sources/flowtype/Services/Speech/LocalModelManager/ImportedASRModel.swift Sources/flowtype/Services/Speech/LocalModelManager/ASRModelInspector.swift Sources/flowtype/Services/Speech/LocalModelManager/SafetensorsManifest.swift Sources/flowtype/Services/Speech/LocalModelManager/WhisperModelInspector.swift /tmp/flowtype-m2-independent-review-20261102/inspection-timing.swift -o /tmp/flowtype-m2-independent-review-20261102/inspection-timing
/tmp/flowtype-m2-independent-review-20261102/inspection-timing
```

The result transcript is `/tmp/flowtype-m2-independent-review-20261102/inspection-timing-result.txt`; the compiler produced no diagnostics and exited 0. The two timings are successive iterations of one executable invocation, not repeated full-suite or real-model tests. The sparse synthetic model remains in the scratch `timing-model` directory for review.

## Declined to judge

- Full Whisper/Qwen model inference, per-variant 0.6B/1.7B × 4/8-bit behavior, accuracy, long-audio head/tail retention and measured memory: no authorized complete model/runtime execution in this review; mandatory real acceptance remains Pending.
- Current application GUI rendering and operating-system responsiveness under a real model switch: GUI was not exercised; the main-actor defect above is established by call isolation and exact-inspector timing, not a claimed GUI observation.
- Live SiliconFlow/OpenAI availability, optional-field support, DashScope handshake, billing and weak/offline-network service behavior: no live credentials or service requests; retain mandatory V1 Pending.
- V2–V5 cross-application delivery, clipboard protection, real-stage cancellation and microphone/Bluetooth disconnect recovery: no GUI/devices/physical actions exercised; mandatory acceptance remains Pending.
- Arbitrary Hugging Face architectures, raw PyTorch/GGUF conversion, Python execution, Parakeet/Omnilingual adapters and M3–M5 implementation: explicitly outside the approved M2 scope.
- Metadata/weight semantic equivalence or transcription quality inferred solely from a structurally valid tokenizer/tensor inventory: structural inspection cannot prove trained payload semantics; no unsupported compatibility claim is made.

## Assessment

**Ready to merge / source-complete: No — with fixes.** Two P2 defects remain: the source-package loading path does not implement the accepted file-format contract, and normal full Qwen validation blocks the main actor for a measured multi-frame interval. Fix these with focused verification before restoring a source PASS. Independently, **release/real-environment acceptance is not complete** while required full-model, service, GUI and V1–V5 cases remain Pending.
