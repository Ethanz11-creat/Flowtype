# SDD ledger — plan: docs/superpowers/plans/2026-11-11-iflytek-interview-four-modules.md

Base: e0661d7; branch feat/iflytek-interview; existing linked worktree verified; baseline 12/12 tests pass.
Spec: docs/interviews/2026-11-11-iflytek-four-module-research.md
Execution: inline, one fresh final reviewer; no per-task implementer agents.

Pre-flight: Task1 → Task2/3: id/path inputs and unified prediction schema match.
Pre-flight: Task2 → Task4: persistent worker serial API available; replay must not block ingress.
Pre-flight: Task1 → Task4: 36 sources / 12 dev /24 eval; refs stay scoring-only.
Pre-flight: Task1/2 → Task5: frozen raw outputs and canonical vocabulary; preserve original prompts.
Pre-flight: Task3/4/5 → Task6: manifest per run, effective fallback outputs, manual_pending labels required.
Ruling: Existing isolated worktree and interview branch are the execution workspace — user explicitly selected them; no extra branch/worktree — cost if wrong: tasks share this user's existing worktree, which is clean and dedicated.
Ruling: Human audio-boundary confirmation and microphone demonstrations remain pending until actually done; all independent implementation and experiments continue — no automated test substitutes for listening — cost: some endpoint metrics cannot be claimed yet.

Tasks: 1–6 implementation and automatic matrices complete; overall human acceptance partial.
Task 1: complete (commits e0661d7..da4d1e3, tests: env PYTHONDONTWRITEBYTECODE=1 build/ascend-validation-audit/.venv/bin/python -m unittest discover -s tools/interview_bench/tests -p test_*.py → OK)
Task 2: complete (commits da4d1e3..923d38d, tests: env PYTHONDONTWRITEBYTECODE=1 build/interview-bench/.venv/bin/python -m unittest tools.interview_bench.tests.test_backends tools.interview_bench.tests.test_schema tools.interview_bench.tests.test_prepare → OK)
Task 2 evidence: admission 20261111T080109067213Z, all three models 10/10 ok. First failed admission retained. MLX metallib copied adjacent to new binary; dependency stdout redirected to stderr. Qwen0.6 LFS SHA, Whisper SHA, Silero Git blob verified; GitHub API used for identical pinned Silero content after raw-host timeout.
Ruling: While Task3's serial model batch runs, implement independent Task4 tooling; no extra inference batch runs concurrently — avoids wasting batch wall time, inputs/protocol remain frozen — cost if wrong: shared machine compiler/test CPU load affects uncontrolled desktop performance; recorded as such.
Ruling: Task5's fixed-baseline cloud requests may run while Task3's single-model-at-a-time batch runs; neither uses the other's new outputs — inputs and candidate lists already frozen, cloud workload is network-bound — cost if wrong: some CPU/network load is present during timing, so performance remains an uncontrolled desktop measurement, not a speed SLA.
Task4 historical check: archived flowtype-dev contains a 2026-05-15 streaming design (server VAD/stable commit window), not equivalent to this causal 32ms replay. Read only; no merge or claimed prior coverage.
Tooling checkpoint: 25/25 new tests and 12/12 original research tests pass. Tasks3–6 implementation committed; real model/correction batches still running, no completion lines yet. Original test runner needs PYTHONPATH=tools; initial module import failure corrected by using original import layout, no old source edits.
Provenance: first full model's pre-checkpoint source snapshot reconstructed from current/Git/append-only prefixes, every byte verified against its already-frozen SHA256 (zero unmatched). Later snapshots will retain the same byte-check rule; no guessed source content accepted.
Task 5: complete (commits 923d38d..d15d0df, tests: env PYTHONDONTWRITEBYTECODE=1 build/interview-bench/.venv/bin/python -m unittest tools.interview_bench.tests.test_correction tools.interview_bench.tests.test_reporting → OK)
Task5 evidence: 982 requests, 374876 reported tokens, zero usage missing, zero fallback. English raw/plain/contextual/mismatched WER 2.99/3.24/2.36/3.21%; mixed raw/plain/static_tech MER 13.98/17.92/14.68%. Preserve negative results; no new API calls/prompt tuning. Correct candidate table covers501/501 rare entries; mismatch3/501; mixed static vocabulary matches0/191 references. Posthoc scoring/rendering sources are separately retained from original inference snapshots.
Task3 interim: Qwen1.7 complete1130, zero failures, 1362/11479 clean and419/2997 mixed; batch887.99s, audio3323.61s, RSS1693712384bytes. Qwen0.6 running, then Whisper. Full exec session31263; correction session22283 completed.
Task4: actual Silero5.1/PyTorch2.8 CPU1thread load/reset check passed; prepared9sessions/36sources. Offline VAD preflight is boundary sanity only, not actual real-clock ASR results. Real dev/eval ASR runs wait for all comparative model batches to finish. Manual annotations, recorded demo and3 microphone insertions remain pending.
Process shutdown regression found during audit: unresponsive worker with descendant in a separate session left it computing. Test observed real failure; owned process tree termination and model batch timeout added;29/29 tests now pass. Existing in-flight batch keeps its loaded orchestrator; inference/model/decoding parameters unchanged.
Pre-replay timing audit: actual RED→GREEN tests caught first-result counting an empty transcript and endpoint timing omitting execution lag. First text now skips empty segments; endpoints use recorded monotonic decision event time, with signal-sample difference separately retained. Frozen inference-source/weight verification added;32/32 new tests pass. Replay scheduler session98093 waits for Whisper resource.json, then runs dev and eval serially; logs replay-schedule.log/replay-dev.log/replay-eval.log.
Task 3: complete (commits 923d38d..22a410b, tests: env PYTHONDONTWRITEBYTECODE=1 build/interview-bench/.venv/bin/python -m unittest tools.interview_bench.tests.test_backends tools.interview_bench.tests.test_reporting → OK)
Task 4: complete (commits 923d38d..3d5fb63, tests: env PYTHONDONTWRITEBYTECODE=1 build/interview-bench/.venv/bin/python -m unittest tools.interview_bench.tests.test_vad tools.interview_bench.tests.test_replay → OK)

