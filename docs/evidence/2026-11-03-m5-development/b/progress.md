# SDD ledger — plan: docs/superpowers/plans/2026-11-03-m5-b-smoke-and-artifact.md

Baseline: 15ba5e2c81a6b86537da548fe3dfcba84e4b8a0b; branch flowtype-local; existing linked worktree.
User authorization: implement all M5 A→B→C, maximum one subagent.

Ruling: Reuse one implementer for all tasks; controller performs separate task/scoped/final reviews — user caps subagents at one, overriding fresh-subagent-per-task/reviewer skill defaults — cost if wrong: reduced fresh-context diversity, mitigated by written task-specific diffs/review gates.
Ruling: The prior planning-only sentence is historical and superseded by current implementation authorization; retain no-push/no-install/no-real-user-data limits — user explicitly requested development — cost if wrong: reversible source/doc changes; no external release side effects.

## Preflight

| Pair/task | Produces/consumes or internal check | Finding / resolution |
| --- | --- | --- |
| B1/B2 | ValidationReport/main dispatch | 共同字段一致；artifact不构造UI/timer |
| B1/B3 | BoundedProcess/child dispatch→check-app/fixture | 各CLI先支持内部子模式；原始进程组归属不变 |
| B2/B3 | AppResources/MLX→标准Resources布局 | 真实Metal+MLX与strict/deep必须运行证明 |
| B3/C1/C3 | manifest/check-app CLI→verify/manual identity | 签名后hash；工具有独立Codable映射 |
| B1 | Files/interfaces/tests vs implementation | task text internally consistent; Task headings normalized for skill extractor; no change to product requirements |
| B2 | Files/interfaces/tests vs implementation | task text internally consistent; Task headings normalized for skill extractor; no change to product requirements |
| B3 | Files/interfaces/tests vs implementation | task text internally consistent; Task headings normalized for skill extractor; no change to product requirements |

Historical M4 build/full23872/0 accepted as baseline; no unchanged pre-implementation full rerun, per spec. Execution evidence belongs to this plan only. Task briefs are generated before each dispatch. No task complete yet.

## Tasks

- [x] Task 1 (B1)
- [x] Task 2 (B2)
- [x] Task 3 (B3)
Task 1: starting atd6aaace2bcbc74d21499543e83684598391bda41. M5-A source approved, full24164/0; no artifact acceptance inherited.

Task 1: minor (deferred): short fixed timer fixture waits/upper range may be scheduler-sensitive; final review to triage bounded eventual assertions.
Task 1: complete (commits d6aaace..7488553, spec and quality review clean; full24224/0, development smoke0/6356ms/probe1/window1; task-1-review.md).
Task 2: starting at748855375a4f887732aa282d50d0c3ef2d260c43.

Task 2: complete (commits7488553..df63cd2, spec and quality review clean; focused108/0; full24334/0; package/lock unchanged; task-2-review.md).
Task 3: starting atdf63cd2f903cd6de33e5a79db4d1956adef6ced5. Actual resource/signature/Metal/MLX gate still Pending.

Task 3: minor (deferred): standalone manifest architecture relies on fixed production adapter lipo check; production arm64 proven; optional standalone validation at final triage.
Task 3: complete (commitsdf63cd2..c21cb25, spec and quality review clean; packaging128/0/runner17/0; actual strict+external-resource+Metal+MLX Pass; task-3-review.md).
M5-B source and B3 artifact gates complete; final C10/manual/remoteCI and whole-M5 review remain Pending.

Final whole-M5 source review approved at4cdfaf4; final actual release run3683D6F7-2BD5-4F54-A3EF-5F80A38020D0 technical24phasesPass/full24334/0/smoke10of10. Manual41 and remoteCI Pending; see C final-source-review.md/final-technical-review.md, archived at closeout. Earlier Pending notes above are chronological checkpoints.
