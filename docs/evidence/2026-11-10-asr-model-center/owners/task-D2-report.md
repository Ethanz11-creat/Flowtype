# D2 implementation report

Status: DONE. Base f5dcd8d1a3ffbf746d8fc8a5f5ce1c655cff5e29; task-scoped commit recorded below.

## Implementation

Added separate `flowtype.model-center-acceptance` schemaVersion 1 ledger, exact fixed 30 H IDs, pending-only template, standalone Swift validator/CLI/self-tests and shell entrypoint. The original 41-case ManualCaseID/validator/schema and existing verification CLI remain untouched and independently required. Product Sources and Package.resolved are unchanged. No registration in the original runner is needed: this gate has its own `--self-test`, and the original runner was exercised independently.

`ModelCenterAcceptance.evaluate(report:candidate:) throws -> VerificationStatus` checks complete ID set, uniqueness, known schema/status/types/keys, matching aggregate status, document and row identities, mandatory real manual Pass attestations, tester/date/hardware/macOS/model-or-service-version/actions/observation, and existing nonempty evidence files under the ledger directory without traversal or symlinks. Recognition cases require realRecognition; accessibility requires realAccessibility; configurationValid/metadata/fixture/offscreen never constitute Pass. Structural validation cannot authenticate a human's prose or the visual content of an evidence file.

The public overload/CLI requires report + manifest + distribution-report. It validates actual App bytes/resources against the provided existing artifact manifest via `validateManifest`, binds manifest source/binary to the D4 candidate/app path, and consumes the agreed declared D4 status/check fields without executing signing, service, network or permission actions. Missing/malformed files and mismatches fail closed. Exit codes: Pass 0, Fail 1, Pending 2, usage 64. Template writer refuses overwrite.

## TDD and verification evidence

All commands ran sequentially; no edits occurred while tests ran. Logs are ignored under `build/D2/`; synthetic test roots were `build/D2-selftest-<UUID>` and removed after tests.

1. RED: `bash -n scripts/verify-model-center.sh` -> 0; `scripts/verify-model-center.sh --self-test > build/D2/RED.log 2>&1` -> 1. The CLI was buildable; the evaluator was a `.pending` placeholder. Output: `Model center acceptance self-test: 2 passed, 46 failed`, including complete-attestations Pass, duplicate/missing/unknown cases and candidate mismatches. These were business assertion failures, not compiler/import errors.
2. RED public-boundary extension: `scripts/verify-model-center.sh --self-test > build/D2/RED-public.log 2>&1` -> 1, `4 passed, 61 failed`; missing D4 Pass fields, package mismatch, failed distribution and changed binary all failed expected assertions against the placeholder.
3. GREEN: `scripts/verify-model-center.sh --self-test > build/D2/GREEN.log 2>&1` -> 0, `65 passed, 0 failed`. A forced-cast warning in test code was corrected; subsequent logs are warning-free.
4. Actual CLI fixture coverage added: `scripts/verify-model-center.sh --self-test > build/D2/GREEN-cli.log 2>&1` -> 0, `71 passed, 0 failed`.
5. Final focused verification: `bash -n scripts/verify-model-center.sh` -> 0; `scripts/verify-model-center.sh --self-test > build/D2/GREEN-final.log 2>&1` -> 0, pristine output:
   ```text
   CLI fixtures: template=2, complete=0, mismatch=1, missing/duplicate option=64
   Model center acceptance self-test: 81 passed, 0 failed
   ```
   These are actual child invocations of the compiled CLI against a synthetic App/manifest and declared synthetic D4 report, not mocked exit values. Additional tests cover malformed JSON/types, unknown fields, explicit Fail and partial Pending.
