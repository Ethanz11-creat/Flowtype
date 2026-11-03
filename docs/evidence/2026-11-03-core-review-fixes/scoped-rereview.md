# Independent scoped rereview — CORE-01–04

Reviewed base `2fff1c7e55c793a39d5e8efb1926e0b75ee20882` against the working-tree repairs, including the new untracked production owners and regression files. Final rereview occurred on 2026-11-04 Asia/Shanghai after the CORE-01 followups. Applied the requesting-code-review criteria; no further agents were dispatched. Product source, index and HEAD were not modified by this reviewer. This report is the only authored repository file.

**Result: all four original findings addressed in the final reviewed source; no remaining Critical or Important issue established within this repair scope.** Candidate build/test/artifact gates belong to the parent task and remain a condition of code readiness. This is not live hardware/provider/application acceptance or release sign-off.

## Strengths and disposition

| Finding | Status | Evidence and reasoning |
| --- | --- | --- |
| CORE-01 — literal corruption before preservation | Addressed | `ASRPostProcessor.swift:17` captures explicit literals before all cleanup rules, accepts each full-text rule only if ordered exact literals remain, and preserves original boundaries. Punctuation conversion uses full-text context and skips protected UTF-16 spans (`:224`). ASCII digit/identifier repetition is no longer shortened. Quotes, escaped quoted content, JSON values, URLs including apostrophes/Unicode data, paths, flags, function calls and backticks are protected. |
| CORE-02 — primary typing lacks target revalidation | Addressed | Both `.type` and automatic fallback pass `typingValidator` (`InjectionStage.swift:92`, `:116`, `:182`) to the real `KeyboardInjector` loop. That loop validates after preparing each pair and before posting, including the first pair and newline boundaries. Primary typing permits same-process unknown AX according to existing `decideDelivery`; automatic fallback still additionally requires explicit editable focus. Permission, PID, known identity and unsafe focus changes stop further pairs. Existing event evidence determines clipboard/cancelled versus uncertain outcome, without restarting partial delivery. |
| CORE-03 — preview finish reacquires held lock | Addressed | `StreamingPreviewSession.swift:35` and `:57` claim state under their lock, then yield/finish/cancel timers and invoke resource cleanup outside it. Cleanup installation after termination immediately releases the newly returned resource. Final ownership rejects late result replacement. `AppleSpeechProvider.swift:178` stores the request/session pair under its separate lock and captures the attempt session directly in recognition callbacks; request/framework cleanup is outside provider and session locks. Reentrant stop is idempotent. |
| CORE-04 — heartbeat on an unserviced RunLoop | Addressed | `DispatchCancellableTimer.swift:18` schedules a dispatch source on its serviced serial queue with monotonic deadlines and generation invalidation. Cancel drains an already-running callback outside the state lock and avoids synchronously dispatching onto its own queue. `RecordingHeartbeat.swift:25` is the actual production owner wired from `AudioRecorder.swift:228`, records actual tap progress at `:244`, and notifies frozen before finishing visualization. Start registers before releasing watchdog ownership; stale owner progress/cancel cannot affect its replacement. AudioRecorder cancellation does not hold a lock required by the current frozen callback. Apple preview timeout uses the same serviced timer implementation. |

## Review findings resolved during this pass

The first reviewed CORE-01 implementation had two Important gaps: quoted Chinese/JSON values still underwent repetition cleanup, and cleaning fragments independently created artificial filler/punctuation boundaries. Concrete triggers included `字段值为 "回头回头回头"` becoming `字段值为 "回头"`, `这个10000元的预算` losing `这个`, and `预算(10000)` becoming `预算（10000)`. These were reported promptly and fixed by quoted-literal protection plus full-text rule validation and punctuation context.

A subsequent production-source probe established another URL fidelity gap: `打开 https://a.co/?q=it's&重复=回头回头回头` lost repeated query text because the URL matcher stopped at the apostrophe. The final URL matcher accepts apostrophes and conservatively includes ambiguous punctuation. The added fixtures cover both an ordinary apostrophe query and a query beginning with an apostrophe, as well as a surrounding single-quoted URL. No corresponding open finding remains in the final inspected revision.

## Regression coverage and verification limits

Read the actual `CoreTextFidelitySelfTests.swift`, `CoreLifecycleRegressionSelfTests.swift`, modified `M3FinalFixSelfTests.swift`, and both focused/full `SelfTest.swift` registrations. Text tests traverse real PostProcess → Polish → Injection stage composition for raw, completed echo and failed polish, substituting only the external stream and delivery effect. Primary typing tests use the real chunk loop and distinguish first-pair, chunk and newline target changes, unknown-focus compatibility, cancellation and escaped-event outcomes. Lifecycle tests exercise the production preview/session, dispatch timer and watchdog owners rather than merely invoking a fake downstream frozen callback.

The final reviewer verification executed the complete current `ASRPostProcessor.swift` through isolated Swift stdin with only no-op logging/resource lookup shims. **12 focused comparisons, 0 failures, interpreter exit 0.** They covered quoted repetition, JSON, full-context parentheses, original filler boundaries, punctuation following literals, escaped quotes, a non-BMP prefix, URL apostrophe query variants and surrounding single quotes. Earlier probes reproduced the reported failures before their repairs. No shared `.build` command, package/full suite or artifact gate was run by this reviewer; parent-owned results must be matched to the final candidate.

No microphone, Speech permission/recognizer, cloud/model request, keyboard event, clipboard effect, app installation or push was performed. Real Speech callback behavior, physical microphone starvation/unplug/Bluetooth recovery, permission changes and cross-application delivery remain separate Pending acceptance work. Synthetic cleanup and scheduler evidence does not turn those into passes.

## Declined to judge and accepted limits

- Whole-rule rejection can retain ordinary filler/spacing when the same rule would damage a protected literal; for example the filler rule's internal whitespace normalization would change multiline backtick code. This is an accepted conservative fidelity tradeoff, consistent with the original review's allowed original-text fallback; it is not a claim that every mixed code/prose cleanup remains identical.
- Ambiguous punctuation adjoining a URL is preserved as possible URL data. Choosing its linguistic meaning requires information not present in the transcript; preservation is appropriate for this repair.
- Did not expand these fixes into new routing, Typeless parity, partial-preview presentation, automatic resend, new quote-language parsing or real target-app insertion guarantees. These are outside the four identified repairs.
- Did not judge hardware quality/accuracy, actual Speech-framework scheduling, vendor timing/schema behavior, imported models, TCC or real clipboard/application consumption from synthetic tests.

## Readiness

**Ready for the scoped code repair, subject to the parent completing candidate-matched required gates.** No further source change is requested from this rereview. Full release readiness still requires the already documented manual acceptance evidence; this report establishes neither those passes nor an independent full-suite run.
