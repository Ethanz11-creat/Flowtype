# D4 implementation report

Base: `74e894e`. Worktree `/Users/yiheng/pycode/flowtype-local`, branch `flowtype-local`. No subagents were spawned. Implementation is limited to the requested packaging/distribution/verification files. Product Sources, dependency locks, and old 41-case schema/IDs are unchanged.

## Implemented behavior

- `FLOWTYPE_SIGNING_IDENTITY` is optional. The default keeps ad-hoc signing. An explicit identity must have the Developer ID Application identity/team form; codesign resolves and signs with that exact identity. Actual Mach-O files and nested framework/XPC/app containers are signed inside out, then the enclosing App, with `--timestamp --options runtime` in Developer ID mode. No JIT/unsigned-executable-memory entitlement is introduced. The existing packager still signs/verifies in staging, writes the manifest after signing, and only then transactionally publishes. Existing sign-failure tests cover preservation of the previous App/manifest.
- Added exact D4 schemaVersion 1 `DistributionVerificationReport` with status, candidate, optional teamID and notary IDs, hardenedRuntime/stapled/gatekeeperAccepted booleans, optional dmgSHA256, and issues. Candidate has exactly gitSHA/sourceTree/binarySHA256/appPath/optional packageSHA256. `sourceTree` is the Sources tree. Package hash always equals dmgSHA256; missing package remains nil/Pending. There is no added discriminator and no conflicting `ModelCenterCandidate` declaration.
- Added `scripts/verify-distribution.sh --app <absolute> --manifest <absolute> --dmg <absolute> --notary-evidence <absolute> --output <absolute>` and `--self-test`. Exit codes are Pass 0, Fail 1, Pending 2, usage 64. Verifier validates real manifest/binary/resources, actual codesign Developer ID/team/CDHash/runtime, both Accepted submissions, both staples and Gatekeeper App/DMG assessments. Manifest mismatch yields a Fail report before command execution. Malformed/unreadable input that cannot establish a candidate exits 1 rather than inventing identity hashes.
- Missing Developer ID, notary profile, package or evidence remains Pending. Invalid signature/runtime, rejected notary evidence, actual-byte mismatch, fresh log mismatch, signature mismatch, staple failure and Gatekeeper failure fail closed. `--self-test` injects every signing/notary/disk-image/Gatekeeper command and never invokes their real counterparts.
- Added explicit `scripts/build-dmg.sh --distribution`, which delegates to the CLI's `--distribute` operation. Default zero-argument DMG behavior is preserved. The operation requires the current clean repository App/manifest and preconfigured identity/profile, archives the already signed App, submits and saves raw notary output, staples the App, rechecks identity/resources and calls existing check-app, then creates/signs/submits/staples the DMG. It preserves submitted ZIP/DMG bytes and final hashes. It never rebuilds/re-signs the accepted App. A final DMG is atomically renamed into place only after distribution verification passes, preserving a previous final package on rejection/failure.
- Added `VerificationOptions.candidateManifest` / `--candidate-manifest <absolute>`, artifact/release lanes only. It must equal current repository `build/FlowType.manifest.json` canonically; live manifest loading validates actual App bytes. It requires clean nonshallow source, matching git SHA and Sources tree, and records internal `artifact-reuse` in place of `artifact-build`. Signature/resource checks, all ten smoke runs, source-end comparison and existing manual/CI validation remain. Release's independent code lane is unchanged. Report evidence validation accepts exactly one build/reuse phase and rejects both/neither.
- Registered the standalone D4 suite in the existing verification self-test using the existing bounded child-script pattern and strict single-positive-summary/normal-exit checks. D2 registration remains intact; no self-test argument recursion.

## Provenance and operation boundaries

`notary-evidence.json` is emitted by the explicit distribution operation, not accepted as hand-entered IDs. It contains schemaVersion, actual signingIdentity/teamID and two submission records (`acceptedOutput`, `submittedSHA256`, `finalSHA256`). The evidence directory retains `app-submitted.zip`, `dmg-submitted.dmg`, separate raw `app-submit.json` / `dmg-submit.json`, moved-app resource-check output, and command stdout/stderr.

