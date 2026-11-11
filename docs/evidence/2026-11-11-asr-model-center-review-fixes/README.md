# ASR model-center review fixes — 2026-11-11

**Current technical candidate Pass; formal release Pending.** Code candidate `76757c7e5693c0350b67093d1a0750c21b0b214b` passes **28,484 assertions / 0 failures**. Artifact passes 22/22 phases and 10/10 smokes. Release reuses the same ad-hoc App, passes 24/24 technical phases and another 10/10 smokes, and returns **exit 2 / Pending** for manual and remote CI. Actual ordinary D4 distribution and D2 model-center gates also return **exit 2 / Pending**. No unexpected final-candidate gate failure occurred.

| Identity | Exact value |
| --- | --- |
| Executable code commit | `76757c7e5693c0350b67093d1a0750c21b0b214b` |
| Sources tree | `a3fb7822700cc8bfda8d8d36240619d13f9bec18` |
| Scripts tree | `95057298acb707b433912b0652c406a7865f3e6c` |
| Ad-hoc executable SHA256 | `cbefddba7165b06ef60f78189ef7b4ca8ec73ec68b2529397064e63f8c5b54c5` |
| Artifact manifest SHA256 | `0c36f75e5194ca679b76e0b3c74e3544bf2d826c8c135e0132628ce8d16aa88d` |
| Metal shader SHA256 | `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f` |
| Package.swift SHA256 | `eb8bc692aafdef7c2312d119caabd4ea3bbeda0a34feeaaa2d76162dc9441e0f` |
| Package.resolved SHA256 | `b37d08e8803698551e02714fd4d747025077ba6970e83856a02ebe0526838a37` |
| App path during validation | `/Users/yiheng/pycode/flowtype-local/build/FlowType.app` |
| Final distribution package | Pending; packageSHA256 null, no DMG produced |

The known explicit shader was physically rehashed and staged at `/Users/yiheng/pycode/flowtype-local/build/review-fixes-validation-20261111-005928/shader/default.metallib` before packaging replaced the App; no cache search was used. All gate and template commands explicitly unset both signing-identity and notary-profile environment variables without inspecting their values. Packaging used default ad-hoc signing. Manifest, executable and all 17 recorded resource hashes were measured before release and after all gates and remained identical. Source/scripts/dependency files remained frozen and clean throughout the sequential gates.

## Evidence

- [Gate results and actual counts](gate-summary.json), [exact commands, exits, raw paths and hashes](commands.json), [candidate/resources identity](candidate-identity.json), [manifest](reports/FlowType.manifest.json).
- Current [code](reports/code-report.json), [artifact](reports/artifact-report.json), [release](reports/release-report.json), and [D4 distribution](reports/distribution-report.json) reports. Relative phase evidence paths in copied gate reports refer to the original ignored run directories recorded in commands.json. D2's actual result is in its command log/hash; it does not produce a separate JSON result file.
- Fresh [41-case mainline](reports/manual-mainline.json) and [30-case model-center](reports/manual-model-center.json) ledgers bind only the available technical candidate identity. Every row remains Pending, with no fabricated tester/date/actions/observations/evidence. [Remote CI](reports/remote-code.json) is a fresh not-run Pending wire document with blank gitSHA/sourceTree/runURL and no evidence.
- [Focused RED/GREEN log and preview hash inventory](focused-evidence-sha256.json) records original raw paths without embedding large logs. [Four new controller Rulings and their costs](rulings.md) are verbatim; [52 historical Rulings](../2026-11-10-asr-model-center/rulings.md) and [owner coverage/reports](../2026-11-10-asr-model-center/coverage.md) remain in the previous archive.
- [Archive SHA256 inventory](archive-sha256.json) and [closeout validation](closeout-validation.json). No App, model, package or large raw log is tracked here.

## Fixes and independent review

The [original review](reviews/report.md) found I1 primary recovery limited to cloud, I2 missing model-center cancellation, I3 missing same-UUID external relocation, and M1 missing independent cloud-text-polish disclosure. The [fix report](reviews/fix-report.md) documents root causes and meaningful RED/GREEN evidence: selected eligible primary recovery keeps its 60-second identity-bound reservation and bounded fallback budget; explicit successful Test checks current identity and mutation epoch. The application-owned operation now exposes captured-UUID cancellation and retains admission until actual drain. Relocation uses B5 validation/persistence/lease ownership, preserving imported UUID and role slots while clearing/remapping the exact legacy association. The production policy summary reuses the existing disclosure and text-settings navigation.

