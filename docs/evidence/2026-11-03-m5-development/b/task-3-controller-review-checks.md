# B3 planned controller review lens

Task-scoped checks derived from brief/spec; no verdict before final diff/evidence.

- Fixed production adapters, driver-only injection; no release source/signature/hardware bypass switch.
- Clean/non-shallow identity and HEAD/tree stability across build; metadata consistent with plist; hashes only after signing.
- Actual release .bundle copies, standard MLX resource bundle and plist; no MacOS shader/code signing of shader, Python, installs, xattr or signature relaxation.
- One owned lock for publication and release-resource hiding; no overwrite of active normal app. Journal/backup provenance and original/expected fingerprints govern rollback; two renames are not called atomic.
- Restoration after normal failure, TERM/INT, failed artifact, timeout and leftover marker; unknown paths/content/active ownership fail closed. Verify B1 cancellation retains old contract and nested group race cannot produce false Pass.
- Outside-checkout app copy, unrelated cwd, no shader-location env rescue; hide only actual current-worktree release resources and restore all before success. Copy/signature/artifact identity and binary/metadata/shader/resource hashes checked before/after.
- Real result must show three separate stages all true plus resolvedInsideApp, fixed packaged clean metadata and matching signed binary. Synthetic fixture success is insufficient.
- Original source shader copied before final old app replacement. No normal app/model/device/permission/clipboard/input/provider run. No unchanged product full for script-only work.
- Record legitimate deferred/unsupported results honestly; no release or remote CI inference.

## In-progress concrete feedback sent before final task review

- buildApp failure catch deleted unjournaled owned staging, contrary spec§6 retained diagnostic stage; await amended retention/recovery evidence.
- canonical .build was an allowed-root anchor even if it pointed to another worktree/cache; require actual release resources remain in this canonical worktree and a rejecting external-.build fixture.
- JSONSerialization as? Int/Bool bridging can confuse numeric/boolean schema types; typed independent Codable report + malformed type negative requested.
- raw signal handler/global nonisolated(unsafe) Int32 lacks synchronization/volatile semantics; request async-signal-safe notification and synchronized cancellation state, covering TERM restoration and child signal inheritance.

These are ongoing implementation checks, not waived findings. Final review must reconcile each against committed code/report/tests.
