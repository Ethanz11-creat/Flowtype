# Scoped independent re-review: M2 P2 fixes

Read `/Users/yiheng/.codex/skills/subagent-driven-development/re-review-prompt.md` and follow that review contract. Read-only checkout; no subagents, full-suite rerun, model downloads, network, GUI, configuration/key/audio/user-model access or writes to checkout/index/branch.

Repo: `/Users/yiheng/pycode/flowtype-local`. Fix base `9fa57bf`; current HEAD and complete diff are in `review-package.diff` alongside this file. Read this supplied diff once instead of re-deriving via git. You may read relevant changed files and pinned dependency contracts to settle concrete doubts.

## Authority and evidence

- `brief.md`: complete authorized requirements and constraints.
- `report.md`: implementer claims and exact RED/GREEN logs; verify against source and logs, not assertion alone.
- `docs/evidence/2026-11-02-m2-review-fixes/independent-review.md`: original findings in full.

## Findings to verdict, in order

1. P2: accepted Whisper `.mlpackage` sources lack native compilation/preparation and do not match pinned runtime path resolution. The fix must preserve legal Manifest roots/resources, optional prefill, compiled/mixed/source inputs, original identity/tokenizer directory and offline behavior; actual named compiled component paths must reach the runtime. Generated artifacts must remain owned through backend, active/captured leases and in-flight compute, clean up on failure/cancel/release, never remove user files. Uncancellable compilation must drain before gate ownership releases. Do not reject previously accepted source packages or change dependency versions.
2. P2: Qwen full coordinator inspection blocks MainActor for about 1.4s per pass. All expensive imported/startup/retry/legacy/runtime-preparation inspection must be off-main. Preserve operation reservation before any long await, global gate, cancellation/draining/late-result ownership, canonical UUID/fingerprint/resource checks, success-only latest-config commit and prior/captured lease. Test real synchronous inspection held on a worker, main-actor heartbeat/cancel, competing operations and late completion, not only an already-async fake.

## Scope and output

Verdict both as ADDRESSED or NOT ADDRESSED with file:line evidence. Inspect fix diff for new Critical/Important breakage. Untouched findings are nonblocking out-of-scope observations. Do not run unchanged suites; only focused verification if a specific code doubt is unanswered by existing evidence. Actual tiny Core ML compile/load smoke, if present, does not prove full Whisper inference. All actual full-model/GUI/cloud/V1–V5 remain Pending.

Return the report directly: Finding Verdicts, New Breakage in Fix Diff, Out-of-Scope Observations, Checks, Verdict. Include concrete fix for any open Important. No product edits. Controller will save your final response as the review record.