The [first scoped rereview](reviews/rereview.md) closed the four findings and found R1: legacy relocation left detail focus on the old preset backend. The [R1 fix](reviews/r1-fix-report.md) follows the committed imported UUID only when the original detail is still focused; failure, cancellation, stale preview and user navigation retain their expected focus. Its [follow-up review](reviews/r1-rereview.md) closes R1 with no new findings. Original reports are copied byte-for-byte.

Historical focused counts in those reports belong to their recorded earlier commits (aa5d037 / e0980ec), not the final candidate. Final-candidate focused results are **496/0 model center** and **1,128/0 backends**, recorded in [the gate correction report](reviews/gate-failure-fix-report.md) and the [current small raw model-center log](reviews/gate-fix-final-model-center.log). Fixtures and offscreen previews do not establish real-model or human acceptance.

## Preserved failed gate and deterministic correction

The first full code run at **e0980ec** returned **exit 1 / Fail, 28,471 passed / 1 failed**: `C4 I3 cancelled producer retains owner until actual cleanup drain`. Its [unchanged report](reports/historical-e0980ec-code-report.json), [exact command and raw/report hashes](historical-e0980ec-failed-code-evidence.json) and [original stop note](reviews/historical-e0980ec-stop.md) are retained. Artifact/release were never started for that candidate. This failure is neither erased nor relabeled Pending.

The original log lacked exact-session/held-state diagnostics, so its historical scheduler interleaving remains unknown. Controlled delayed admission proved the old finite-yield helper could return with zero sessions and no VM/A5 owner, reproducing the false premise: [diagnostic patch](reviews/gate-diagnostic-instrumentation.patch), [actual controlled RED log](reviews/gate-diagnostic-red2.log), **480/2**. This establishes a synchronization defect in the test; no production ownership defect was established by the uninstrumented full failure.

The [correction report](reviews/gate-failure-fix-report.md) replaces finite polling and arbitrary sleeps with exact newly-created session finish/cleanup barriers and identity-bound timer tickets. A minimal optional sleeper exercises the existing real AsyncDeadline race; nil defaults preserve production sleep/cancellation behavior and the 15-second realtime timeout. Ownership assertions remain and cover worker-held and cleanup-held boundaries independently. The [fresh scoped review](reviews/gate-failure-rereview.md) is clean. Renewed full verification was justified by this changed, reviewed source; no unexplained retry-to-green was used.

## Pending acceptance and limits

All **71 real manual/device checks**, actual Qwen/Whisper model acquisition/loading/offline quality/memory, real HF authorization/restart/resume/disk conditions, actual cloud vendors and all **three local servers**, credential/Keychain behavior, keyboard/VoiceOver/window interactions, current remote CI and formal distribution remain **Pending**. No models/services/network/credentials/user configuration/microphone/clipboard/permissions/release identity/notary/mount/Gatekeeper/push/merge were used for this closeout.

Historical [remote CI run 41672136709](https://github.com/Ethanz11-creat/Flowtype/actions/runs/41672136709) remains **failure (25,919/1)**. Local Pass does not change it. The historical code candidate d43a603 and 28,335/0 results remain [previous-phase evidence](../2026-11-10-asr-model-center/README.md), preserved byte-identically; this archive supersedes them only for current code evidence.

DashScope strict actor-internal cleanup joining remains the documented lifecycle-proof limitation: no reproduced late-output/stale-selection/additional-audio consequence was established, and injected session fixtures do not prove the real actor's internal cleanup. It is not a newly established product bug. The historical captured-mutation warning is baseline history; an incremental build does not establish a warning-free clean rebuild.

The [remaining release work](../2026-11-10-asr-model-center/README.md#remaining-release-work) still applies: produce the final Developer ID signed/stapled App and final DMG with actual Apple provenance, run artifact verification against that final identity, generate fresh candidate-bound ledgers, complete all 71 actual observations and current remote CI, and rerun release/D4/D2 with complete evidence. Final signing/resource/package changes invalidate this ad-hoc identity for manual acceptance. D4 observed ad-hoc signing and returned Pending before external notary/mount operations; missing DMG/notary paths were deliberately absent.

## Code candidate and documentation commit

The documentation commit is separate from executable candidate `76757c7e5693c0350b67093d1a0750c21b0b214b`. Find it with `git log -1 --format=%H -- docs/evidence/2026-11-11-asr-model-center-review-fixes/README.md`. Verify `git diff --exit-code 76757c7e5693c0350b67093d1a0750c21b0b214b <docs-commit> -- Sources scripts Package.swift Package.resolved` and compare `<docs-commit>:Sources` / `:scripts` to the trees above. This archive advances only documentation/evidence; no rebuild or report relabeling is needed for its commit.
