# B3 controller task review

Base df63cd2f903cd6de33e5a79db4d1956adef6ced5 → HEAD c21cb25e4d37249d3d932939a6157b946b64a243. Controller separate review under maximum-one-subagent ruling.

Inputs: exact task brief/context/spec§6, finalized implementer report, full review-df63cd2..c21cb25.diff in three passes,128/0 packaging and17/0 amended runner outputs, actual build/watchdog/check/artifact stdout/stderr/results, manifest and strict-signature child logs. No unchanged tests rerun.

Spec compliance: APPROVED. Fixed production adapters share the tested Swift flow; additional core/CLI helpers keep shell contracts narrow without release bypass flags. Clean/non-shallow source identity and HEAD checks, real release bundle enumeration, explicit existing shader copy before candidate replacement, standard nested MLX bundle/plist, actual-code signing then strict/deep verification precede signed-byte manifest and publication. One CLOEXEC flock protects candidate/manifest journals and release-resource hiding. Fingerprints and UUID-owned stages/backups govern recovery; no unknown directory overwrite, active group conflict is Fail, and in-use final candidate is refused.

All four in-progress observations in task-3-controller-review-checks.md resolved: failed stages/new rollback bytes retained; external .build refused/tested; independent Codable report plus explicit-null checks reject bool/int substitutions; raw signal handling only performs self-pipe write with saved errno, synchronized ordinary code observes cancellation. Optional runner hooks retain default behavior and cover onLaunch throw, running/handshake cancellation and owned group cleanup.

check-app validates actual signed hash triples/resources, copies outside checkout, removes locator env, changes cwd, hides only canonical current-worktree release bundles, runs the bounded artifact child, restores outside its inner watchdog, and verifies exact typed report/packaged identity and before/after bytes. Durable conflict/marker behavior after SIGKILL and actual TERM restoration have fixtures. Two candidate renames are not called atomic. No xattr/signature relaxation/Python/install/download/model/ordinary app operation.

Quality: APPROVED. Streaming SHA avoids large shader allocation, actual hashes are independently compared to shasum in fixtures, production entry uses fixed adapters and safe closed errors. Source-only helper changes appropriately avoid unchanged product full. Child group boundary and outer TERM2s/inner race are accurately disclosed; unknown/live inner state prevents success.

Evidence: RED10/18 → final packaging128/0; amended runner17/0; CLI compile and shell syntax0; package/lock unchanged. Unique real build normal0/no timeout176963ms (release163.32s). Unique moved check normal0/no timeout8880ms; artifact843ms/resources=true/Metal=true/MLX=true/resolvedInsideApp=true, packaged clean metadata, failure=null, exactly one stdout JSON. Strict signature raw logs say valid on disk/satisfies its Designated Requirement for original and moved app. Resource restoration reported true and markers checked by implementer. Before/after binary/metadata/shader hashes equal manifest.

Actual candidate: version1.0.0/build350, gitSHAc21cb25e4d37249d3d932939a6157b946b64a243, Sources953608b60a0349dfcd2acfc4ddeef6f6d6b39288. Binaryc59eb53b8aaec14421ef19e2c884e67cbb94f46a31ec069092051e66a38ac85f; metadata9ff060d015a4a3fefffb63b1378bd9e55545f7da17203cd985d5e73b42b6afc8; shaderf36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f. This is B3 evidence, not the C3 final candidate.

Critical/Important: none found. Minor: standalone manifest writer labels architecture arm64 and relies on fixed production release adapter's actual lipo validation; this is correct for supported production flow. Optional future standalone input validation can be considered without blocking this target. Existing product compiler warnings unchanged.

Declined/outside task: actual ASR/model inference, acoustic/visible GUI/tap/permissions/cloud/clipboard/input/device/manual and remoteCI; final smoke10 and release aggregation belong C. No DMG or publish run, no inference of release readiness.
