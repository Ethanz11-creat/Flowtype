# Task B1 report — pinned Hugging Face resolver

Status: DONE. Base: `69691c0`. Implementation frozen after required GREEN; subsequent edits only interface documentation and this evidence report.

## Implemented

- Added exact cross-task `HFRepositorySelection`, `HFFileDigest`, `HFPlannedFile`, `HFRepositoryFile`, and `HFResolvedRepository` fields/conformances.
- Input parsing supports model repo IDs and official HTTPS links. tree/blob suffixes require structured explicit selection; slash revisions are encoded as one API segment. Rejects unsupported schemes/origins, dataset/space routes, credentials/query/fragment, NUL, path traversal, encoded slash and nested percent encoding.
- `HFRepositoryClient` actor queries the model revision endpoint once, validates/fixes a 40-hex commit, and enumerates all recursive tree pages using that commit. Same-origin pinned-path pagination only; cursor/URL loops, oversized pages/files, conflicting duplicates, absent metadata/digests, and Int64 byte-sum overflow fail explicitly. Missing pipeline_tag is accepted.
- Metadata GETs are bounded while streaming; default response cap 16MiB, per-resolve cumulative preflight cap 32MiB. Low-only injected limits let byte-boundary fixtures remain small. Files are checked against the resolved manifest and validated by size + Git blob SHA1 header or LFS SHA256.
- Explicit `asr.hf.official` credential reference only; mirror/custom endpoints stay anonymous. The independent HF redirect policy permits at most five HTTPS/no-userinfo hops, strips bearer outside official origin, never restores it after a cross-origin hop, and removes forwarded cookies. Audio transport policy is unchanged.
- Registered `HFInstallSelfTests.run(_:)` in both `--hf-install-only` and the full runner.

## API handoff / approved ruling

Controller approved immutable `HFResolvedRepository.resolutionContextID: UUID?` (default nil for constructed fixtures). Each successful resolve gets a unique context stored by the creating client, binding source+commit+endpoint+credential ID+budget. The required readMetadata signature cannot otherwise distinguish identical repo/commit results resolved anonymously versus authenticated. Tokens are never stored in returned metadata or install-plan types. Unknown/forged contexts cannot read metadata. Client lifecycle should follow a preview so contexts release at preview end. B2 must separately aggregate the 32MiB budget across model+tokenizer repositories. Spec and B plan now document this contract.

Public construction/call forms:

```swift
HFRepositoryInput.parse(input, revision: revision, subdirectory: subdirectory)
HFRepositoryClient(downloadEndpoint: endpoint, session: injectedSession,
                   credentialStore: injectedStore, metadataLimits: .init())
try await client.resolve(selection, credentialID: "asr.hf.official")
try await client.readMetadata(file: file, repository: resolved)
```

## TDD evidence

Sequential commands, no competing build/test processes:

RED:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-red-build.log 2>&1
# exit 0; Build complete! (31.72s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-red-selftest.log 2>&1
# exit 1; === HF install self-test: 43 passed, 44 failed ===
```

The compiling interface stubs deliberately rejected valid input and all resolutions. Expected failures included valid repository input, structured slash-revision selection, pinned pagination, HTTP status/limit classification, credential scoping, metadata verification, and redirect policy. Relevant actual RED output:

```text
✗ FAIL: pinned pagination unexpectedly failed: invalidMetadata
✗ FAIL: metadata failure classification — got Optional(FlowType.HFRepositoryError.invalidMetadata), want Optional(FlowType.HFRepositoryError.totalSizeOverflow)
✗ FAIL: HF credential namespace enforced — got Optional(FlowType.HFRepositoryError.invalidMetadata), want Optional(FlowType.HFRepositoryError.invalidCredential)
✗ FAIL: streaming body cap enforced before JSON decoding — got Optional(FlowType.HFRepositoryError.invalidMetadata), want Optional(FlowType.HFRepositoryError.byteLimit)
=== HF install self-test: 43 passed, 44 failed ===
```

GREEN:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-green-build.log 2>&1
# exit 0; Build complete! (36.27s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-green-selftest.log 2>&1
# exit 0
# === FlowType --self-test ===
# === HF install self-test: 102 passed, 0 failed ===
git diff --cached --check
# exit 0; no output
```

Coverage includes repo/URL parsing; explicit slash revision; two pages/seven files pinned to commit A; exact URL revision routes; omitted pipeline_tag; Git/LFS metadata digest distinction; HFPlannedFile Codable roundtrip; 401/403/404/503; invalid commit; advertised >16MiB; streamed lower-cap overflow; foreign/moving-revision Link; cursor loops; 1001-entry page; 10001 files; Int64 overflow; duplicate conflict; missing size/digest; unsafe tree paths; explicit-only auth; mirror anonymity; two identical repo results with separate auth contexts; forged file rejection; size/digest verification; independent/cumulative budgets; HTTPS redirect bearer stripping/hop bounds.

## Files changed