Task6: compact matrix/boundary regressions RED→GREEN; full superset accepted, reduced200 mismatches require validated historical400 with explicit cross-batch/mixed-not_run provenance. Runtime supports --profile compact; actual experiments remain full, no further API calls.
Task6: 37/37 new tests and12/12 original research tests passed. Model language groups and load timer scope added to reporting. Walkthrough includes actual outcomes and18 follow-up questions. Human boundaries/recording/microphone remain pending; no fabricated records.
Task 6: complete (commits 923d38d..d9e9eb0, tests: env PYTHONDONTWRITEBYTECODE=1 build/interview-bench/.venv/bin/python -m unittest discover -s tools/interview_bench/tests -p test_*.py → OK)

Final review: fresh-context gpt-6-astra, read-only, e0661d7..d9e9eb0;37/37 new +12/12 old tests and382 archive hashes independently checked; no Critical;2 Important,2 Minor. Report retained in audit/final-review.md.
Final: fixed replay write failure/consumer shutdown — test_audio_write_failure_is_a_failed_segment and test_audio_write_failure_with_full_queue_shuts_down RED→GREEN, suite41/41.
Final: fixed replay canonical session IDs — test_replay_requires_canonical_ids_in_snapshot_summary_and_predictions RED→GREEN (summary/prediction/snapshot), suite41/41.
Final: regraded outdated derived renderer provenance to Important because source attribution is required to reproduce analysis; fixed — test_archived_derived_correction_sources_match_provenance RED→GREEN, suite41/41. Original inference snapshots untouched.
Final: minor (deferred): HTML wall-clock text display does not follow audio pause/seek/rate; uninterrupted playback works, stored event times/metrics unaffected.
Final: Ruling: Human listening/recording/microphone success excluded from automated verdict — retain all three manual_pending until real observations — cost if wrong: no endpoint or product insertion acceptance claim can be made yet.
Final: Ruling: Do not rerun models or cloud services for reviewer reproduction — validate retained outputs and checksums, no new calls after982 — cost if wrong: review does not independently reproduce measured accuracy or alias service behavior.
Final: Ruling: Keep immutable historical inference snapshots including old bugs — fixes apply only to active tooling and derived metadata — cost if wrong: rerunning an old snapshot may reproduce its old bugs; current tools are the supported entry point.
Final: Ruling: Product integration/noise robustness/training/optional models remain outside this interview delivery — preserve the agreed experiment scope — cost if wrong: these experiments do not establish product release readiness or general noise robustness.
Final: Ruling: Annotation paths accept only fixed public-dataset IDs, not arbitrary user imports — current preparation scope makes filename construction bounded — cost if wrong: a future generic dataset importer must validate IDs before reusing it.
Final verification:41/41 new tests and12/12 original research tests pass;8 automatic checks passed,3 manual_pending; compact full-superset also partial. No further model/cloud batches, no client/settings changes. Keep feat/iflytek-interview and this worktree; no push/merge.

Final freeze regression: last copy updated derived metadata without its matching renderer snapshot; new checksum test caught the mismatch. Synchronized source+metadata together and all model-derived summaries/sources; no inference outputs changed. Final verification rerun below.
Final freeze rerun:41/41 tests passed after source/metadata synchronization; original12/12 green. Archive/source hashes verified before final commit.
