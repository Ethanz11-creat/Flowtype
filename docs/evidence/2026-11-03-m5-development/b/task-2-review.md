# B2 controller task review

Base748855375a4f887732aa282d50d0c3ef2d260c43 → HEADdf63cd2f903cd6de33e5a79db4d1956adef6ced5. Controller separate review under maximum-one-subagent ruling.

Inputs: task-2-brief.md; finalized report; complete review-7488553..df63cd2.diff read in two passes; raw focused/full/watchdog evidence and unchanged dependency record. No unchanged tests repeated.

Spec compliance: APPROVED. Packaged .app resources have a single standard nested bundle entry with no developer fallback; ordinary development retains Bundle.module. Both postprocessor resource consumers and status icon use the entry. Bounded segment canonicalization handles escaped bundle/file/Metal ancestors and missing/dangling targets. Strict two JSON/nonempty entries/icon parsing is distinct from ordinary fallback semantics. Artifact main emits one closed report/null failure with isolated cleanup; packaged clean identity precedes any work. Three injected stages stop at failure and only completed stages become true. Live Metal actually calls makeLibrary; live MLX separately performs explicit .gpu add/eval/Int32 readback and requires[2,3]. No model/UI/router/timer work is constructed by artifact entry; focused/full use only synthetic dependencies.

Quality: APPROVED. Lazy hardware boundaries prevent accidental real GPU execution by code tests. Closed error mapping avoids path/error leakage. Tests exercise real generated bundle files, malformed/missing resources and escaped links, plus ordered stages and wrong result/identity. Package.swift/Package.resolved have zero diff; transitive MLX import compiled.

Evidence: behavioral RED58/48; first GREEN105/1 found missing-leaf ancestor resolution bug; repaired focused108/0 including two dangling targets. Stable sequential build0/full24334/0, external normal0/no timeout257412ms, stderr empty. No later source edits. These are source/synthetic results; real packaging/default MLX search/GPU remain B3 Pending.

Critical/Important: none found. No new task-scoped Minor. Earlier SelfTest summary repetition remains optional final-review carry from A3.

Declined/outside task: strict signature, actual packaged resources/Metal/MLX, repository-external execution and final smoke10 are B3/C; ordinary GUI/tap/model/cloud/device/clipboard/input/manual and remote CI remain Pending. No result inferred for them.