- Sources/flowtype/Services/Speech/ModelInstallation/HFRepositorySelection.swift
- Sources/flowtype/Services/Speech/ModelInstallation/HFRepositoryMetadata.swift
- Sources/flowtype/Services/Speech/ModelInstallation/HFRepositoryClient.swift
- Sources/flowtype/Testing/HFRepositorySelfTests.swift
- Sources/flowtype/Testing/HFInstallSelfTests.swift
- Sources/flowtype/Testing/SelfTest.swift
- Sources/flowtype/App/RuntimeEnvironment.swift
- docs/superpowers/specs/2026-11-09-hf-model-installation-design.md
- docs/superpowers/plans/2026-11-09-asr-model-center-b-hf-installation.md

## Self-review and limits

Read staged diff for all nine files. Checked exact shared types, actor isolation, cumulative byte accounting across reentrant requests, path-segment encoding, pinned pagination restrictions, token origin/namespace, immutable per-result context, membership checks and hash semantics. No unresolved correctness findings from self-review. Build/test output has no warnings or failures.

No full suite (explicitly deferred to B6). No real-network claim: network boundary uses injected URLProtocol; redirect classification exercises the same method the URLSession delegate invokes. No real token, Keychain access, global Hub cache, weights, actual model installation, microphone, clipboard, user configuration or permission writes. No new dependency or Package.resolved changes. Live transport, native compatibility and installation validation remain subsequent tasks/acceptance work.

Commit: `3fb459b feat: resolve pinned Hugging Face model repositories`. Post-commit `git status --short` produced no output (clean worktree).

## Review fix round 1 — blob files were treated as directories

Review finding: Important — a confirmed `blob/main/config.json` selected `config.json` as a tree directory and requested a nonexistent `/tree/<commit>/config.json`. The parser had shared tree/blob remainder handling and the original tests did not exercise blob input through the resolver.

Implemented the approved fix:

- `HFRepositorySelection` adds optional `referencedFilePath: String?` with a default-nil explicit initializer; existing three-argument callers and legacy Codable records remain compatible. This is nonsensitive source-file intent, suitable for later install-plan source records.
- Confirmed blob input sets the parent directory as `subdirectory` (root file => nil), retains the full repo-relative file path, and requires any supplied subdirectory to match the parent. Blob links still require an explicit revision; slash boundaries are never guessed. A blob revision without a file suffix is invalid.
- Resolver validates the file path and exact parent relation before querying metadata; it enumerates the complete parent subtree at the frozen commit, then requires the referenced file to exist in the manifest. Missing targets produce `.fileNotInRepository`. It does not silently accept nonexistent blob files or query files as tree directories.
- Updated the B design schema/behavior and B1 plan interface for downstream B2.

Exact sequential RED commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-fix1-red-build.log 2>&1
# exit 0; Build complete! (39.56s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-fix1-red-selftest.log 2>&1
# exit 1; === HF install self-test: 105 passed, 13 failed ===
```

Relevant RED output:

```text
✗ FAIL: blob: containing directory selected — got Optional("config.json"), want nil
✗ FAIL: blob: referenced file identity survives Codable selection — got nil, want Optional("config.json")
✗ FAIL: blob parse-to-resolve unexpectedly failed: notFound
✗ FAIL: blob parse-to-resolve unexpectedly failed: conflictingSelection
✗ FAIL: blob: nonexistent referenced file rejected
✗ FAIL: blob: forged file outside selected parent rejected
✗ FAIL: blob: file suffix required
=== HF install self-test: 105 passed, 13 failed ===
```

The failures occurred against the original implementation before production edits, reproducing root-file invalid tree routing, nested-file parent conflicts, dropped source-file identity, missing target acceptance and absent parent-consistency validation.

Exact sequential GREEN commands:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-fix1-green-build.log 2>&1
# exit 0; Build complete! (31.12s)
swift run --skip-build FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/task-B1-fix1-green-selftest.log 2>&1
# exit 0
# === FlowType --self-test ===
# === HF install self-test: 132 passed, 0 failed ===
git diff --check
# exit 0; no output
```

Added integrated injected-URLProtocol cases for root `config.json`, `variant/config.json`, and `refs/pr/12` + `variant/nested/config.json`; they assert exact pinned tree paths, complete sibling manifests, encoded slash revision, source-file Codable identity, missing-file rejection, explicit conflicting directories, legacy decoding, forged parent mismatch and missing file suffix. No live metadata/weights requests, global cache/credential access or full suite (deferred to B6).

Self-review: read all five changed-file diffs. Confirmed tree behavior is unchanged, optional Codable compatibility/defaulted initializer preserve B2 callers, referenced-file checks run before successful context publication, and path/commit/auth/budget invariants remain intact. No remaining finding or concern. Code frozen after GREEN.

Fix commit: `0a26778 fix: resolve Hugging Face blob links through parent directories`. Post-commit worktree clean (`git status --short` empty).
