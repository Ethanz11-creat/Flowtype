import Foundation
import os

/// Owns one preview stream, including setup that may finish after Stop. Speech
/// callbacks and AsyncStream termination can synchronously reenter this owner.
final class StreamingPreviewSession: @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<String>.Continuation?
        var cleanup: [@Sendable () -> Void] = []
        var text = ""
        var finished = false
    }
    private let state: OSAllocatedUnfairLock<State>
    private let timeoutTimer = DispatchCancellableTimer()

    init(continuation: AsyncStream<String>.Continuation, timeout: TimeInterval) {
        state = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
        continuation.onTermination = { [weak self] _ in _ = self?.finish() }
        timeoutTimer.schedule(withTimeInterval: timeout) { [weak self] in _ = self?.finish() }
    }

    var isFinished: Bool { state.withLock { $0.finished } }

    func addCleanup(_ action: @escaping @Sendable () -> Void) {
        let stopped = state.withLock { state in
            guard !state.finished else { return true }
            state.cleanup.append(action)
            return false
        }
        // A synchronous recognition callback may terminate before task creation
        // returns. Its newly returned task must still be cancelled, exactly once.
        if stopped { action() }
    }

    func receive(_ text: String, isFinal: Bool = false) {
        let snapshot = state.withLock { state -> (AsyncStream<String>.Continuation?, [@Sendable () -> Void]) in
            guard !state.finished else { return (nil, []) }
            state.text = text
            let continuation = state.continuation
            guard isFinal else { return (continuation, []) }
            // Claim terminal ownership with the final text, so a racing partial
            // callback cannot overwrite it before stream termination begins.
            let cleanup = state.cleanup
            state.finished = true
            state.continuation = nil
            state.cleanup.removeAll()
            return (continuation, cleanup)
        }
        snapshot.0?.yield(text)
        if isFinal {
            timeoutTimer.cancel()
            snapshot.1.forEach { $0() }
            snapshot.0?.finish()
        }
    }

    @discardableResult func finish() -> String {
        let snapshot = state.withLock { state in
            let result = (state.text, state.continuation, state.cleanup)
            state.finished = true
            state.continuation = nil
            state.cleanup.removeAll()
            return result
        }
        timeoutTimer.cancel()
        // No framework or stream callout is allowed under the nonrecursive lock.
        snapshot.2.forEach { $0() }
        snapshot.1?.finish()
        return snapshot.0
    }
}