6. `scripts/verify-model-center.sh --write-template docs/superpowers/validation/model-center-acceptance-v1.template.json` -> 0, `Model center template: 30 Pending`.
7. `scripts/verify.sh --self-test > build/D2/legacy-selftest.log 2>&1` -> 0, `=== verification self-test: 193 passed, 0 failed ===`.
8. Python stdlib parsed schema/template, checked 30 unique IDs, matching schema/template ID sequence, all rows exactly Pending and schema discriminator/version -> `Schema/template JSON and fixed 30-ID consistency: Pass`. No external JSON Schema engine was installed or downloaded. `git diff --cached --check` -> 0.

No full FlowType/code/artifact gate was run: those belong to D3 final phase per controller. These synthetic validator tests are not real H1-H8 acceptance.

## CLI examples

```bash
scripts/verify-model-center.sh --write-template build/model-center-manual.json
scripts/verify-model-center.sh --self-test
scripts/verify-model-center.sh --report build/model-center-manual.json --manifest build/FlowType.manifest.json --distribution-report build/distribution-report.json
```

The last command exits 2 with the untouched Pending template and matching valid Pending D4 candidate; exits 1 with a mismatching candidate or malformed report; cannot exit 0 until all 30 real rows and matching complete D4 Pass are present. The self-test exercises these exact argument forms with isolated paths and checks 0/1/2/64.

## Exact D4 handoff / controller ruling

D4 wire fields consumed (schemaVersion 1; no new distribution discriminator):

```text
schemaVersion: Int (=1)
status: "Pass" | "Fail" | "Pending"
candidate: { gitSHA:String, sourceTree:String, binarySHA256:String,
             appPath:String, packageSHA256:String? }
teamID: String?
hardenedRuntime: Bool
appNotarizationID: String?
dmgNotarizationID: String?
stapled: Bool
gatekeeperAccepted: Bool
dmgSHA256: String?
issues: [String]
```

`sourceTree` means Sources tree, not repository tree. Candidate packageSHA256 must equal dmgSHA256 (including nil==nil for undistributed Pending). SHA fields use lowercase 40/64 hex; appPath is normalized absolute `.app` path. D4 candidate appPath points to the App verified against the provided manifest. D4 owns real distribution-check execution and report provenance; D2 does not invent new signing/notary truth.

Controller explicitly ruled that missing Developer ID/DMG conditions may produce honest Pending with nil package. The optional package can be omitted or null in Pending candidate fields. Blank template candidate is accepted only as an unbound Pending ledger. Any claimed Pass row/report without final package fails. D4 Pass additionally requires nonempty team/notary IDs, true hardenedRuntime/stapled/gatekeeperAccepted and empty issues. D4 Pending blocks aggregate Pass; D4 Fail or identity mismatch fails the aggregate. Optional team/notary/hash fields decode null or absence; the required boolean/status/issues fields remain typed.

D4 can reuse `ModelCenterCandidate` by compiling this source, or encode the same five-field wire shape. It must not define a conflicting same-module type. No external distribution implementation was added here.

## Changed files / self-review / limits

Created `scripts/verification/ModelCenterAcceptance.swift`, `ModelCenterAcceptanceCLI.swift`, `ModelCenterAcceptanceSelfTests.swift`, `scripts/verify-model-center.sh`, `docs/superpowers/validation/model-center-acceptance-v1.schema.json`, `model-center-acceptance-v1.template.json`; updated C4 acceptance markdown with command/evidence/schema rules.

Reviewed staged changes against exact IDs, candidate/hash binding, nullability, status aggregation, evidence file restrictions, schema/template alignment, independent legacy gate and scope. No unresolved implementation findings. No credentials, user state, actual models, services, microphone, permissions, network, signing, installs, pushes or release actions were used. Real 30-case manual acceptance, original 41-case manual acceptance, remote CI and Developer ID/notarized distribution remain Pending and require D3/D4 evidence.

Commit: `c6edbe5 feat: gate model center acceptance on candidate-bound evidence`. Post-commit `git status --short` was empty. Full RED/GREEN command logs remain in ignored `build/D2/`.

## Fix round 1 — I1 registration and M1 macOS lexical consistency

