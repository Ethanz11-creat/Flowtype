import Foundation
import os

/// Capture progress and a serviced monotonic watchdog share one attempt owner.
/// The frozen notification always precedes stream completion.
final class RecordingHeartbeat: @unchecked Sendable {
    private struct State {
        var ownerID: UInt64?
        var generation: UUID?
        var lastProgress: TimeInterval = 0
        var timer: DispatchCancellableTimer?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let now: @Sendable () -> TimeInterval

    init(interval: TimeInterval = 2, timeout: TimeInterval = 5,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.timeout = timeout
        self.now = now
    }

    func start(ownerID: UInt64, isActive: @escaping @Sendable () -> Bool,
               onFrozen: @escaping @Sendable () -> Void, finish: @escaping @Sendable () -> Void) {
        let generation = UUID()
        let timer = DispatchCancellableTimer()
        let timestamp = now()
        let previous = state.withLock { state in
            let previous = state.timer
            state.ownerID = ownerID
            state.generation = generation
            state.lastProgress = timestamp
            state.timer = timer
            // Register before releasing ownership. A concurrent stop cannot
            // cancel an unregistered timer which setup would then resurrect.
            timer.schedule(withTimeInterval: interval, repeats: true) { [weak self] in
                guard let self, isActive() else { return }
                let timestamp = self.now()
                let expired = self.state.withLock { state -> DispatchCancellableTimer? in
                    guard state.ownerID == ownerID, state.generation == generation,
                          timestamp - state.lastProgress > self.timeout else { return nil }
                    let timer = state.timer
                    state.generation = nil
                    return timer
                }
                guard let expired else { return }
                expired.cancel()
                guard isActive() else { return }
                onFrozen()
                finish()
            }
            return previous
        }
        previous?.cancel()
    }

    func recordTap(ownerID: UInt64) {
        let timestamp = now()
        state.withLock { state in
            guard state.ownerID == ownerID, state.generation != nil else { return }
            state.lastProgress = timestamp
        }
    }

    func cancel(ownerID: UInt64) {
        let timer = state.withLock { state -> DispatchCancellableTimer? in
            guard state.ownerID == ownerID else { return nil }
            let timer = state.timer
            state.ownerID = nil
            state.generation = nil
            state.timer = nil
            return timer
        }
        timer?.cancel()
    }

    deinit { state.withLock { $0.timer }?.cancel() }
}
