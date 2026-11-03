# Task 2 controller review

Rangeaea7dc9..ffd4ba4. Read package review-aea7dc9..ffd4ba4.diff in bounded passes, including all production hunks and M5 tests; re-read the test fixture hunk when initial output truncated. Compared task brief, finalized report, raw full24046/0 and focused64/0 logs, fixture artifact counts. No suite rerun.

Spec compliance: APPROVED for A2. Core stores/backup/model directories use RuntimePaths, defaults and sentinel use runtime domain, nonapp Keychain branches before SecItem query, environment skips before read, prepare skips before Task scheduling. Existing injected network/model/driver dependencies retain semantic behavior. Full runner includes new isolation checks and original regression assertions. Extra touched adapters follow named reachable risks, not unrelated refactor.

Task quality: APPROVED, no blocking finding. Real OS calls are guarded, synthetic downstream dependencies remain usable, app guards admit all original behavior. Reporter concurrency change is small/locked and compiler evidence explains it. Full regression24046/0 and retained fixture DB row/migration backups corroborate basic integration; no claim of real GUI/model/network acceptance.

Minor deferred: permitted-budget counters cannot detect an arbitrary future OS call that bypasses ValidationEffects entirely. Current zero counters are supporting evidence only; source audit and independent downstream spies at specific gates/Keychain are the concrete checks. Keep this limit explicit in final evidence; avoid calling counters a complete filesystem/network sandbox. No unsafe current bypass found within automatic runner paths reviewed.

Cross-task checks resolved: smoke remains disabled placeholder and future B1 adds explicit timer startup; missing BuildIdentity/log flush is A3; UI-only direct settings pasteboard is unreachable because window opening is guarded. B1 must additionally disable actionable statusbar selectors and actual hotkey handling; it already owns that contract. Existing warning list is reported, A3 removes old logger warning in its rewrite; unrelated warnings remain out of scope.