Verification authenticates each raw Accepted submission with a fresh read-only `notarytool log <id> --keychain-profile <profile>` response, requiring matching jobId, Accepted status and submitted SHA256. It hashes retained submitted bytes itself, extracts the submitted App ZIP, mounts submitted/final DMGs read-only, validates their contained App against the current manifest and identical actual signature/CDHash, and requires submitted/final DMG signature/CDHash equality. Final App fingerprint and final DMG SHA match the recorded stapled artifacts, with hashes checked again after commands. This binds Accepted evidence to submitted bytes, current/final bytes and actual identity instead of trusting copied IDs. The profile is a reference only; no Apple password is read or printed.

Ruling: raw Accepted JSON alone is insufficient provenance; fresh Apple log SHA binding plus retained submitted packages and matching signed contents is required for Pass. Cost: real verification needs a working configured notary profile/service even if stapled artifacts are locally available; without profile it remains Pending.

Only explicit `--distribution`/`--distribute` performs signing/submission/stapling. Ordinary verification performs read-only signature/notary-log/staple/Gatekeeper checks and temporary read-only package inspection. No live Developer ID, Keychain, notarytool, signing credentials, uploading, publishing, installation or real disk-image mounting was used during implementation; every such test boundary is injected.

## TDD evidence

All compiler/test invocations ran sequentially; no tracked files were edited while they ran. Full logs are ignored in `build/D4/`.

1. `scripts/verify-distribution.sh --self-test > build/D4/RED-distribution.log 2>&1`: pending-only buildable evaluator and empty signing adapter produced **5 passed, 17 failed**, covering rejected/forged/mismatched evidence, signature/runtime/staple/Gatekeeper failures, complete Pass and nested Developer ID signing. These were behavioral assertion failures, not import/compiler failures.
2. `scripts/verify.sh --self-test > build/D4/RED-reuse.log 2>&1` exited 1: **209 passed, 7 failed**. New reuse tests observed unwanted artifact builds, no successful reuse phase, acceptance of external manifest and absent option parsing. Registered D2 remained **91 passed, 0 failed**.
3. `scripts/verify-distribution.sh --self-test > build/D4/GREEN-distribution-initial.log 2>&1` exited 0: **22 passed, 0 failed**.
4. Explicit release orchestration placeholder RED: `scripts/verify-distribution.sh --self-test > build/D4/RED-release-operation.log 2>&1` exited 1: **25 passed, 2 failed** (`release pipeline completes only accepted fixture`, `Rejected submission blocks distribution`). Implementation then exercised actual ordering/capture/publication through injected commands.
5. CLI parser placeholder RED: `scripts/verify-distribution.sh --self-test > build/D4/RED-cli.log 2>&1` exited 1: **34 passed, 2 failed** for missing explicit-mode/absolute-pair parsing. `GREEN-distribution.log` then exited 0: **36 passed, 0 failed**.
6. Self-review provenance RED: `scripts/verify-distribution.sh --self-test > build/D4/RED-package-binding.log 2>&1` exited 1: **35 passed, 2 failed** for a different submitted DMG CDHash and missing Fail report on changed binary. Implemented submitted/final DMG signature equality and moved actual-byte validation inside the report failure boundary.
7. `bash -n scripts/verify-distribution.sh scripts/build-dmg.sh scripts/verify.sh` exited 0. `scripts/verify-distribution.sh --self-test > build/D4/GREEN-distribution-final.log 2>&1` exited 0: **37 passed, 0 failed**.
8. `scripts/verify.sh --self-test > build/D4/GREEN-verification.log 2>&1` exited 0, pristine output:
   ```text
   CLI fixtures: template=2, complete=0, mismatch=1, missing/duplicate option=64
   Model center acceptance self-test: 91 passed, 0 failed
   Distribution verification self-test: 37 passed, 0 failed
   === verification self-test: 219 passed, 0 failed ===
   ```
   Reuse tests assert no artifact-build calls, matching internal reuse phase, signature/resources and ten smoke executions, external/dirty/wrong-source/wrong-hash rejection, valid export and both/neither build/reuse rejection. Original default lanes/manual/CI regressions are included.

Final packaging and raw-rejection retention results are recorded below before commit.

## Changed files

Modified `scripts/verification/ArtifactPackagingCLI.swift`, `ArtifactPackaging.swift`, `VerificationCLI.swift`, `VerificationReport.swift`, `VerificationSelfTests.swift`, `scripts/build-dmg.sh`. Created `scripts/verification/DistributionVerification.swift`, `DistributionVerificationCLI.swift`, `DistributionVerificationSelfTests.swift`, `scripts/verify-distribution.sh`.

