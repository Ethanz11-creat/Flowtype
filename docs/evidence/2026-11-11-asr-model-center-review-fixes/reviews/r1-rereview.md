# R1 focused follow-up review

Date: 2026-11-11. Base: `aa5d037c316d03d543b3f3f424cbc16b9e44f325`. Reviewed HEAD: `e0980ec6c8b2c35ca67736cce8520bb51b2f4de1`.

Read `r1-fix-report.md`, the supplied `r1-fix-range.diff`, the two changed files and relevant existing identity projection. Confirmed the current HEAD and clean working tree. This review is limited to R1 and new breakage in its two-file diff. Original `rereview.md` is preserved. No suites were rerun, no children were used, and no source/index/HEAD or user state was changed; only this follow-up report was written.

## Strengths and specification alignment

**R1 — ADDRESSED.** `ASRModelCenterViewModel.swift:444` captures the original detail's projected backend identity and whether it was focused. After the existing relocation succeeds, `:450` resolves the captured durable imported UUID from committed configuration and uses the existing `ASRModelCenterPresentation.nativeID` projection to follow its actual new identity. This handles legacy primary, fallback and unselected relocation without changing role, persistence or lease semantics.

Both initial focus and current focus must match the old detail (`:451`). Navigation to another row, cleared focus, and an unrelated row already focused before the action therefore remain unchanged. Failed or canceled relocation throws before this continuation, and a stale preview fails the existing guard before loading; these paths do not perform the new focus assignment. Ordinary external relocation resolves to the same backend ID.

The fix stays within the VM's successful continuation and reuses identity projection rather than duplicating legacy mapping rules. The nine production lines are proportionate to the issue, and no new lifecycle abstraction or unrelated change is introduced.

## Issues

- Critical: none found.
- Important: none found.
- Minor: none found in this focused follow-up diff.

## Verification evidence

Read the raw logs without rerunning tests. `fix-logs/r1-red.log` contains exactly the three expected primary/fallback/unselected focus failures and reports **476 passed / 3 failed**. Each failure retains the old preset ID where the fixture expects its imported UUID. `fix-logs/r1-green.log` reports **479 passed / 0 failed**. The associated build logs complete in 31.53 seconds and 27.72 seconds, with no warning/error diagnostics found.

The changed tests execute the production environment/UIActions relocation path. Successful legacy cases now set initial preset focus and assert actual imported focus alongside association, role and lease outcomes. Six additional guard scenarios exercise load failure, explicit cancellation during blocked loading, obsolete preview, browsing another row, clearing focus and unrelated initial focus. They assert the real persisted directory as well as focus, so skipped work cannot falsely establish successful navigation behavior. This is meaningful isolated regression evidence, not a claim of real device/VoiceOver/manual acceptance.

## Declined to judge

- Unchanged behavior outside R1 was not re-audited; the earlier scoped review remains the disposition for I1/I2/I3/M1.
- No behavior within this small follow-up diff was set aside as outside the specification.

## Assessment

**Scoped fix review: clean.** All original findings **I1, I2, I3 and M1**, plus follow-up **R1**, are closed. Candidate `e0980ec6c8b2c35ca67736cce8520bb51b2f4de1` is ready for the controller-owned full code/artifact/release gates. No further source correction is recommended by this scoped review.

**Formal release readiness remains Pending.** The full candidate gates have not been run by this reviewer. The 71 real manual/device checks, current remote CI and formal distribution evidence remain separate acceptance gaps; neither prior candidate evidence nor fixture results are promoted to those gates.
