# Final golden-copy fix report

Base: `4d8da71354a0400c4108a5784253b8d7e438ba0f` (source clean at start). Commit: `00bdd2f` (`test(capsule): align stable presentation golden copy`); only `SelfTest.swift` committed. Working tree clean afterward.

## Root cause and failing evidence

The final code lane report `build/verification/6B551B82-A340-4ACC-9EBB-43DD5488503C/verify-report.json` marks `code-build` Pass, `code-full` Fail with exit 1 / `fullTestFailed`, and both source snapshots clean at SHA `4d8da71`.

The full-test child stdout ends `25554 passed, 1 failed`; its entire stderr contains only:

> presentation: ASR provider identity does not leak into processing title — got 正在处理, want 处理中...

Evidence files:

- `build/verification/6B551B82-A340-4ACC-9EBB-43DD5488503C/children/2519F634-5CF2-4880-A209-548594BA2304/stdout`
- `build/verification/6B551B82-A340-4ACC-9EBB-43DD5488503C/children/2519F634-5CF2-4880-A209-548594BA2304/stderr`

`SelfTest.testStableSessionPresentation` still expected the superseded `处理中...` title. Approved spec `docs/superpowers/specs/2026-11-03-capsule-waveform.md:15` explicitly requires processing and polishing to share `正在处理`. Product behavior is correct; the old full-suite golden was stale and had not been invoked by the focused presentation route.

## Minimal test-only fix

Only `Sources/flowtype/Testing/SelfTest.swift` changed:

1. Update that existing expected title to `正在处理`. Preserve the private-provider fixture, no-provider-leak assertion intent, ASR/polish shared-title assertion, and preparation-spinner assertion.
2. Invoke the same existing three-assertion test in `--capsule-presentation-only`, so this route now catches a stale golden too. The existing full-suite registration remains unchanged; no new broad flag, duplicate test implementation or product change.

## Verification

The existing full-lane failure above supplies the failing evidence. Per parent instruction, this worker does not rerun the full suite or either final verification lane.

```sh
swift build > .superpowers/sdd/2026-11-03-capsule-waveform/final-golden-fix-build.log 2>&1
# exit 0; Build complete! (42.19s); no warnings/errors

.build/debug/FlowType --self-test --capsule-presentation-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-capsule-waveform/final-golden-fix-presentation-run > .superpowers/sdd/2026-11-03-capsule-waveform/final-golden-fix-presentation.stdout 2> .superpowers/sdd/2026-11-03-capsule-waveform/final-golden-fix-presentation.stderr
# exit 0; 114 passed / 0 failed; stderr empty

git diff --check
# exit 0
```

Parent retains scoped review and the fresh complete code/artifact gates. No cloud, microphone, clipboard, permission or active-window effects are needed by this change.