## Self-review and remaining real acceptance

Reviewed the requested API, D2 wire compatibility/nullability, inside-out signing and unchanged staging transaction, exact candidate reuse path and clean source, unchanged old manual schema, raw notary provenance, submitted/final package binding, explicit external-operation opt-in and independent self-test registration. The self-review fixes are documented above/below.

No full product build/code/artifact/release gate was run: D3 owns the final candidate build and broad gate. No real model/service download, microphone, permissions, clipboard, user configuration, Keychain or credentials were accessed. Real Developer ID signing/notarization, clean-machine quarantined first launch/install/upgrade, signed-model loading/Metal/Keychain access, and original/new real-manual matrices remain **Pending**, not Pass. Fixture success only establishes tooling behavior. No signing account or credential was requested; no push/merge/publish occurred.

## Final focused checks and final self-review fix

9. `/usr/bin/swiftc scripts/verification/BoundedProcess.swift scripts/verification/ArtifactPackaging.swift scripts/verification/ArtifactPackagingSelfTests.swift -o build/D4/packaging-self-tests > build/D4/packaging-compile.log 2>&1` exited 0, empty compile log. `build/D4/packaging-self-tests > build/D4/GREEN-packaging.log 2>&1` exited 0: `=== packaging self-test: 128 passed, 0 failed ===`. This includes failed signing/build preservation of the previous candidate and manifest plus resource/journal recovery.
10. Final raw-rejection retention RED: modified the injected notary rejection to return exit 1 and asserted named raw evidence retention. `scripts/verify-distribution.sh --self-test > build/D4/RED-rejection-retention.log 2>&1` exited 1: `FAIL: nonzero notary rejection preserves named raw response`; **37 passed, 1 failed**. Previously the generic live command logs retained output, but the named submission file was skipped on nonzero exit. The submit boundary now saves the raw command response before checking its exit code/Accepted status. `scripts/verify-distribution.sh --self-test > build/D4/GREEN-rejection-retention.log 2>&1` exited 0: **38 passed, 0 failed**, warning-free. This was the only production change after the combined 219-check GREEN; the affected distribution suite was rerun directly rather than unnecessarily repeating unrelated suites.
11. `ruby scripts/verification/ArtifactPackagingCLIInputTests.rb "$PWD/build/D4" > build/D4/GREEN-packaging-cli.log 2>&1` exited 0: **12 passed, 0 failed**. Actual CLI missing/empty/explicit shader and extra-argument handling stays unchanged, with no user-cache enumeration or published candidate.
12. `git diff --check` exited 0. `git diff --name-only -- Sources Package.resolved` was empty. Only the ten declared D4 files are staged for the task commit. No unresolved self-review finding; real signed-distribution and manual acceptance remain Pending for the reasons above.

Status: **DONE** (implementation/fixture verification complete; actual release not performed).

Commit: `cb5e2a4 feat: verify signed and notarized FlowType distribution` (10 explicit task files, 559 insertions / 25 deletions). Post-commit `git status --short` was empty. Full report and logs remain in the ignored task workspace / `build/D4/` for controller review.

## Fix round 1 — I1 publication postconditions, I2 stale successful output, minor nil-package handoff

Base `cb5e2a4`. Read the full controller review; both Important findings were valid. Earlier completion statements about preserving final packages across all failures and fail-closed output were incomplete and are superseded by this fix.

### Changes

- **I1:** `DistributionVerification.distribute` now returns its already validated report and accepts two injected boundaries: `beforePublish` for final source/cancellation validation, and `publishReport` for durable report persistence. The CLI performs its final clean `packagingSnapshot`/identity comparison and cancellation check before publication, and no longer runs a second full evaluation after publication. The staged DMG is fully evaluated first. Before atomic replacement, an existing regular final DMG is retained as a hard link under the owned evidence directory; it remains until report persistence succeeds. A report-writing error atomically restores the old package (or removes the new package if none existed). Backup cleanup after successful commit is best-effort and cannot turn a committed success into a late failure.
- **I2:** after parsing and validating the requested output location, the CLI atomically writes an unbound Fail marker before any candidate canonicalization, manifest decode, package hash, source preflight, cancellation handler or external command work. A later thrown failure replaces that marker with a candidate-bound schema-1 Fail report when the existing App/manifest can establish actual identity. Unreadable packages honestly have nil package/dmg hash; malformed manifest/missing App keeps the unbound marker with no invented candidate/hash fields. D2 cannot decode that marker as a successful distribution attestation. If persisting a failure itself fails, the selected output is removed rather than intentionally retaining a previous success. Invalid output destinations are refused before selection. Errors after output selection exit 1; malformed arguments still exit 64.
- **Minor handoff:** the standalone D4 compiler includes the existing `ModelCenterAcceptance.swift`, and a fixture serializes a real producer Pending report with nil package/dmg hashes then calls D2's real public manifest/distribution evaluator. Aggregate result is Pending. No distribution/ledger wire fields or schema versions changed; no consumer validation was copied into tests.

