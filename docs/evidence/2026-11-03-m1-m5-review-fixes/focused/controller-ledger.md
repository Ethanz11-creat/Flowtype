# M1–M5 independent-review repair ledger

Base: 5471880. Requirements: docs/evidence/2026-11-03-m1-m5-independent-review.md IR-01 and IR-02.

- Verified: CLI fallback reads undeclared user caches; violates M5 explicit-input boundary.
- Verified: RecordingStage cancellation catch misses frozen flag; normal Stop retains live context and can advance audio.
- Implementation dispatched to existing m5_implementer; at most one active child, no nesting.
- Sequence: IR-01 behavioral RED/GREEN; IR-02 deterministic stage RED/GREEN; controller diff review; one scoped independent re-review; one integrated release lane after clean source commit; evidence/docs closeout.
- Preserve historical review/run evidence. Real manual 41 and remote CI remain Pending.
- No user data/cache/Keychain, GUI, recording, input/clipboard, remote service/CI, downloads/installs, Python, Package.resolved mutations, push/merge/publish.
- Final release must set explicit existing MLX_METALLIB_PATH to build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib. No cache discovery.

Implementation received: IR01 9c20e31 (RED9/3→GREEN12/0), IR02 bb8b5bf (RED19772/3→GREEN19777/0). Controller inspected production diff, actual CLI fixture source, real stage four-case gate and raw failure/pass outputs. Package.resolved unchanged, clean source HEADbb8b5bf. Independent scoped re-review dispatched sequentially after implementer completed.

Scoped independent re-review: IR01/IR02 ADDRESSED, no new Critical/Important. Controller accepts the enumerated synthetic-vs-real limits; full hardware, cloud, clipboard/input, manual41 and remoteCI still Pending.
One fresh integrated release: run761FBC46-7432-4C5D-A5FF-7D6FB67D71A5 on clean bb8b5bf; exit2/Pending; all24 technical phases Pass, full24364/0, smoke10/10; build358. Controller checked final typed report, child stderr, signatures/moved resource/Metal/MLX evidence, full/smoke raw outputs, source/manifest identity and actual binary/metadata/shader/14 resource hashes. No outer full rerun.
Evidence export initially failed because required preexisting empty destination was missing; created it and export succeeded45 files, no validation rerun. Selected focused archive69 files. Historical review findings retained, current resolution and new candidate evidence appended; manual/CI Pending unchanged.
