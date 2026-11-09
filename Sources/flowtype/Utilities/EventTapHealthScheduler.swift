import Foundation

@MainActor
protocol EventTapHealthTimer {
    func cancel()
}

@MainActor
protocol EventTapHealthScheduler {
    func schedule(interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void) -> any EventTapHealthTimer
}

/// The production health check stays on the main queue, without an extra actor hop.
@MainActor
struct DispatchEventTapHealthScheduler: EventTapHealthScheduler {
    func schedule(interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void) -> any EventTapHealthTimer {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { @Sendable in
            MainActor.assumeIsolated { tick() }
        }
        source.resume()
        return DispatchEventTapHealthTimer(source: source)
    }
}

@MainActor
private final class DispatchEventTapHealthTimer: EventTapHealthTimer {
    private let source: DispatchSourceTimer

    init(source: DispatchSourceTimer) { self.source = source }

    func cancel() {
        source.setEventHandler {}
        source.cancel()
    }
}
