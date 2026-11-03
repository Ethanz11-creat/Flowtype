# Verification after review repairs

1. Inspect both raw RED/GREEN logs and final diff, including the real CLI/stage paths.
2. Sequential scoped independent re-review after implementer is idle. Resolve substantive findings first.
3. Confirm clean source commit and unchanged Package.resolved blob 702ce34b917f9fdf9927b1b428f431125c28970c.
4. Run once, with stdout/stderr/exit captured:
   MLX_METALLIB_PATH="$PWD/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" scripts/verify.sh --lane release
   No manual/CI report means expected exit 2 / Pending, not 0. Integrated lane owns debug build, full self-test, release packaging, signature/moved Metal+MLX check and ten fresh smoke runs.
5. Inspect all 24 technical phases, child logs and candidate/source identity. No extra unchanged full run.
6. Export only allowlisted safe run evidence, retain focused logs/reviews, add SHA256 inventory. Append repair resolution to original review without rewriting historic findings; update current audit/M5 ledger pointers.
7. Commit documentation/evidence only after verification. Keep manual 41 and remote CI Pending, no publication.
