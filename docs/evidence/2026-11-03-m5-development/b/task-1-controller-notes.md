# B1 controller review preparation

Review base d6aaace2bcbc74d21499543e83684598391bda41. Implementation in progress; these are checks, not a final verdict.

- Read watchdog ownership/handshake/timeout implementation and process fixtures, StartupSmoke, timer changes, action gates/selectors, RuntimeOptions filter and report schema.
- Sent implementer the concrete coverage gap in actual window/menu entrypoints (gate enumeration alone insufficient). Await final test implementation/evidence before grading.
- Verify no ordinary AppDelegate, captures, permission prompts, input/clipboard mutation, provider probes or model loads are reachable in smoke.
- Verify actual startup observation >=6s and actual instance callbacks >=1, unique ownership/stop behavior, no shared redirect.
- Verify process descendant termination means no active owned descendant; zombie state is not live work, but do not suppress live descendant failures. Non-owned fixture must survive.
- Final task review must consume committed review diff and finalized report/raw exit evidence; do not repeat unchanged tests.
