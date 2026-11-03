# Independent whole-core code review — 2026-11-03

Follow-up on 2026-11-04: CORE-01–04 were repaired and independently rereviewed; full self-tests passed 25,920/0 and all 24 technical gate phases passed. See the [repair evidence and remaining manual acceptance](../2026-11-03-core-review-fixes/README.md). This report retains its original reviewed baseline and findings.

Reviewed checkout: `2fff1c7e55c793a39d5e8efb1926e0b75ee20882`; historical comparison base: `6aa27fba88fc2dbeb4b41db1ec1088a5220fe5ad`. This is a review of current production call chains, not approval based on the latest capsule diff or previous passing counts. Product source, index and HEAD were not changed. Only this report was authored.

**Result: changes required. Four Important findings; no Critical finding established.** Two affect all relevant text/Unicode paths; two affect the real capture/Apple-preview lifecycle. These are existing core defects, not missing Typeless parity features. Fix and focused regression coverage are needed before treating this candidate as core-ready. Real microphone, provider and application acceptance remain separate Pending evidence.

## Scope and evidence standard

Read the assigned reviewer brief first. Applied the requesting-code-review review criteria as the independent reviewer; no further agents were spawned. Inspected the actual default pipeline and controller ownership/transition/finish/retry/history paths, trigger detector/event tap, readiness aggregation, AudioRecorder and recording unwind, route snapshots/registry, batch and realtime adapters, local Qwen/Whisper lease and inference boundaries, preprocessing/refinement/context, delivery policy/transactions, recovery/resource leases, capsule presentation, settings change coordination and trial pipeline. Selected tests were read to distinguish real coverage from substituted boundaries.

The Typeless report and P2/P3 notes were discovery material, qualified by FlowType's 2026-10-14 evidence recheck and M4 research. Direct recovered-source spot checks included `qA149QP2.mjs:3853–3869` (insertion occurs before that caller's editability branch), `UfR9-a2Z.js:8301–8358` (per-audio WS/HTTP final-result race and cleanup), and `main/index.js:11714–11726` (500 ms wrapper wait, not acknowledgment). No competitor app, user data or network was accessed. None of the findings below depends on asserting unknown Typeless native or server behavior.

Intentional FlowType differences remain valid: native Swift/AppKit, local and imported Qwen/Whisper plus BYOK, provider capability filtering, final-only presentation/insertion, conservative silence detection, and no automatic resend after uncertain delivery. Accounts, commercial services, sync, translation and command modes are capability gaps, not defects to implement through this review.

## Strengths established from source

- `SessionController` and `SessionContext` consistently use session/context identity and committed presentation generations to reject stale stage, timer and UI results. Typed recovery actions are card-owned; ordinary retry is restricted to retained ASR audio and cannot replay delivery.
- `ASRRouteSnapshot` retains provider identity, credentials, protocol, language and local lease at capture start. Realtime ingress includes queued/in-flight audio in its five-second bound; full local PCM remains separate. Paraformer finals are keyed by begin time, foreign task IDs are filtered, and a saved-audio retry creates a fresh realtime attempt.
- ASR candidates share a monotonic stop budget and optional polish consumes its remainder. Deadline wrappers avoid joining uncooperative producers. Qwen/Whisper inference serialization protects their individual retained runtimes after caller cancellation.
- Context collection is bounded and off the UI actor; secure AX fields are guarded. ASR and polish context opt-outs are applied at their request boundaries. Realtime Paraformer does not receive a fabricated foreground-prompt field.
- Paste has an initial/fresh target gate, complete clipboard representation snapshots, change-count ownership, serialized cleanup, balanced events and an event/effect distinction. Uncertain delivery retains copyable text and never automatically retries. Automatic typing fallback has per-pair revalidation; the missing equivalent on the primary typing path is CORE-02 below.
- Trial reuses capture/ASR/processing but substitutes scoped result delivery, without automatic clipboard insertion or ordinary history saving. Capsule notices and slow progress do not confer lifecycle or retry authority.

## Findings

### CORE-01 — Important: preprocessing corrupts numeric and coding literals before the preservation guard

