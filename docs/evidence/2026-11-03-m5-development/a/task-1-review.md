# Task 1 controller review

Range9b149fd..aea7dc9, package review-9b149fd..aea7dc9.diff read in full; task brief and report compared; final focused/build raw evidence inspected. No test rerun on unchanged code.

Spec compliance: APPROVED for A1. Runtime current is explicit and locked, unique role/suite/root is bound before launch, descriptor-relative O_NOFOLLOW traversal and O_EXCL marker prevent symlink/shared-root acceptance, app formulas preserve casing, errors/unsupported modes cannot enter GUI. Context identity/runID injection is instance-only. A2 persistence and A3 metadata/flush are intentionally absent, not falsely accepted.

Task quality: APPROVED. No Critical/Important finding. The marker/parent traversal handles two-owner race; locks do not recursively call process current; handles are closed on throwing paths. Test expectations use literal old formulas and actual filesystem/launch behavior. Final source has build exit0 and focused94/0, with real behavioral RED49/19.

Minor deferred: Review Focus mentions read-only roots, while new root tests cover symlink/occupied/ownership race and protected roots but do not explicitly chmod an owned fixture root read-only or test a regular file as root. Implementation fails closed (openat O_DIRECTORY/openat marker failures), so this is test coverage, not a demonstrated unsafe branch. Carry to final review; add targeted fixtures if this code is touched again.

Existing AppLogger nonisolated(unsafe) queue warning is unchanged; A3 already owns replacement logger, carry there. Whole runner remains prohibited until A2.
