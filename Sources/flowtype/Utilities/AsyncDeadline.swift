import Foundation

enum AsyncDeadlineError: Error { case timedOut }

/// Races an operation against a whole-operation deadline and caller cancellation.
/// The caller resumes immediately; it never joins a producer that ignores cancellation.
/// Producers must own resource cleanup in their cancellation handler/stream termination.
func withAsyncDeadline<Value: Sendable>(seconds: TimeInterval,
    sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let race = DeadlineRace<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.register(continuation)
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    race.finish(.success(try await operation()))
                } catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    if let sleep { try await sleep(max(0, seconds)) }
                    else { try await Task.sleep(for: .seconds(max(0, seconds))) }
                    race.finish(.failure(AsyncDeadlineError.timedOut))
                } catch { /* The other participant won. */ }
            }
            race.install(producer: producer, timer: timer)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var producer: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func register(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let finished = result
        if finished == nil { self.continuation = continuation }
        lock.unlock()
        if let finished { continuation.resume(with: finished) }
    }

    func install(producer: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.producer = producer; self.timer = timer }
        lock.unlock()
        if finished { producer.cancel(); timer.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let producer = self.producer
        let timer = self.timer
        self.continuation = nil
        self.producer = nil
        self.timer = nil
        lock.unlock()
        producer?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