**Locations:** `Sources/flowtype/Services/Speech/ASRPostProcessor.swift:161`, `:262`, `:267`; production entry `Sources/flowtype/Core/Pipeline/Stages/PostProcessStage.swift:35`; downstream `Sources/flowtype/Core/Pipeline/Stages/PolishStage.swift:107`, `:143`.

**Trigger:** a successful ASR transcript contains repeated digits/identifier characters, or Chinese prose around URL queries/code punctuation. This occurs with polish disabled, unavailable or enabled.

**Expected:** preserve the recognized number, explicit code content and URL while cleaning ordinary prose. This follows the delivery-accuracy requirement to preserve numbers, paths, URLs and code literals, and reasonable dictation expectations independently of competitor behavior.

**Actual:** the unconditional preprocessing chain applies repetition cleanup and punctuation conversion to the whole transcript. `fixCommonASRErrors` reduces any non-whitelisted run of four or more identical Characters to two, including digits and backtick content. Punctuation conversion unconditionally converts `?`/`!` in Chinese-dominant text and converts a terminal closing code parenthesis. The later polish literal check compares the LLM output to **already processed** `fallback`, not the original transcript. Raw mode directly returns this processed fallback, so the preservation guard cannot repair or even detect these earlier changes.

**Focused production-source experiment:** executed the unchanged complete `ASRPostProcessor.swift` through Swift stdin, with only a no-op logger and an AppResources shim pointing at the actual bundled JSON resource paths. No model, network, clipboard or source file write. Exit 0; observed:

```text
金额是10000元 => 金额是100元
变量是 `aaaa` => 变量是 `aa`
请打开这个地址 https://a.co/?x=1 => 请打开这个地址 https://a.co/？x=1
请运行 foo() => 请运行 foo(）
```

**Impact:** silently wrong amounts/IDs and unusable URLs/code can be delivered once and persisted as the final result. A successful LLM response may preserve the damaged value and still pass validation.

**Fix direction:** protect numeric/coding literal spans across the complete postprocess chain, or validate processed output against original recognized literals and fall back to the complete original where damaged. Keep ordinary filler/repetition/prose behavior deliberately scoped. Protect code punctuation as well as digit runs; merely changing the polish prompt does not fix the defect.

**Missing test:** run real PostProcessStage → PolishStage → delivery payload capture with the examples above, both polish-off and completed-polish/fallback cases. Existing `preservesCodingLiterals` tests start at the preservation helper/PolishStage and therefore miss damage in the preceding production stage.

**Provenance:** numeric collapse and unconditional punctuation behavior are already present at the historical base. Current later literal protection does not cover them. This is not attributed to the capsule change.

### CORE-02 — Important: primary Unicode delivery stops rechecking the target after its initial gate

**Locations:** `Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift:92`, `:145`, `:152`; `Sources/flowtype/Services/KeyboardInjector.swift:84`–`:95`. Compare the explicit fallback validator at `InjectionStage.swift:115`–`:125`.

**Trigger:** select `.unicode`, or `.pasteInSupportedApps` in an app that takes the typing path. Begin a multi-chunk/newline result in the correct stop-time field, then change application/focused element or enter a secure/non-text field during an inter-pair suspension. A 20,000-character result has over 300 pair boundaries and approximately 1.25 seconds of configured waits even without other delays.

**Expected:** stop dispatching when the destination no longer matches the saved target or becomes unsafe. If an event has already escaped, retain an uncertain result without copying/retrying the whole text. If no event escaped, retain recoverable text. Preserve the intended unknown-focus compatibility policy rather than imposing the stricter fallback-only admission policy everywhere.

**Actual:** the initial target/accessibility gate exists and is useful; it is not the missing part. The `.type` arm calls `typeText` without a validator, so its default `{}` is forwarded to the real Unicode loop. Each loop iteration executes that empty closure, then posts globally. Cancellation is checked, but target identity, safety and permission are never resampled after the initial gate. The automatic paste-failure fallback supplies a real per-pair validator and therefore does stop correctly in the same scenario.

