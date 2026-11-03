import Foundation
import os

/// A serviced queue, rather than the caller thread's RunLoop, owns each deadline.
/// Cancellation invalidates the generation and drains a callback already running.
/// Callbacks may cancel their own timer; no client code runs under the state lock.
final class DispatchCancellableTimer: @unchecked Sendable {
    private struct State {
        var source: (any DispatchSourceTimer)?
        var generation: UUID?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let queue = DispatchQueue(label: "app.flowtype.deadline", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()

    init() { queue.setSpecific(key: queueKey, value: true) }

    func schedule(withTimeInterval interval: TimeInterval, repeats: Bool = false,
                  block: @escaping @Sendable () -> Void) {
        let generation = UUID()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(0.001, interval)
        source.schedule(deadline: .now() + delay, repeating: repeats ? delay : .infinity)
        source.setEventHandler { [weak self] in
            guard self?.state.withLock({ $0.generation == generation }) == true else { return }
            block()
        }
        let previous = state.withLock { state in
            let previous = state.source
            state.source = source
            state.generation = generation
            return previous
        }
        // Even if a concurrent cancel got here first, activate balances the new
        // source's initial suspension so it can be safely destroyed.
        source.activate()
        previous?.cancel()
    }

    func cancel() {
        let previous = state.withLock { state in
            let previous = state.source
            state.source = nil
            state.generation = nil
            return previous
        }
        previous?.cancel()
        if DispatchQueue.getSpecific(key: queueKey) != true { queue.sync {} }
    }

    deinit { cancel() }
}
