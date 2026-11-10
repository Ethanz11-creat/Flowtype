# Task B3 report — verified resumable streaming downloads

Status: DONE. Base: `8b47f62`. Commit: `958b4a9` — `feat: download ASR files with verified resumable transfers`. Scope frozen after required GREEN; no full suite (controller explicitly reserves it for B6).

## Implemented

- Added `HFDownloadTransport.transfer(file:partialURL:credentialID:progress:) async throws`, using an ephemeral URLSession and serial URLSessionDataDelegate. Payloads never use `data(for:)`, Hub download helpers, global Hub tokens or shared model caches. Delegate callbacks are written synchronously in pieces of at most 64 KiB. SHA verification reads independent 64 KiB chunks.
- Resolve URLs are constructed from the planned endpoint, repository, fixed 40-character commit and safely encoded remote path. A retry starts again at that immutable resolve URL; no signed CDN URL is persisted or logged. Neither production file has logging or response-body printing.
- Added strict response state: 206 requires the current disk offset and manifest total, 200 truncates before writing, and 416 accepts completion only after exact size and digest verification. Invalid ranges and invalid 416 partials are discarded and can restart once, within the three-attempt ceiling. A changed/missing validator on a resumed 206 is an integrity failure. Truncation, excess bytes, digest mismatch, HTML and Git LFS pointers cannot complete; integrity failures remove the bad partial and sidecar for an explicit later retry.
- Added stream verification for metadata-selected LFS SHA256 and ordinary Git blob SHA1, including the exact `blob <size>\0` header. ETags never become content digests. Zero-byte files are rejected at the transport/verifier boundary.
- Added transport-owned atomic `HFDownloadJournal` sidecars containing the exact `HFPlannedFile`, written byte count, a restricted opaque ETag and credential reference. Resume validates full planned-file equality (including endpoint/commit/path/digest/size), credential ID and fresh actual byte length; a mismatched/unreadable sidecar discards that partial. Signed URLs, bearer values and response bodies have no journal fields.
- Added `HFDownloadError` with stable codes `auth`, `rateLimit`, `network`, `integrity`, `diskFull`, `cancelled`; `retryAfter` and `requiresPause` expose long Retry-After pauses to B4. ENOSPC and Cocoa out-of-space errors map to diskFull.
- Transient network disconnect/timeout/connectivity failures, 429 and 5xx retry at most three attempts, with injected 1s/2s waits. A bounded Retry-After overrides the backoff; delays above 30 seconds return a pause request immediately. Initial-origin 401/403 are permanent. A CDN 401/403 refreshes the fixed resolve URL for a new signed redirect, under the same attempt ceiling. Requests have a 60-second idle timeout and no short total weight-download deadline.
- Redirects are explicitly processed from HTTP responses, with URLSession automatic forwarding disabled. Only HTTPS targets without userinfo/fragments are accepted, with at most five hops. Bearer authorization starts only for exact HTTPS huggingface.co:443 and narrows permanently on any cross-origin hop. Mirrors/custom endpoints remain anonymous and do not read the credential store. Only the explicit `asr.hf.official` reference is accepted.
- Cancellation cancels the active URLSession task, waits for its final serial delegate callback, synchronizes/closes the handle, then returns cancelled. The sink emits no callbacks or writes after that return. Partial bytes/sidecar remain available for explicit resume. B4 owns generation suppression for callbacks received before drain completes.

## Approved ownership / B4 handoff

Controller explicitly approved transport-owned adjacent per-file sidecars, distinct from the coordinator's job journal.

```swift
let transport = HFDownloadTransport() // production: isolated ephemeral URLSession + explicit credential reference only
try await transport.transfer(file: plannedFile, partialURL: ownedStagingFile,
                             credentialID: plan.credentialID, progress: receiveWrittenFileBytes)
```

