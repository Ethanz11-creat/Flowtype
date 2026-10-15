import Foundation
import ApplicationServices

/// Dispatch describes an event submission, never a claim that an app inserted text.
enum DeliveryOutcome: String, Codable, Sendable {
    case typedDispatched, pasteDispatched, clipboard, uncertain, cancelled

    var isTerminalDelivery: Bool { self != .cancelled }
}

/// Retain the AX object itself: pointer/hash/string descriptions are not stable
/// element identities. AX CFEqual compares the underlying accessibility objects.
struct DeliveryFocusIdentity: @unchecked Sendable, Equatable {
    private let element: AXUIElement?
    private let testID: String?

    init(element: AXUIElement) { self.element = element; testID = nil }
    init(testID: String) { element = nil; self.testID = testID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if let a = lhs.element, let b = rhs.element { return CFEqual(a, b) }
        return lhs.element == nil && rhs.element == nil && lhs.testID == rhs.testID
    }
}

struct DeliveryTargetSnapshot: Sendable, Equatable {
    let pid: Int32?
    let focusIdentity: DeliveryFocusIdentity?
    let signals: FocusSignals

    init(pid: Int32?, focusIdentity: DeliveryFocusIdentity? = nil,
         signals: FocusSignals = FocusSignals(secureInputActive: false, focus: .blindOrUnknown)) {
        self.pid = pid
        self.focusIdentity = focusIdentity
        self.signals = signals
    }
}

/// Unknown AX focus is allowed only while the stop-time process remains the same.
func decideDelivery(target: DeliveryTargetSnapshot?, current: DeliveryTargetSnapshot) -> InjectionDecision {
    guard let target, let pid = target.pid, pid == current.pid else { return .clipboard }
    if let before = target.focusIdentity, let now = current.focusIdentity, before != now { return .clipboard }
    if decideInjection(target.signals) == .clipboard { return .clipboard }
    return decideInjection(current.signals)
}

/// A process switch during asynchronous AX collection invalidates the entire
/// sample, including a switch back to the original stop target.
func deliverySnapshotAfterCollection(_ sample: DeliveryTargetSnapshot, frontmostPID: Int32?) -> DeliveryTargetSnapshot {
    guard sample.pid == frontmostPID else { return DeliveryTargetSnapshot(pid: nil) }
    return sample
}
