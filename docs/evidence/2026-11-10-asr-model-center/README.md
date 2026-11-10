# ASR model center technical candidate — 2026-11-10

**Technical candidate Pass; release Pending.** The final code lane passes 28,335 assertions with zero failures. Artifact validation passes all 22 phases, including actual ad-hoc signature/resource checks and 10 isolated smokes. The release gate reuses the same App (no rebuild or re-sign), passes all 24 technical phases and another required 10 smokes, then exits **2 / Pending** because manual and remote CI remain Pending. D4 distribution and D2 model-center gates each exit **2 / Pending** against the actual App. No unexpected gate failure occurred.

| Identity | Exact value |
| --- | --- |
| Executable candidate code commit | `d43a603c13b61b21de7cac4b44c51ceb54404a23` |
| Sources tree | `40f3b4b1c763057f70810596b0eae02b7035c728` |
| Scripts tree | `95057298acb707b433912b0652c406a7865f3e6c` |
| Ad-hoc executable SHA256 | `1c4efb28993f4dad954aff750ea9a1c8f7271615796218e68af41712b4d48854` |
| Artifact manifest SHA256 | `ccce5d0497691a672c1ad4d9c6d8ebcea41fd224e80ad1c3430583f91607475f` |
| Used Metal shader SHA256 | `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f` |
| Package.resolved SHA256 | `b37d08e8803698551e02714fd4d747025077ba6970e83856a02ebe0526838a37` |
| App path at execution | `/Users/yiheng/pycode/flowtype-local/build/FlowType.app` |
| Final distribution package | Pending; no DMG was produced or represented as accepted |

The explicitly supplied shader was physically rehashed and copied from the known existing App resource to owned ignored `build/D3/default.metallib` before packaging replaced the App. No cache search was used. All actual gate invocations explicitly unset `FLOWTYPE_SIGNING_IDENTITY` and `FLOWTYPE_NOTARY_PROFILE`, without inspecting their values. Packaging used its default ad-hoc signing. The candidate manifest and executable hashes were compared before and after release reuse and remained identical; all 17 recorded resource hashes also match actual bytes.

## Evidence and review

- [Gate statuses/counts](gate-summary.json), [exact commands, exits, raw paths and SHA256](commands.json), [candidate identity](candidate-identity.json), [artifact manifest](reports/FlowType.manifest.json).
- Actual [code report](reports/code-report.json), [artifact report](reports/artifact-report.json), [release report](reports/release-report.json), [D4 distribution report](reports/distribution-report.json). Their relative raw-evidence paths refer to their original ignored run directory, recorded in commands.json; raw logs/App are not embedded here.
- [41-case mainline ledger](reports/manual-mainline.json), [30-case model-center ledger](reports/manual-model-center.json), [remote CI not-run ledger](reports/remote-code.json). Every manual row remains Pending, without fabricated tester/date/actions/observation/real-recognition assertions. Only the available technical identity is bound; package is null for undistributed Pending.
- [Research → owner → evidence coverage](coverage.md); [all 52 controller rulings, verbatim and ordered](rulings.md), including wrong-cost wording and final external items 1–8.
- Final whole-branch [review](reviews/final-review.md) identified Important I1 service-expiry admission and Minor M1 eager draft credential lookup. The [one fix wave](reviews/final-fix-report.md) was committed as `d43a603`; the [scoped rereview](reviews/final-rereview.md) confirms both addressed with no new breakage. Those three reports are archived byte-for-byte. This evidence task did not repeat that review.

DashScope strict actor-internal cleanup joining remains a documented lifecycle-proof limitation: current terminal/cancellation/ownership paths showed no reproduced late-output/stale-selection/additional-audio consequence. It is not claimed to be proven by injected session fixtures. The historical captured-mutation warning at HFInstallTransactionSelfTests.swift:169 remains a recorded baseline; incremental build silence does not prove a clean warning-free rebuild.