Base: `c6edbe5`. Both review findings addressed. The earlier statement that old-runner registration was unnecessary was incorrect and is superseded by this fix.

- I1: `VerificationSelfTests.run` now registers a real standalone `scripts/verify-model-center.sh --self-test` invocation through `BoundedProcess`, with owned process-group cleanup, a 120-second deadline and isolated output logs. The old CLI never directly executes the new suite's CLI fixtures under its own executable. The child script compiles/runs the new CLI only; it does not invoke the old CLI, so there is no old→new→old recursion or duplicated ledger test logic.
- A child succeeds only on normal exit 0 and exactly one summary matching `Model center acceptance self-test: <positive count> passed, 0 failed`. Nonzero exit, missing summary, zero tests, reported failures and duplicate summaries return false and cause the registered outer assertion to fail. Six real isolated shell subprocess fixtures exercise that boundary, including valid-summary/nonzero-exit failure propagation. Their logs live in the old suite's owned `D2-registration-fixtures` temporary directory; it is removed with the successful outer suite.
- M1: the ledger runtime and published schema now use the same explicit macOS lexical pattern, with no trimming or leading-zero-major normalization. Both accept version 15+ with zero, one or two numeric minor components; both reject whitespace (including a trailing newline), `015.0`, prefixes, prerelease text and missing components. The end assertion uses `(?![\s\S])` so a regex `$` cannot accidentally accept a final newline. The original CI capability helper is unchanged.

RED evidence:

```text
bash -n scripts/verify.sh scripts/verify-model-center.sh -> 0
scripts/verify-model-center.sh --self-test > build/D2/fix1-RED-macOS.log 2>&1 -> 1
FAIL: malformed macOS " 15.0 " fails
FAIL: malformed macOS "015.0" fails
FAIL: malformed macOS "15.0\n" fails
Model center acceptance self-test: 88 passed, 3 failed

scripts/verify.sh --self-test > build/D2/fix1-RED-registration.log 2>&1 -> 1
FAIL: D2 registration valid propagates child result
FAIL: registered standalone model center CLI self-test passes
=== verification self-test: 198 passed, 2 failed ===
```

The registration helper was a buildable false-returning placeholder for RED, proving the newly registered actual-suite assertion and positive subprocess boundary fixture detect missing integration. Negative fixtures then prove an always-success/exit-ignored implementation cannot pass GREEN.

GREEN evidence (sequential; no edits during execution):

```text
bash -n scripts/verify.sh scripts/verify-model-center.sh -> 0
scripts/verify-model-center.sh --self-test > build/D2/fix1-GREEN-standalone.log 2>&1 -> 0
CLI fixtures: template=2, complete=0, mismatch=1, missing/duplicate option=64
Model center acceptance self-test: 91 passed, 0 failed

scripts/verify.sh --self-test > build/D2/fix1-GREEN-combined.log 2>&1 -> 0
CLI fixtures: template=2, complete=0, mismatch=1, missing/duplicate option=64
Model center acceptance self-test: 91 passed, 0 failed
=== verification self-test: 200 passed, 0 failed ===
```

The outer 200 checks are the original 193 plus six child-result-contract checks and one real standalone-suite registration check; the nested 91 D2 checks remain visible as their own summary rather than being mislabeled as outer assertions. Output is warning-free. A Python stdlib check applied the published schema's macOS pattern to 11 representative accepted/rejected strings: 11/11 passed. `git diff --check` was clean.

Changed only `VerificationSelfTests.swift`, `ModelCenterAcceptance.swift`, `ModelCenterAcceptanceSelfTests.swift` and the new model-center schema. Standalone CLI and old 41-case schema/ManualCaseIDs remain intact. Self-review found no remaining issue. No full FlowType gate, product source/dependency change, service, network, credential, permission or real-manual action was performed; real acceptance/distribution remains Pending.

Fix round 1 commit: `74e894e fix: register model center acceptance regression coverage`. Post-commit `git status --short` was empty.