- `partialURL` must be in the caller-owned isolated job/staging directory. B4 must not mutate the partial or its sidecar while a transfer is running. A transfer is the ownership interval; await its task result after cancellation before releasing the slot or deleting files.
- `HFDownloadJournal.sidecarURL(for:)` derives `<partial>.hf-journal.json`. The helper `read(for:)` is size-limited and accepts regular files only. B4 can inspect it after drain, but transport is its sole writer.
- On verified completion only the sidecar is removed. The verified partial remains at exactly `partialURL` for B4's atomic publication. The transport never registers an installation or changes selection.
- Progress is the absolute current file byte count, not a delta; it can restart at zero when an ignored Range response truncates a partial. B4 sums completed files and the current file, with generation checks. B4 must catch `HFDownloadError.requiresPause` and display `retryAfter` as the server-requested delay.
- Tests can inject URLSessionConfiguration (custom URLProtocol), a memory credential store, an async sleeper and a chunk writer. The default sleeper uses Task.sleep; the default writer uses FileHandle.write. No response/byte-state test hooks are embedded in the production state machine.

## TDD and verification evidence

All commands ran sequentially, with no competing build/self-test processes. Initial compile RED and final build/focused output are in this ignored task workspace. The initial runtime RED below was observed in the session; its focused log was overwritten by the final rerun, so the quoted failures and counts below are the retained evidence for that run.

Initial RED — tests and runner integration were written before the implementation files:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B3-red.log 2>&1
# exit 1
# error: cannot find type 'HFDownloadTransport' in scope
# error: cannot find type 'HFDownloadError' in scope
```

This was an absent-API compile RED, not a claimed successful runtime test. The first implementation then built successfully (`Build complete! (28.00s)`). Its focused runtime run was genuinely RED:

```sh
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B3-focused.log 2>&1
# exit 1; HF install self-test: 257 passed, 10 failed
# FAIL: B3 range 206: ... integrity ...
# FAIL: B3 range 200: ... integrity ...
# FAIL: B3 valid 416: ... integrity ...
# FAIL: B3 refreshed resolve: ... integrity ...
# FAIL: B3 bounded streaming: ... integrity ...
```

Root cause: URL resource-value file sizes were cached on the same URL instance before writes. The verifier and range logic saw stale lengths after the stream changed the file. Replaced those lookups with fresh FileManager attributes, retaining regular-file checks. Corrected one fixture assertion at the same time: a short valid file with its own correct manifest is not truncation; the truncation fixture must retain the eight-byte manifest.

Final GREEN:

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B3-build.log 2>&1
# exit 0; Build complete! (27.00s); no compiler warnings
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B3-focused.log 2>&1
# exit 0; HF install self-test: 273 passed, 0 failed
```

The final focused run includes B1/B2 plus B3. B3 exercises:

- partial four bytes + correct 206 start/total; ignored Range 200 truncation; wrong start restart; wrong total rejection;
- valid complete 416 digest acceptance and corrupt complete 416 restart;
- expired signed CDN URL renewed through the same fixed commit resolve URL; explicit official auth; CDN auth stripping; anonymous mirror; unsafe redirects and five-hop ceiling;
- correct SHA256 and Git blob SHA1; same-length corruption; zero bytes; truncated files; HTML and LFS pointer rejection even with matching synthetic digest;
- 503 retries, permanent 401/403/404 behavior, three-attempt ceiling, Retry-After 7 seconds and long Retry-After 31-second immediate pause;
- injected ENOSPC; validator change; removal of truncated/bad partial;
- URLProtocol asynchronously emits 128 chunks with cancellation during the stream; progress and fresh file size remain unchanged after cancellation returns;
- a 1 MiB streamed fixture passes through the production delegate/writer, verifies exact output and observes maximum 64 KiB disk writes.

Retry clock injection records requested waits without sleeping: `[1, 2]` for two 503 responses followed by success, and `[7]` for bounded Retry-After. Cancellation uses short fixture pacing solely to expose the live transfer; no production retry wall-clock waits occur in these tests.

`git diff --check` passed. Package.swift and Package.resolved are unchanged. No full suite, actual model weights, live service/network, microphone, real credential store or user configuration checks were performed or claimed.

## Files changed

- `Sources/flowtype/Services/Speech/ModelInstallation/HFDownloadTransport.swift`
- `Sources/flowtype/Services/Speech/ModelInstallation/HFDownloadJournal.swift` (journal, stable error and file verifier)
- `Sources/flowtype/Testing/HFDownloadSelfTests.swift`
- `Sources/flowtype/Testing/HFInstallSelfTests.swift`

