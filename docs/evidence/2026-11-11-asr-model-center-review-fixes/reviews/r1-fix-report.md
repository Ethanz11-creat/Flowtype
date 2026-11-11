# R1 — follow the relocated model detail

Date: 2026-11-11 (Asia/Shanghai). Base: `aa5d037c316d03d543b3f3f424cbc16b9e44f325`. Final HEAD: `e0980ec6c8b2c35ca67736cce8520bb51b2f4de1`. Sources tree: `36cd76ab34503bb475e7708996ade3810f3a98ce`.

## Verified root cause

Read `rereview.md` and traced production `ASRModelCenterEnvironment.actions` → `relocatePreview` → existing B5 transaction → VM refresh. Successful legacy relocation correctly clears the preset association and changes the backend ID to `native:import:<same imported UUID>`. The continuation did not update selectedID, and refresh always retains the built-in preset row, so selection remained on that old, now-uninstalled preset detail. This was a focus-only omission; no new transaction or model-lifecycle change was needed.

## Final behavior

`ASRModelCenterViewModel.relocatePreview` captures the original projected backend identity from the preview's original model and installed records, and records whether that detail was focused before awaiting relocation. Only after the existing transaction succeeds, if the same original detail is still focused, it resolves the captured imported UUID in the committed configuration and selects its actual current backend ID using `ASRModelCenterPresentation.nativeID`.

User navigation is respected: a different detail selected during the await, cleared selection, or an unrelated detail already focused before the action stays unchanged. Failed/canceled/stale-preview continuations never reach the focus update. No configuration, role, credential, lease, preview-validation or persistence semantics were changed.

## Meaningful regression coverage

Existing `legacyRelocation` cases now start with `selectedID == old preset ID` and check the actual production environment/UIActions result for primary, fallback and unselected legacy relocation. Each must focus the same durable imported UUID after commit.

New `legacyRelocationFocusGuards` exercises actual environment/UIActions across six cases: load failure, explicit UIActions cancellation during an uncooperative load, obsolete preview, user browsing another detail while loading, user clearing focus while loading, and unrelated detail already focused when relocation starts. Assertions check both final detail focus and the actual committed/unchanged directory, so a skipped transaction cannot masquerade as navigation preservation.

## Sequential RED → GREEN evidence

No tracked edits occurred while build/self-tests ran. Raw logs are beside the original logs in `fix-logs/`.

```sh
swift build > build/reviews/2026-11-10-requesting-z7be18vw/fix-logs/r1-red-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-model-center-only > build/reviews/2026-11-10-requesting-z7be18vw/fix-logs/r1-red.log 2>&1
```

RED build exit 0, `Build complete! (31.53s)`. Test exit 1: **476 passed / 3 failed**. The only failures were `R1 successful legacy primary/fallback/unselected relocation follows same imported UUID detail`, each reporting the old `native:preset:qwen3-0.6b-4bit` instead of that fixture's imported backend UUID. The new navigation/failure guards already passed before the production change.

```sh
swift build > build/reviews/2026-11-10-requesting-z7be18vw/fix-logs/r1-green-build.log 2>&1
swift run --skip-build FlowType --self-test --asr-model-center-only > build/reviews/2026-11-10-requesting-z7be18vw/fix-logs/r1-green.log 2>&1
```

GREEN build exit 0, `Build complete! (27.72s)`, no emitted warnings/errors. Test exit 0: **479 passed / 0 failed**. No source edits followed that verification. `git diff --check` and staged diff check both exited 0. Explicit-file commit:

```text
e0980ec6c8b2c35ca67736cce8520bb51b2f4de1 fix: follow relocated model identity in detail focus
Sources/flowtype/Settings/ModelCenter/ASRModelCenterViewModel.swift
Sources/flowtype/Testing/ASRModelCenterFixSelfTests.swift
```

## Self-review and limits

Reviewed the two-file diff: nine production lines only, after successful awaited relocation and before the existing refresh; imported UUID resolves from committed configuration, and both initial/current focus checks guard unrelated navigation. Working tree is clean after commit. Original `fix-report.md` and `rereview.md` were not overwritten; this separate report remains in the requested ignored review directory.

No broader suites/full code/artifact/release gates were repeated; those are controller-owned next. Tests use existing isolated configuration, synthetic inspection/provider and cancellation gates. No real models/services/network/user state/credentials/microphone/clipboard/permissions/signing/notary/download/push/merge or child agents were used. Real interaction/accessibility/release acceptance remains pending; this report establishes the production action/presentation behavior covered by these fixtures. No unresolved R1 implementation concern was found.
