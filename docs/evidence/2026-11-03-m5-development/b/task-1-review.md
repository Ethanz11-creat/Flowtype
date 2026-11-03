# B1 controller task review

Base d6aaace2bcbc74d21499543e83684598391bda41 → HEAD748855375a4f887732aa282d50d0c3ef2d260c43. Controller review under the user maximum-one-subagent ruling; implementer self-review is separate.

Inputs: task-1 brief, finalized task-1 report, complete review-d6aaace..7488553.diff (read in four bounded passes), raw focused/process/full/smoke results and CLI negative records. No unchanged tests rerun.

Spec compliance: APPROVED. Bootstrap precedes ordinary startup; smoke bypasses AppDelegate, uses real hidden panel/status setup and read-only readiness, actual instance-owned Sendable probe and common health callbacks with 1s/30s and 5s defaults, >=6s observation and10s deadline. Non-app selector/tap/hotkey guards are exercised at actual entrypoints by synthetic downstream spies and app controls; mutation52/6 proves detection. Closed report fields/nulls and explicit WindowServer69 vs ordinary failure are preserved. External watchdog has a handshaken owned group, monotonic bounds, file outputs, null stdin, literal argv, TERM2s/KILL and bounded group cleanup.

Task quality: APPROVED. Generation invalidation/weak ownership prevents redirected/stale timer work. Main exit flushes and cleans only its suite. No product user paths or model/provider actions were added to smoke reachability. The process cleanup now verifies group disappearance after KILL, not just parent termination.

Evidence: behavioral RED15/34; actual entry mutation52/6 → focused58/0; process RED7/3 →17/0; stable build0/full24224/0 (198198ms); one real development smoke0 (6356ms, probe1/window1, blocked readiness, no timeout, exactly one JSON). Negative CLI64/64/64/root preparation1 as specified. No source change after these runs. Final ten/artifact/GPU/manual/remoteCI not inferred.

Important/Critical: none found. Minor deferred: timer fixtures use short fixed waits (150ms/110ms) and a tight health tick upper range; scheduler load could make them flaky. Final review should consider bounded eventual observation with ownership assertions rather than scheduler punctuality; no current failure or product defect observed.

Boundary carried forward: Foundation Process can create new groups in ordinary child tools; runner only owns its handshaken group. B3/C owners must bound/clean nested new groups and restore journals themselves. This is explicit in the report, not an OS sandbox guarantee.

Declined/outside task: real tap creation/permissions, visible GUI, models/acoustics, clipboard/input, real cloud, artifact resources/signing and final ten smoke belong to subsequent/manual gates. They remain Pending, not silently accepted.