Historical [CI run 41672136709](https://github.com/Ethanz11-creat/Flowtype/actions/runs/41672136709) remains **failure**, 25,919/1, in its [unchanged D1 archive](../2026-11-09-asr-model-center/d1-historical-ci.json). Local timer ownership/liveness fixes and this candidate's code Pass do not change that historical result. No new remote run was requested or executed.

## Remaining release work

These are explicit blockers, including all eight external-evidence items declined by final review. No item was set aside solely as outside the plan/specification.

1. Establish the final Developer ID signed/stapled App and final DMG on a clean checkout of the chosen code commit, with preconfigured release identity/profile and explicit authority for actual signing/submission. Follow D4's [producer/provenance contract](owners/task-D4-report.md). Retain submitted ZIP/DMG bytes, original Apple responses, fresh Apple notary-log SHA binding, signature/CDHash and final hashes; perform clean-machine quarantine install/upgrade, resources/Metal and Keychain checks. Missing DMG paths in this run were deliberately nonexistent and produced honest Pending. No notarytool, upload, DMG mounting, stapling or Gatekeeper action was reached by the ordinary verifier after detecting ad-hoc signing.
2. Run artifact `--candidate-manifest` against that exact final signed App in the clean candidate checkout, including all resources and ten smokes. Signing or changing any binary/resource/package invalidates this ad-hoc identity for manual acceptance. Generate fresh ledgers; perform all 41 original R/V cases and all 30 H1–H8 cases against the final identity. Do not change hashes in old Pass rows to recycle observations.
3. Complete actual cloud recognition/model/region/errors (H5), native Qwen both scales and 4/8-bit plus Whisper tiny/base multilingual/offline/>30s first-last output (H3), and the three actual local servers with disconnect/cancel/authentication (H4). Record model variant/source commit, exact native engine version, server installed source commit/version, actual actions/observations and nonempty evidence. Research versions are references, not claims of installed/tested versions.
4. Complete real HF authorized/variant/multi-source transfer, offline/restart/resume/corruption/disk conditions (H1/H2), in-flight switching/cancel/draining/deletion and real Keychain recovery (H6), three actual window sizes/keyboard/VoiceOver/reduced motion (H7), clean user and old configuration upgrade (H8). Original R1–R6 and V1–V5 include actual 10 launches, 20 sessions, permission recovery, TextEdit/VSCode/Chrome/Terminal/Cursor delivery/focus, clipboard formats/concurrent copy, phase cancellations and microphone unplug/Bluetooth recovery. Domain fixtures and offscreen previews cannot satisfy these cases.
5. After separately authorized push/remote CI, obtain an actual successful code run for the exact candidate git SHA and Sources tree. Replace the not-run CI ledger only with that run's URL and artifact URLs, preserving prior failed history. Actual runner/compatibility remains unverified.
6. Re-run release reuse, D4 distribution and D2 model-center gates with the complete final ledgers/evidence. All must return Pass (0), including D4 team/runtime/two Apple acceptances/staples/Gatekeeper/byte provenance and both manual schemas. Only then assess formal release readiness. Current exit 2 is an acceptance blocker, not a successful release.

Commands for the eventual complete candidate are the same public forms recorded in [commands.json](commands.json); use the actual final paths and ledgers. The [acceptance document](../../superpowers/validation/2026-11-09-asr-model-center-acceptance.md) specifies required H attestations; the [legacy manual validator](../../../scripts/verification/ManualValidation.swift) specifies the independent 41-row contract.

## Code candidate versus archive commit

This archive's docs-only commit necessarily advances HEAD. The executable/reports remain bound to `d43a603c13b61b21de7cac4b44c51ceb54404a23`, never to the archive commit. Identify the archive commit using `git log -1 --format=%H -- docs/evidence/2026-11-10-asr-model-center/README.md`; inspect its range from the recorded candidate with `git diff --name-only d43a603c13b61b21de7cac4b44c51ceb54404a23 <archive-commit>`. Only documentation/evidence paths are permitted. Check `git diff --exit-code d43a603c13b61b21de7cac4b44c51ceb54404a23 <archive-commit> -- Sources scripts Package.swift Package.resolved` and compare `<archive-commit>:Sources` / `:scripts` with the recorded trees. No rebuild is needed to archive documentation. To rerun a gate requiring exact clean source identity, use a clean checkout of the code candidate and its exact App/manifest; running it at a later docs HEAD must not relabel the prior candidate.

[Archive SHA256 inventory](archive-sha256.json) covers each tracked artifact except the inventory itself. Raw logs remain in ignored `build/D3` and `build/verification`; large App/model/package files are not committed. The tracked reports, owner coverage and next steps above remain usable without that ignored workspace. No push, merge, publication, actual models/services/credentials/microphone/clipboard/permission changes were performed in this evidence task.