**Impact:** the remaining transcript may be typed into a different application/field, potentially a password field or command destination, and the session can still be recorded as `typedDispatched`. This is a destination-safety bug, not a request for Typeless feature parity or proof that Typeless handles the race correctly.

**Fix direction:** give the primary typing path a fresh per-pair target/accessibility validator, including the first pair and newline boundaries. Apply its existing primary-path unknown-focus policy while retaining the fallback path's stricter explicit-editability rule. Reuse the current first-event/uncertain handling; never restart partial typing.

**Missing test:** parameterize the real typing-loop boundary tests for `.unicode` and non-paste legacy mode. Change PID, known focus identity, secure/non-text signal or permission after one prepared/dispatched pair and require zero subsequent posts. `M3FinalFixSelfTests.targetChanges` exercises automatic paste fallback, so it does not establish safety of this arm.

**Provenance:** primary Unicode insertion without target revalidation exists at the historical base; subsequent fallback fixes narrowed that path's protection without fixing the primary arm. Not a new capsule regression.

### CORE-03 — Important: Apple preview completion synchronously reacquires its held unfair lock

**Locations:** `Sources/flowtype/Services/Speech/AppleSpeechProvider.swift:186`, `:203`, `:215`, `:220`–`:234`.

**Trigger:** Apple on-device preview has started and its recognition callback reports an error or final result. The preview timeout closure also contains the same problem if its timer fires. RecordingStage starts this preview alongside ordinary local/cloud dictation; preview is optional but the defect can affect the shared recording session.

**Expected:** finish the preview stream and release its resources without blocking capture, Stop or cancellation, regardless of whether it will be used as an ASR fallback.

**Actual:** error/final/timeout branches call `previewContinuation.finish()` inside `stateLock.withLock`. The installed `continuation.onTermination` calls `stopStreamingRecognition()`, whose first operation acquires the **same nonrecursive OSAllocatedUnfairLock** at line 234. AsyncStream invokes the termination callback synchronously from `finish()`. This is a reentrant lock acquisition, which can trap or block rather than returning to the recognizer/recording path. Cancellation of the recognition task under that same lock is a related call-out that should also be moved out of the critical section.

**Focused framework-semantics experiment:** used a standalone `AsyncStream.makeStream`, installed an onTermination callback that safely probes an NSLock with `try()`, held the lock around `finish()`, and printed ordering. No real recognizer or deliberately deadlocking process was run. Exit 0:

```text
calling finish under lock
onTermination ran before finish returned; same lock available: false
finish returned
```

This verifies synchronous reentry; the nonrecursive production lock and reentrant call chain are visible in source. The experiment does not claim a live Speech-framework acceptance result.

**Impact:** a normal preview error/final can interrupt or hang dictation even when the chosen main ASR engine is healthy; later stop cleanup also needs this lock. Existing cancellation/resource-drain correctness cannot compensate for a synchronous lock trap/deadlock inside the preview implementation.

**Fix direction:** atomically take/clear continuation, request and task references under the lock, then perform finish/endAudio/cancel outside it. Make stop/termination cleanup idempotent and keep framework calls outside the nonrecursive critical section.

**Missing test:** exercise the real preview state/termination owner with synthetic recognition final/error/timeout signals, verifying stream termination plus repeated stop/cancel completes. Recording-stage tests substitute `RecordingPreview`, and therefore cannot detect this implementation-level recursion.

**Provenance:** the same locked finish and onTermination→stop chain is present at the historical base. Not introduced by current capsule changes.

### CORE-04 — Important: the capture heartbeat timer is installed on an unserviced worker RunLoop

**Locations:** `Sources/flowtype/Services/AudioRecorder.swift:106`–`:117`, `:227`–`:249`; `Sources/flowtype/Utilities/CancellableTimer.swift:22`; call site `Sources/flowtype/Core/Pipeline/Stages/RecordingStage.swift:128` and stream wait `:160`.

**Trigger:** normal nonisolated async recording startup schedules the heartbeat, then the input device stops delivering tap callbacks without an engine-start exception (for example a frozen/disconnected device). First-buffer-never-arrives is also affected.

