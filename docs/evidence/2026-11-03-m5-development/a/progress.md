# SDD ledger — plan: docs/superpowers/plans/2026-11-03-m5-a-build-identity-and-isolation.md

Baseline: 15ba5e2c81a6b86537da548fe3dfcba84e4b8a0b; branch flowtype-local; existing linked worktree.
User authorization: implement all M5 A→B→C, maximum one subagent.

Ruling: Reuse one implementer for all tasks; controller performs separate task/scoped/final reviews — user caps subagents at one, overriding fresh-subagent-per-task/reviewer skill defaults — cost if wrong: reduced fresh-context diversity, mitigated by written task-specific diffs/review gates.
Ruling: The prior planning-only sentence is historical and superseded by current implementation authorization; retain no-push/no-install/no-real-user-data limits — user explicitly requested development — cost if wrong: reversible source/doc changes; no external release side effects.

## Preflight

| Pair/task | Produces/consumes or internal check | Finding / resolution |
| --- | --- | --- |
| A1/A2 | RuntimePaths/defaults/logger路径→所有shared | 先接隔离日志；RED只fixture，A2后才full |
| A1/A3 | 启动bootstrap/日志路径→identity/logger configure | A3增加header/flush不重建current |
| A2/A3 | self-test退出与配置迁移日志 | A3统一退出flush，保留A2存储隔离 |
| A3/B1/B2/B3 | BuildIdentity与生成器→JSON和打包 | 磁盘schema与runtime snapshot分开 |
| A1 | Files/interfaces/tests vs implementation | task text internally consistent; Task headings normalized for skill extractor; no change to product requirements |
| A2 | Files/interfaces/tests vs implementation | task text internally consistent; Task headings normalized for skill extractor; no change to product requirements |
| A3 | Files/interfaces/tests vs implementation | task text internally consistent; Task headings normalized for skill extractor; no change to product requirements |

Historical M4 build/full23872/0 accepted as baseline; no unchanged pre-implementation full rerun, per spec. Execution evidence belongs to this plan only. Task briefs are generated before each dispatch. No task complete yet.

## Tasks

- [x] Task 1 (A1)
- [x] Task 2 (A2)
- [x] Task 3 (A3)

Task 1: complete (commits9b149fd..aea7dc9, controller spec and quality review approved; no blocking findings)
Task 1: minor (deferred): explicit read-only and regular-file root fixtures missing; implementation currently fails closed. Final review must triage.
Task 1: minor (deferred): pre-existing logger DispatchQueue annotation warning; A3 owns logger rewrite.
Task 1 evidence: task-1-report.md, raw final build exit0, focused94/0, actual RED49/19, task-1-review.md. No full test yet.
Task 2: starting at aea7dc9396b2020d2372c85af0d4da20f10394cf.
Task 2 implementation guidance: minimal ValidationEffects capability guard at actual external operation boundaries, with independent downstream spies for zero invocation; do not rely on gate counters alone or add a broad instrumentation framework. Ordinary app behavior direct/compatible; read-only permission states remain allowed. No new project-level policy, elaborates existing isolation contract.
Task 2: complete (commitsaea7dc9..ffd4ba4, controller spec and quality review approved; no blocking findings)
Task 2: minor (deferred): budget counters do not detect entirely bypassed guard calls; evidence is source audit+boundary tests, not an OS sandbox. Final evidence must state limitation.
Task 2 evidence: corrected behavioral RED30/1; focused64/0, sequential build/full24046/0, fixtureDB row1/backups, task-2-report/review. No real GUI/models/permissions/input activity.
Task 3: starting at ffd4ba473cf871617caaebdd65061b06642ee8e9.
Task 3: complete (commitsffd4ba4..d6aaace, controller spec and quality review approved; no blocking findings)
Task 3: minor (deferred): repetitive runner summary logging may drift in future branches; current exits flush. B1/B2 may consolidate naturally.
Task 3 evidence: focused116/0, generator29/0, sequentialbuild/full24164/0, raw/header/flush inspections, task-3-report/review. No realGUI/hardware activity.
M5-A: source complete; package constraints still apply; no final wholeM5 review or artifact/release acceptance yet.

Final whole-M5 source review approved at4cdfaf4; final actual release run3683D6F7-2BD5-4F54-A3EF-5F80A38020D0 technical24phasesPass/full24334/0/smoke10of10. Manual41 and remoteCI Pending; see C final-source-review.md/final-technical-review.md, archived at closeout. Earlier Pending notes above are chronological checkpoints.
