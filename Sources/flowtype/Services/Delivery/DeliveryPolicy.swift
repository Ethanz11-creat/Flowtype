import Foundation

enum DeliveryMode: String, Codable, Sendable {
    case automatic, unicode, pasteInSupportedApps

    /// Selects a mode preference only. Callers must also validate target identity,
    /// focus safety and accessibility permission before dispatching any events.
    func usesPaste(bundleID: String?) -> Bool {
        if self == .automatic { return true }
        guard self == .pasteInSupportedApps, let bundleID else { return false }
        return ["com.apple.TextEdit", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac"].contains(bundleID)
    }
}

enum DeliveryMethod: Equatable, Sendable {
    case paste, type, clipboard
}

/// Pure method selection after the caller validates the stop-time target with
/// decideDelivery. A bundle ID selects legacy compatibility, never authorization.
func resolveDeliveryMethod(mode: DeliveryMode, signals: FocusSignals,
                           accessibilityTrusted: Bool, bundleID: String?) -> DeliveryMethod {
    guard applyAccessibilityGate(decideInjection(signals), accessibilityTrusted: accessibilityTrusted) == .inject else {
        return .clipboard
    }
    return mode.usesPaste(bundleID: bundleID) ? .paste : .type
}

/// Evaluate only after the paste transaction exits, using fresh target and
/// permission samples. Unknown focus permits initial paste, but never fallback.
func canFallbackToTyping(mode: DeliveryMode, pasteResult: PasteTransactionResult,
                         eventDispatched: Bool, target: DeliveryTargetSnapshot?,
                         current: DeliveryTargetSnapshot, accessibilityTrusted: Bool) -> Bool {
    guard mode == .automatic, !eventDispatched,
          pasteResult == .unsafeSnapshot || pasteResult == .notDispatched,
          accessibilityTrusted, current.signals.focus == .editableText else { return false }
    return decideDelivery(target: target, current: current) == .inject
}
