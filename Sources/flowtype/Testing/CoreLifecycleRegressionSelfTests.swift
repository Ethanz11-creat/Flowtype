import Foundation
import os

/// Exercises the same continuation/cleanup owner and queue-backed timer used by
/// capture, without requesting permissions or constructing Speech/AV resources.
enum CoreLifecycleRegressionSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        for terminal in ["final", "error", "stop"] {
            let pair = AsyncStream<String>.makeStream()
            let owner = StreamingPreviewSession(continuation: pair.continuation, timeout: 30)
            let calls = OSAllocatedUnfairLock(initialState: [String]())
            owner.addCleanup {
                calls.withLock { $0.append("end") }
                // Actual cleanup may synchronously invoke another framework
                // callback or stop. Reentrancy must be harmless and nonblocking.
                _ = owner.finish()
            }
            owner.addCleanup { calls.withLock { $0.append("cancel") } }
            owner.receive("retained partial")
            if terminal == "final" { owner.receive("complete final", isFinal: true) }
            else { _ = owner.finish() }
            let expected = terminal == "final" ? "complete final" : "retained partial"
            r.eq(owner.finish(), expected, "CORE03 \(terminal): repeated stop preserves result")
            owner.receive("late result", isFinal: true)
            r.eq(owner.finish(), expected, "CORE03 \(terminal): late callback cannot replace stopped result")
            r.eq(calls.withLock { $0 }, ["end", "cancel"], "CORE03 \(terminal): reentrant cleanup runs exactly once")
            var received: [String] = []
            for await text in pair.stream { received.append(text) }
            r.eq(received, terminal == "final" ? ["retained partial", "complete final"] : ["retained partial"],
                 "CORE03 \(terminal): actual stream drains and terminates")
            owner.addCleanup { calls.withLock { $0.append("late setup") } }
            r.eq(calls.withLock { $0 }, ["end", "cancel", "late setup"],
                 "CORE03 \(terminal): task returned after stop is immediately cleaned")
        }
        await cancellation(r)
        await timeout(r)
        await scheduler(r)
        await heartbeat(r)
    }

    @MainActor private static func cancellation(_ r: SelfTest.Reporter) async {
        let pair = AsyncStream<String>.makeStream()
        let owner = StreamingPreviewSession(continuation: pair.continuation, timeout: 30)
        let cleanups = OSAllocatedUnfairLock(initialState: 0)
        owner.addCleanup { cleanups.withLock { $0 += 1 } }
        let consumer = Task { () -> String? in
            var iterator = pair.stream.makeAsyncIterator()
            return await iterator.next()
        }
        consumer.cancel()
        r.check(await consumer.value == nil, "CORE03: stream consumer cancellation terminates")
        r.eq(cleanups.withLock { $0 }, 1, "CORE03: onTermination cleans the real owner once")
        owner.receive("late final", isFinal: true)
        r.eq(owner.finish(), "", "CORE03: cancelled stream rejects late results")
    }

    @MainActor private static func timeout(_ r: SelfTest.Reporter) async {
        let pair = AsyncStream<String>.makeStream()
        let owner = StreamingPreviewSession(continuation: pair.continuation, timeout: 0.02)
        let cleanups = OSAllocatedUnfairLock(initialState: 0)
        owner.addCleanup { cleanups.withLock { $0 += 1 } }
        owner.receive("partial")
        let result = try? await withAsyncDeadline(seconds: 1) {
            var values: [String] = []
            for await text in pair.stream { values.append(text) }
            return values
        }
        r.eq(result, ["partial"], "CORE03/04: actual queue-backed preview timeout finishes stream")
        r.eq(cleanups.withLock { $0 }, 1, "CORE03/04: timeout cleans recognition exactly once")
        r.eq(owner.finish(), "partial", "CORE03/04: timeout retains fallback text")
    }

    @MainActor private static func scheduler(_ r: SelfTest.Reporter) async {
        let outcome = await Task.detached { () -> (Bool, Int, Int, Int) in
            let repeated = OSAllocatedUnfairLock(initialState: 0)
            let obsolete = OSAllocatedUnfairLock(initialState: 0)
            let replacement = OSAllocatedUnfairLock(initialState: 0)
            let timer = DispatchCancellableTimer()
            timer.schedule(withTimeInterval: 0.005, repeats: true) { repeated.withLock { $0 += 1 } }
            // This worker has no driven RunLoop. The real timer must still fire.
            try? await Task.sleep(for: .milliseconds(60))
            timer.cancel()
            let fired = repeated.withLock { $0 }
            timer.schedule(withTimeInterval: 0.1) { obsolete.withLock { $0 += 1 } }
            timer.schedule(withTimeInterval: 0.01) { replacement.withLock { $0 += 1 } }
            try? await Task.sleep(for: .milliseconds(150))
            timer.cancel()
            let cancelled = DispatchCancellableTimer()
            cancelled.schedule(withTimeInterval: 0.01) { obsolete.withLock { $0 += 1 } }
            cancelled.cancel()
            try? await Task.sleep(for: .milliseconds(30))
            return (fired > 0, repeated.withLock { $0 } - fired,
                    obsolete.withLock { $0 }, replacement.withLock { $0 })
        }.value
        r.check(outcome.0, "CORE04: heartbeat scheduler fires from a worker without a RunLoop")
        r.eq(outcome.1, 0, "CORE04: cancelled heartbeat stops subsequent ticks")
        r.eq(outcome.2, 0, "CORE04: cancellation and replacement suppress obsolete deadlines")
        r.eq(outcome.3, 1, "CORE04: replacement deadline fires once")
    }

    @MainActor private static func heartbeat(_ r: SelfTest.Reporter) async {
        for hasProgress in [false, true] {
            let result = await Task.detached { () -> (Bool, [String], Bool) in
                let clock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
                let events = OSAllocatedUnfairLock(initialState: [String]())
                let finished = AsyncStream<Void>.makeStream()
                let heartbeat = RecordingHeartbeat(interval: 0.005, timeout: 5, now: { clock.withLock { $0 } })
                defer { heartbeat.cancel(ownerID: 1) }
                heartbeat.start(ownerID: 1, isActive: { true }, onFrozen: {
                    events.withLock { $0.append("frozen") }
                }, finish: {
                    events.withLock { $0.append("finish") }
                    finished.continuation.yield(())
                    finished.continuation.finish()
                })
                var quietBeforeExpiry = true
                if hasProgress {
                    clock.withLock { $0 = 4 }
                    heartbeat.recordTap(ownerID: 1)
                    clock.withLock { $0 = 8 }
                    try? await Task.sleep(for: .milliseconds(30))
                    quietBeforeExpiry = events.withLock { $0.isEmpty }
                }
                clock.withLock { $0 = hasProgress ? 10 : 6 }
                let observed = try? await withAsyncDeadline(seconds: 1) {
                    var iterator = finished.stream.makeAsyncIterator()
                    return await iterator.next() != nil
                }
                heartbeat.recordTap(ownerID: 1)
                try? await Task.sleep(for: .milliseconds(20))
                return (observed == true, events.withLock { $0 }, quietBeforeExpiry)
            }.value
            let label = hasProgress ? "after progress" : "before first buffer"
            r.check(result.0, "CORE04 \(label): actual watchdog detects stalled input on worker")
            r.eq(result.1, ["frozen", "finish"], "CORE04 \(label): real notification precedes stream finish exactly once")
            r.check(result.2, "CORE04 \(label): recent progress does not produce premature freeze")
        }

        let ownership = await Task.detached { () -> [String] in
            let clock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
            let events = OSAllocatedUnfairLock(initialState: [String]())
            let finished = AsyncStream<Void>.makeStream()
            let heartbeat = RecordingHeartbeat(interval: 0.005, timeout: 5, now: { clock.withLock { $0 } })
            defer { heartbeat.cancel(ownerID: 2) }
            heartbeat.start(ownerID: 1, isActive: { true }, onFrozen: { events.withLock { $0.append("stale") } }, finish: {})
            heartbeat.start(ownerID: 2, isActive: { true }, onFrozen: { events.withLock { $0.append("current") } }, finish: {
                finished.continuation.yield(())
                finished.continuation.finish()
            })
            heartbeat.cancel(ownerID: 1)
            clock.withLock { $0 = 6 }
            heartbeat.recordTap(ownerID: 1)
            _ = try? await withAsyncDeadline(seconds: 1) {
                var iterator = finished.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            return events.withLock { $0 }
        }.value
        r.eq(ownership, ["current"], "CORE04: old owner cannot cancel, refresh or notify the new watchdog")

        let stopped = await Task.detached { () -> Int in
            let count = OSAllocatedUnfairLock(initialState: 0)
            let heartbeat = RecordingHeartbeat(interval: 0.005, timeout: 0.02)
            heartbeat.start(ownerID: 3, isActive: { true }, onFrozen: { count.withLock { $0 += 1 } }, finish: {})
            heartbeat.cancel(ownerID: 3)
            try? await Task.sleep(for: .milliseconds(60))
            return count.withLock { $0 }
        }.value
        r.eq(stopped, 0, "CORE04: stopped watchdog cannot classify a normal Stop as frozen")
    }
}
