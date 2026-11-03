# C2 implementation report

Status: implementation and local tool verification complete; scoped commit below. Remote CI remains **Pending**. Stop for controller gate.

## Changes

- Added `.github/workflows/ci.yml`: push/pull_request code gate only, contents:read, complete checkout (`fetch-depth: 0`), disabled persisted checkout credentials, macos-15 arm64, job-local preinstalled Xcode26.0.1 selection, actual OS/architecture/Swift output, and bounded `scripts/verify.sh --lane code`. No artifact lane, provider secrets, shader/toolchain installation, workflow_dispatch, or remote trigger.
- Added `VerificationCapability` shared by runner checks and fixture capability tests: macOS15+, arm64, Swift6.2+; rejects macOS14, Intel, Swift6.1, and malformed versions.
- Added `VerificationEvidence.exportAllowlisted(report:runRoot:destination:)` and `--export-evidence RUN_ROOT --output EMPTY_DIRECTORY`, which do no validation run. The exporter validates canonical owned UUID run roots, report ownership, known phase/reference shapes, per-component symlinks/escape, and an empty owned destination before writing anything. It reencodes typed selected reports, uploads only build/full/signature/check/smoke stdout/stderr and exact isolated diagnostic log names/three rotations, and omits git/source command logs, process results, configurations/defaults/DB/audio/models/production logs and unknown sibling files.
- Genuine matching Fail/report-write partial reports always take precedence over old reports, even with an older filesystem timestamp. Conflicting lane/source/artifact identity rejects export. Failed/partial runs tolerate absent permitted streams, preserving available evidence. Unknown referenced paths/phases or symlink leaves/ancestors reject before any destination write.
- CLI announces the one safe owned report path before runner execution, so late report-write errors remain discoverable. `scripts/export-ci-evidence.sh` consumes exactly that invocation's path, never globs the verification root, and invokes the export-only CLI. Actual tool compile failure has a separate exact-schema fallback that exports only the fixed bootstrap status and safe fixed stderr; raw compiler logs are excluded.
- Export runs under `always()`. Upload uses `always() && steps.evidence.outcome == 'success'` and only `build/ci-evidence/`, so rejected/nonempty destinations cannot be uploaded after export failure. No broad fallback exists. This is the safe interpretation of always collecting valid evidence after verification failures.

The helper script is a small scoped addition beyond the brief's initial file list because an uncompiled verifier cannot implement its own bootstrap export, and the workflow needs one reviewed path selector for partial-report failure cases.

## RED / GREEN evidence

All commands ran from `/Users/yiheng/pycode/flowtype-local`.

Tool compile command throughout:

`swiftc -parse-as-library scripts/verification/BoundedProcess.swift scripts/verification/ArtifactPackaging.swift scripts/verification/VerificationReport.swift scripts/verification/ManualValidation.swift scripts/verification/VerificationSelfTests.swift scripts/verification/VerificationCLI.swift -o build/tools/flowtype-verify`

- Initial compile exited0 (`task-2-red-compile.log`). Initial `build/tools/flowtype-verify --self-test` exited1: **86 passed / 7 failed**, covering missing allowlist/partial/bootstrap functionality and capability acceptance (`task-2-red.stdout/.stderr`).
- First implementation identified a fixture/platform alias issue: Foundation `standardizedFileURL` rewrites `/private/var` to `/var`, unlike POSIX realpath. The exporter now preserves literal paths for ownership comparisons; synthetic roots are canonicalized. Unexpected first implementation failures are retained in `task-2-green.stdout/.stderr`, not represented as successful evidence.
- Additional integration RED (`task-2-contract-red-compile.log`, `task-2-contract-red.stdout/.stderr`) exited1: **97 passed / 6 failed**. It specifically demonstrated stale timestamp-based partial selection, Boolean bootstrap schema coercion, partial lane conflict, and CLI late-failure path loss/helper export failure. These were corrected.
- Final compilation exited0 with empty compiler log (`task-2-final-compile.log`). Final `build/tools/flowtype-verify --self-test` exited0: **105 passed / 0 failed**, stderr empty (`task-2-final.stdout/.stderr`). This retains all C1 synthetic regression tests and adds C2 allowlist/canary/partial/capability and actual helper integrations.
- Actual integration fixtures invoke the real CLI invocation function with an injected late writer failure, then the copied actual helper/current native verifier, and assert the genuine Fail partial is exported while the stale report is absent. They also execute a copied real verify.sh with missing tool sources to cause an actual swiftc bootstrap failure, then execute the helper with no compiled tool and assert exactly `bootstrap-failure.json` and `bootstrap.stderr`. These are temporary synthetic repos; no product executable is built or run.
- `bash -n scripts/verify.sh scripts/export-ci-evidence.sh` exited0.
- `/usr/bin/ruby -rpsych -e 'Psych.parse_file(ARGV.fetch(0)); puts "workflow YAML syntax: Pass"' .github/workflows/ci.yml` exited0 using the existing native Ruby parser. No linter/package was installed. This checks syntax only, not remote CI.
- `git diff --check` passed. Package.swift/Package.resolved unchanged; lock blob remains `702ce34b917f9fdf9927b1b428f431125c28970c`.

## Workflow source review

Read the current scratch `ci-source-notes.md`, full pinned `checkout-action.yml` and `upload-artifact-action.yml`, supported runner table, and `macos-15-arm64-image.md` snapshot before authoring.

- GitHub's supported runner table identifies macos-15 as arm64 (not macos-15-intel).
- Image20261028.0489.1 documents OS15.8.2 and preinstalled `/Applications/Xcode_26.0.1.app`; default Xcode16.4 is insufficient. The workflow selects only the job-local DEVELOPER_DIR and checks it exists. Runtime runner capability checks remain binding.
- Checkout is pinned to controller-verified v4 commit `11d5960a326750d5838078e36cf38b85af677262` (node20, fetch-depth/persist-credentials supported).
- Upload-artifact is pinned to controller-verified v4 commit `ea165f8d65b6e75b540449e92b4886f43607fa02` (node20, path/if-no-files-found/include-hidden-files/retention-days supported).
- Manually reviewed every workflow step: only code validation, full checkout, read permissions, no provider secrets/download/install/cache/artifact stage, always export with successful-export-only fixed upload target. No fixed-string YAML mirror tests were added.

## Limits and next gate

RemoteCI, manual evidence, and final artifact/smoke acceptance remain Pending. No product source/build/full rerun, actual artifact validation, ordinary app, real user config/dictionary/DB/Keychain/models/cache, permissions, recording, clipboard/input, providers/network, remoteCI, Python/install/download, dependencies/lock updates, push/merge was performed. No large evidence archive or documentation commit was made; controller owns those steps.

Controller's later C3 README packaging/verify refresh reminder is retained without expanding C2.

## Commit

`66f1e78c2ea31db7290a5083abab4069df229b38` — `ci: gate code validation and whitelist evidence`.
Scoped stage contained exactly the workflow, exporter helper, and three verifier Swift files above; staged diff check passed. Postcommit worktree status is empty; no docs/archive commit.