**Expected:** the two-second heartbeat checks progress and, after the configured no-callback threshold, invokes `onRecordingFrozen` before finishing visualization. RecordingStage should produce typed recording-interrupted recovery instead of hanging or accepting a healthy-stop payload.

**Actual:** `AudioRecorder.startRecording` is explicitly nonisolated async; after permission it calls synchronous `startEngine` on the generic executor. That function uses `CancellableTimer.schedule`, which calls `Timer.scheduledTimer` on the **current thread's RunLoop**. Generic executor workers do not service that RunLoop. No code adds this heartbeat timer to a running main RunLoop or drives the worker loop. Therefore the callback that sets `frozen` and finishes the visualization stream normally never runs. The same timer helper is also used by Apple preview from its nonisolated async startup; fixing the recording heartbeat should not leave that occurrence unchecked.

**Focused production-helper experiment:** executed the unchanged complete `CancellableTimer.swift` under Apple Swift 6.2.1 with `-swift-version 6`. An `@MainActor` task awaited a nonisolated async function, matching the production actor hop. It scheduled a 20 ms repeating timer, suspended for 150 ms, then read a lock-protected callback count and cancelled. Exit 0:

```text
nonisolated async scheduling on main thread: false
scheduled timer callback count after 150ms: 0
```

The first draft of this small probe did not compile because Swift 6 forbids reading `Thread.isMainThread` directly in an async function; a synchronous read helper corrected that probe. This was not a product build/test failure. No hardware or full suite was run.

**Impact:** a stopped tap can leave the UI preparing/recording until explicit stop/cancel or the independent duration limit. After an already-ready stream freezes, explicit stop can see `frozen == false` and continue partial captured audio as an ordinary successful recording, bypassing the intended interruption recovery.

**Fix direction:** give heartbeat scheduling/cancellation one serialized owner on a serviced executor. A DispatchSourceTimer on a known queue or an owned cancellable task with monotonic waits avoids thread-local RunLoop dependence. Preserve session owner checks and notify-frozen-before-stream-finish ordering. Do not move conversion/model work to MainActor to repair the timer.

**Missing test:** test the real watchdog scheduler from nonisolated async startup with synthetic tap-progress/time input and no microphone. Existing `RecordingStageTerminationSelfTests.Capture.freeze()` directly invokes the frozen callback and finishes its fake stream; that validates downstream unwind but bypasses the defective scheduler entirely. Keep physical unplug/Bluetooth tests Pending separately.

**Provenance:** nonisolated async start and the heartbeat's current-runloop timer scheduling already exist at the historical base. Not a capsule regression.

## Declined judgments and explicit non-findings

- Did not infer normal hold-to-talk behavior from Typeless's 600 ms branch, paste acknowledgment from its 500 ms wait, visible partial text from an internal partial buffer, or reconnect/resume from its WS/HTTP result race. The recovered source and corrective research do not establish those claims.
- Did not report insertion duration beyond 20 seconds as a completion-budget defect: FlowType's realtime design explicitly bounds stop-to-ready-text and excludes long system insertion time. ASR/polish budgets and resource cancellation were inspected; large-text delivery timing is a separate runtime measurement.
- Apple preview fallback can promote preview text after primary failure. This is deliberately retained in FlowType's routing design and M4 tests, including restricted routing modes as an internal fallback, so its existence was not reported as a newly unauthorized cloud/local engine switch. Completeness/long-recording quality remains an acceptance concern, distinct from the lock bug.
- Did not treat localOnly as disabling explicitly enabled cloud text polishing: current product specification and settings distinguish local ASR from optional BYOK text processing; foreground context is separately gated. No prohibited ASR socket or probe under captured localOnly was established.
- No fresh clipboard-loss, duplicate-delivery, stale-card retry or captured-route substitution defect was established in the inspected paths. This is source evidence, not proof that all applications consume clipboard contents within 150 ms or that keyboard submission confirms insertion.
- Hardware model memory/accuracy, imported model inference correctness on actual files, real vendor response timing/schema variations, network switching, permissions/TCC, microphone unplug/reconnect, actual target-app insertion, concurrent external clipboard copies, window animation/layout/accessibility and visual waveform calibration were not executed. They remain manual/capability evidence gaps, not invented failures or passes.
- ASR/LLM server internals, Typeless native paste implementation and unrecovered competitor entry points remain Unknown. No claim of total competitor equivalence is justified.