### RED → GREEN evidence

All tests/compilers ran sequentially. No tracked files were edited while a test/compiler was running. New CLI fixtures invoke the actual compiled D4 `@main` using `BoundedProcess`. They supply isolated synthetic files and fail before any real codesign, profile, notary, mount or network command. The preflight case uses only a literal nonexistent fixture profile and is rejected by the current-repository path preflight before credential access.

1. `scripts/verify-distribution.sh --self-test > build/D4/fix1-RED.log 2>&1` exited 1 with **47 passed, 9 failed**. Relevant output:
   ```text
   FAIL: failure preserves previous final package: source-change
   FAIL: failure preserves previous final package: cancelled
   FAIL: failure preserves previous final package: report-write
   FAIL: actual CLI failure invalidates previous Pass: package-read
   FAIL: actual CLI failure invalidates previous Pass: malformed-manifest
   FAIL: unknown candidate failure invents no hashes: malformed-manifest
   FAIL: actual CLI failure invalidates previous Pass: app-path
   FAIL: unknown candidate failure invents no hashes: app-path
   FAIL: actual CLI failure invalidates previous Pass: preflight
   Distribution verification self-test: 47 passed, 9 failed
   ```
   The new injected completion callbacks were first connected after the old rename to reproduce the actual publication bug. A late Gatekeeper-evaluation failure fixture additionally verifies no publication on the final verification failure. Existing early-rejection behavior remains covered.
2. The initial GREEN compilation exposed Swift's throwing `||` autoclosure syntax; moved `try` to cover the whole guard expression. This was an intermediate compile error, not claimed as a business RED. Re-ran the same focused command after correction.
3. `scripts/verify-distribution.sh --self-test > build/D4/fix1-GREEN.log 2>&1` exited 0: **Distribution verification self-test: 56 passed, 0 failed**, no warnings. Coverage includes prior DMG preservation on source change, cancellation, late evaluation and report-write failure; actual CLI replacement of pre-existing Pass on unreadable package directory, malformed manifest, invalid App path and distribution preflight; honest candidate retention where available; absent fabricated identity otherwise; and the real nil-package producer/D2-consumer roundtrip.
4. `bash -n scripts/verify-distribution.sh scripts/verify.sh` exited 0. The relevant combined verification self-test was then run once; final result and fix commit recorded below.

### Scope and review

Changed only `DistributionVerification.swift`, `DistributionVerificationCLI.swift`, `DistributionVerificationSelfTests.swift` and `scripts/verify-distribution.sh`. Reused existing manifest validation, report wire, command injection, bounded child invocation and D2 consumer. No packaging signing behavior, product source, dependency lock, old manual schema/IDs or default verification lane changed. No full product/code/artifact/release gate or real credential/signing/notary/model/service/user-state action was performed. Actual signed distribution and manual acceptance remain Pending. Self-review found no remaining issue in the two corrected boundaries.

Final fix-round verification: `scripts/verify.sh --self-test > build/D4/fix1-GREEN-verification.log 2>&1` exited 0, warning-free:

```text
CLI fixtures: template=2, complete=0, mismatch=1, missing/duplicate option=64
Model center acceptance self-test: 91 passed, 0 failed
Distribution verification self-test: 56 passed, 0 failed
=== verification self-test: 219 passed, 0 failed ===
```

`git diff --check` exited 0. Exactly the four fix-round files listed above were modified. Status: **DONE**; I1, I2 and the minor nil-package handoff fixture are addressed.

Fix round 1 commit: `94283b7 fix: preserve distribution artifacts and invalidate stale reports`. Post-commit `git status --short` was empty. Logs are retained under ignored `build/D4/fix1-*.log`.
