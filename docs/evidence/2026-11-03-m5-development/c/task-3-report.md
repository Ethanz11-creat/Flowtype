# C3 source / documentation / fixture report

Status: requested source/docs/fixture portion complete; scoped source commit below. C3 task review, whole-M5 source review, final actual release and evidence archive remain separate future gates. No actual release/build/full/artifact was run in C3.

## Implementation

- Manual validator uses41 closed required leaf IDs, exposes every leaf's Pass/Fail/Pending and closed issue codes, and rejects unknown/duplicate IDs, obsolete/malformed schema, wrong top/leaf candidate identities, false parent Pass, missing Pass details, missing/escaped/linked evidence. Missing required leaves remain visible Pending. Optional aggregate-only IDs are exactlyR1–R6/V1–V5 and their declarations must match child aggregation.
- Pass requires UTC testedAt (seconds or three fractional digits), tester, structured environment(macOS/hardware/target), structured observation(actions/result/count/durationMs), exact gitSHA/sourceTree/binarySHA256/appPath, and nonempty relative evidence files within the provided manual JSON parent. R1 requires count≥10, R2≥20, other leaves≥1; durationMs>0. Structural success does not establish that an observation is truthful; the synthetic Pass fixtures are not real acceptance evidence.
- Controller API ruling implemented and documented: `ManualValidation.evaluate(data:manifest:expectedSourceIdentity:expectedAppPath:evidenceRoot:)` accepts optional manifest/source for legitimate empty Pending templates but receives expected appPath explicitly from `repo/build/FlowType.app`. Manifest has no path; report-supplied paths/evidenceRoot cannot establish expected identity. Nonempty candidate identity must match independent source/manifest/path. CI source validation does not depend on artifact availability.
- CI validator consumes only provided code-lane schema1 results, exact source SHA/tree, a GitHub Actions runURL, and same-run artifact evidence URLs. Old/local/malformed/incomplete Pass fails; absent report and valid empty Pending stay Pending. It performs no network access, remote write or remote result authentication.
- Release records optional `manualCases`/`manualIssues` alongside manualStatus/ciStatus; legacy schema1 reports without new fields decode/export correctly. Existing phase aggregation retains Fail precedence and cannot hide required Pending leaves.
- CLI `--write-manual-template FILE` writes41 Pending rows and four empty candidate strings, refuses existing files or linked parents, and triggers no validation. Actual command generated the tracked template; it contains no Pass.

## Focused validation

Compile command:

`swiftc -parse-as-library scripts/verification/BoundedProcess.swift scripts/verification/ArtifactPackaging.swift scripts/verification/VerificationReport.swift scripts/verification/ManualValidation.swift scripts/verification/VerificationSelfTests.swift scripts/verification/VerificationCLI.swift -o build/tools/flowtype-verify`

- Initial compilation exited0 (`task-3-red-compile.log`); `build/tools/flowtype-verify --self-test` exited1, **151 passed / 36 failed** on safe Pending stubs (`task-3-red.stdout/.stderr`). Failures were behavioral identity, details, unknown/duplicate, evidence, false parent, template and CI requirements.
- First GREEN compile/run exited0, **187 passed / 0 failed** (`task-3-green-compile.log`, `task-3-green.stdout/.stderr`).
- Added precise integration/backcompat checks and repeated only the changed tool suite: final compile exited0 (`task-3-final-compile.log`); final `build/tools/flowtype-verify --self-test` exited0, **193 passed / 0 failed**, stderr empty (`task-3-final.stdout/.stderr`). Coverage includes every individually omitted required leaf, explicit expected path, count minima, no-artifact empty template, CI evaluation independent of absent artifact, synthetic fully attested release aggregation, and export of a historical schema1 report lacking new manual fields. All previous C1/C2 synthetic regression fixtures remain included.
- Actual tool-only `build/tools/flowtype-verify --write-manual-template docs/evidence/2026-11-03-m5-manual-template.json` exited0 (`task-3-template.stdout/.stderr`). jq inspection confirmed schema1,41 rows, onlyPending, empty gitSHA/sourceTree/binary/appPath.
- `bash -n scripts/verify.sh scripts/export-ci-evidence.sh` passed. Scoped Markdown file-link resolution passed using existing Ruby; no dependency or linter install. `git diff --check` passed. Package.resolved remains blob `702ce34b917f9fdf9927b1b428f431125c28970c`.

No C3 product build/full, actual artifact/smoke/release, ordinary app, real user state/config/dictionary/DB/Keychain/model/cache, GUI/permissions/recording/clipboard/input, network/provider/remoteCI, Python/download/install, dependency/lock change, push/merge or large archive was performed. The native fixture driver may compile temporary independent tools and intentionally fail copied verify.sh tool compilation; it does not build the product.

## Documentation

- Product matrix overlays current M4 persistent permission/blocker recovery,380×156 card geometry, captured target/focus and real event evidence (`deliveryBlocked` versus `deliveryUncertain`) while retaining historic row IDs and M3 candidate notes. M5 dotted leaf matrix is the authoritative required release list.
- Audit and M5 ledger separate A/B/C1/C2 reviewed source, B3 historical strict/moved Metal/MLX artifact, C3 source pending review, final candidate/ten smoke Pending, remoteCI Pending and all41 real leaves Pending. Fixed B3 SHA/tree/hash checkpoint is explicitly historical, not final C.
- README packaging/verify contract now describes generated identity, standard Resources/explicit shader, strict signing, bounded lanes, safe evidence and Pending template; no longer claims build-app ignores generated identity.
- Tracked A/B/C plans and spec have explicit execution updates with preserved historical planning baselines. Completed implementation steps are checked; B raw archive, C3 final release and whole-M5 review/archive remain unchecked. Internal signature refinement rationale is recorded. New development README is an index only; no raw evidence archive was made.
- Controller's documentation accuracy pass was applied before commit after reading actual InjectionStage: initial changed/unsafe target may complete safely via clipboard; no-event cancellation remains cancelled; deliveryBlocked is a suspended failure, and genuine-event unverifiable/cancelled insertion is uncertain. Watchdog docs now promise only handshaken owned process-group control, explicitly limiting independent Foundation Process descendants; packaging marker/live-inner checks refuse unsafe recovery. These were docs-only corrections, with no product change or repeated product test.

## Remaining gates

Wait for controller's C3 and whole-M5 source review. After approval, controller may dispatch exactly one final clean release command using the explicit existing Resources shader. Without real manual/CI reports, expected release exit is2/Pending if technical stages pass; no synthetic Pass is carried into real acceptance. Later evidence archive uses only explicitly prepared safe staging and allowed synthetic records. No final candidate/report/ten-smoke success is claimed here.

## Scoped source commit

`4cdfaf42cbea1bd04a63a4803a8d103a23e0178f` — `feat: validate manual and CI acceptance evidence`.
Exactly14 source/docs/template/index files were staged, staged diff check passed, postcommit worktree status is empty, and Package.resolved blob is unchanged. This is the source/docs checkpoint before review, not the later actual-release/archive commit.