## Self-review

Read the complete new files and runner diff after GREEN. Checked payload API usage, per-file ownership, immutable resolve construction, exact-origin bearer scope, redirect ceiling, bounded writes/reads, digest header format, failure cleanup, retry bounds, and the cancellation continuation ordering. No unresolved implementation concern found. Production timeout behavior is configured through URLSession and has not been validated against a real network stall; this is fixture verification, not remote/service sign-off. The journal/writer boundary is caller-owned staging; B4 must enforce that ownership and its separate job-level durability/free-space/publication rules.

## Review fix round 1 — I1 creation ENOSPC and M1 verified-416 cancellation

Base: `958b4a9`. Fix commit: `15f158f` — `fix: preserve ASR creation disk-full errors and cancellation`. Read `task-B3-review.md`; addressed important I1 and the related minor M1 in the same bounded fix wave. No additional feature scope.

### Changes

- Replaced Boolean `FileManager.createFile` with a throwing, exclusive empty `Data.write(to:options: .withoutOverwriting)` creation. Creation failures now preserve the actual NSError/underlying errno through the existing `HFDownloadError.disk` classifier. ENOSPC returns `diskFull` and does not enter transient network retry logic. Exclusive creation also refuses to overwrite a partial appearing between the existence check and creation.
- Added optional injected `FileCreator` and `FileVerifier` I/O dependencies. Defaults retain actual filesystem creation and the real streaming digest verifier. The creation seam exercises failure before a FileHandle or journal exists; it does not rely on the later chunk writer. The verifier seam permits cancellation exactly after a real successful hash without an unreliable large-file timing race.
- Verified-416 success now performs the same final `Task.checkCancellation()` as ordinary download completion. Cancellation observed during verification returns `cancelled` after the delegate has already drained, while retaining the verified file.
- Added focused fixtures for initial creation ENOSPC (one creation/request, no backoff, no progress, no partial or sidecar), resumed writer ENOSPC (one request, no backoff, existing four bytes preserved, no recreation), and deterministic cancellation at real 416 digest verification (cancelled, one request, no progress, full partial retained). Existing cancellation/drain and streaming fixtures remain enabled.

### Exact RED evidence

Dependency extraction first preserved the old lossy creation branch for the regression run: its injected throwing creation result was reduced to the same Boolean/network error behavior. The default still used the original FileManager creation. The existing missing cancellation check was unchanged. Only after observing RED were creation propagation/default creation and the final cancellation check fixed.

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B3-fix1-red-build.log 2>&1
# exit 0; Build complete! (32.26s); no warnings
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B3-fix1-red-focused.log 2>&1
# exit 1
```

Retained output:

```text
  ✗ FAIL: B3 create ENOSPC is diskFull — got Optional(FlowType.HFDownloadError.Code.network), want Optional(FlowType.HFDownloadError.Code.diskFull)
  ✗ FAIL: B3 verified 416 cancellation must throw
=== FlowType --self-test ===
=== HF install self-test: 288 passed, 2 failed ===
```

### Exact GREEN evidence

```sh
swift build > .superpowers/sdd/2026-11-09-asr-model-center/B3-fix1-green-build.log 2>&1
# exit 0; Build complete! (27.69s); no warnings
.build/debug/FlowType --self-test --hf-install-only > .superpowers/sdd/2026-11-09-asr-model-center/B3-fix1-green-focused.log 2>&1
# exit 0
```

Retained output:

```text
=== FlowType --self-test ===
=== HF install self-test: 290 passed, 0 failed ===
```

Build and focused runner were sequential. `git diff --check` passed. Reviewed the transport and fixture diff after GREEN; confirmed creation NSError propagation, no ENOSPC retry, existing-partial preservation, and the 416 cancellation boundary. No unresolved review issue. Package files are unchanged. No full suite or real filesystem-exhaustion/live-network/user-state check was run or claimed.

Files changed: `HFDownloadTransport.swift`, `HFDownloadSelfTests.swift`; this report appended in the ignored task workspace. Production call sites remain source compatible because both new dependencies default to nil.