## Reproduction commands for the focused experiments

Run from the reviewed repository root. These feed source to the Swift interpreter over stdin; no temporary source path was created and no app/services are initialized. Toolchain observed with `swift -version`: Apple Swift 6.2.1, target `arm64-apple-macosx15.0`. The first two commands use the interpreter's default language mode; the timer probe explicitly uses Swift 6 mode. Each corrected probe exited 0 with the exact outputs quoted above.

CORE-01:

```sh
python3 - <<'PY'
from pathlib import Path
import subprocess
source = Path('Sources/flowtype/Services/Speech/ASRPostProcessor.swift').read_text()
shim = '''import Foundation
enum AppLogger { static func log(_ text: String) {} }
enum AppResources {
  static func url(forResource name: String, withExtension ext: String) -> URL? {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Sources/flowtype/Resources/" + name + "." + ext)
  }
}
'''
check = '''
for input in ["金额是10000元", "变量是 `aaaa`", "请打开这个地址 https://a.co/?x=1", "请运行 foo()"] {
  print(input + " => " + ASRPostProcessor.process(input))
}
'''
r = subprocess.run(['swift', '-'], input=shim + source + check,
                   text=True, capture_output=True, timeout=50)
print(r.stdout); print(r.stderr); print('exit:', r.returncode)
PY
```

CORE-03 (safe synchronous-callback probe, not an intentional unfair-lock crash):

```sh
swift - <<'SWIFT'
import Foundation
let pair = AsyncStream<String>.makeStream()
let callbackLock = NSLock()
pair.continuation.onTermination = { _ in
    let acquired = callbackLock.try()
    print("onTermination ran before finish returned; same lock available: \(acquired)")
    if acquired { callbackLock.unlock() }
}
callbackLock.lock()
print("calling finish under lock")
pair.continuation.finish()
print("finish returned")
callbackLock.unlock()
SWIFT
```

CORE-04:

```sh
python3 - <<'PY'
from pathlib import Path
import subprocess
source = Path('Sources/flowtype/Utilities/CancellableTimer.swift').read_text()
check = r'''
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func fire() { lock.lock(); count += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
func onMainThread() -> Bool { Thread.isMainThread }
func scheduleLikeAudioRecorder() async {
    let flag = Flag()
    var timer = CancellableTimer()
    print("nonisolated async scheduling on main thread: \(onMainThread())")
    timer.schedule(withTimeInterval: 0.02, repeats: true) { flag.fire() }
    try? await Task.sleep(for: .milliseconds(150))
    print("scheduled timer callback count after 150ms: \(flag.read())")
    timer.cancel()
}
Task { @MainActor in await scheduleLikeAudioRecorder(); exit(0) }
dispatchMain()
'''
r = subprocess.run(['swift', '-swift-version', '6', '-'], input=source + check,
                   text=True, capture_output=True, timeout=20)
print(r.stdout); print(r.stderr); print('exit:', r.returncode)
PY
```

## Readiness assessment

**Not ready for core/release sign-off.** CORE-01 and CORE-02 violate text fidelity and destination safety in real current production wiring. CORE-03 and CORE-04 expose defects hidden by the existing fake preview/capture boundaries and require implementation-level lifecycle regressions. All four predate the latest capsule work; they remain relevant because this requested review covers the whole current core chain.

The previous 25,555/0 code gate and 22/22 artifact checks are historical candidate evidence, not proof against these uncovered cases. This review did not rerun them. After repairs, run focused regressions for the identified boundaries, then the required candidate-matched gates and outstanding real microphone/provider/cross-app acceptance; do not silently expand this review into parity feature development.
