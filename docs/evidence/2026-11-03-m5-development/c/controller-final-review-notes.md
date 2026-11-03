# Controller whole-M5 review working notes

Not a final verdict. Baseline 15ba5e2c81a6b86537da548fe3dfcba84e4b8a0b. Reuse one implementer; controller independently reviews.

Read cross-task product paths: RuntimeEnvironment/RuntimePaths/ValidationEffects, main bootstrap, BuildInfo, AppResources/RuntimeArtifactCheck/StartupSmoke, DiagnosticLogWriter/AppLogger, StatusBarController, BoundedProcess, packaging core/CLI/generator, persistence/configuration/database migration and model/network/input boundary diffs. No product tests rerun to confirm earlier agent reports.

Initial conclusions to reconcile at final HEAD:
- Runtime role established before shared/logger/AppKit; unique defaults and in-memory Keychain, fixed isolated paths. Root traversal uses descriptor-relative no-follow operations; regular-file/unwritable-root missing explicit fixtures are nonblocking coverage opportunities, code fails closed.
- Hardware MLX/Metal calls lazy artifact-only; code full uses synthetic ArtifactCheckDependencies and synthetic session/transport models. Validation counters describe guards, not an OS sandbox; source audit supplements spies.
- BoundedProcess owns only handshaken group, not arbitrary nested Foundation-created groups. Packaging marker recovery refuses live owner/inner group and conflicts; does not infer global process cleanup.
- Logger repetition in focused summary branches is minor maintenance, all current exits flush. No need unrelated refactor.
- B1 short timer wait fixture scheduling sensitivity remains a minor test reliability risk, no actual failure observed in supplied focused/full evidence. Do not rerun unchanged suite to search for flakes.
- B3 production adapter uses real lipo arm64 proof. Standalone manifest architecture assumes it; optional standalone-only hardening is not a current production blocker.

C1 integration findings sent while in progress; resolve against final commit/raw evidence, not this note:
1. Recovery must guard current + backup candidates against active use, correct live lsof, zero candidate mutation, legal recovery retained.
2. External smoke duration >=6000ms and JSON duration not materially larger than observed, instant/overstated negatives.
3. Content fingerprint only tracked explicit build inputs; no untracked .env contents; reject ancestor symlinks.
4. Evidence/tool directories reject symlink ancestors before any writes; reuse root preparation for C2 export.
5. Parent report write failure fixture must exercise late write seam and assert partial phase retention, not merely initial occupied-root rejection.
