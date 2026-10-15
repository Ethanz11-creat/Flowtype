import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Carbon
import os

enum InjectionError: Error {
    case eventSourceCreationFailed
    case eventCreationFailed
    case textTooLong
    case injectionAlreadyInProgress
    case noEventsDispatched
}

struct KeyboardInjector {

    private static let injectionLock = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    static let isInjecting = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

    // chunkSize counts Characters; keyboardSetUnicodeString posts UTF-16 units, so a
    // chunk can expand (e.g. supplementary-plane CJK/emoji). 64 stays well within what
    // the API handles in practice; keep it modest if raising it.
    private static let chunkSize = 64
    private static let interEventDelayNs: UInt64 = 2_000_000 // 2 ms between key events
    private static let maxChars = 20_000                     // sanity ceiling

    // MARK: - Entry point: type the text (Shift+Return for newlines)

    static func insertText(_ text: String, context: SessionContext? = nil) async throws {
        try Task.checkCancellation()
        guard context?.isCancellationRequested != true else { throw CancellationError() }
        let canProceed = injectionLock.withLock { state in
            if state { return false }
            state = true
            return true
        }
        guard canProceed else {
            AppLogger.log("[KeyboardInjector] Injection already in progress, rejecting duplicate")
            throw InjectionError.injectionAlreadyInProgress
        }
        defer { injectionLock.withLock { $0 = false } }

        guard text.count <= maxChars else {
            AppLogger.log("[KeyboardInjector] insertText rejected: \(text.count) chars exceeds \(maxChars) cap")
            throw InjectionError.textTooLong
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.eventSourceCreationFailed
        }

        let start = Date()
        defer {
            AppLogger.log("[KeyboardInjector] Unicode dispatch attempt for \(text.count) chars in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }

        isInjecting.withLock { $0 = true }
        defer { isInjecting.withLock { $0 = false } }

        let segments = splitIntoLineSegments(normalizeNewlines(text))
        for (i, segment) in segments.enumerated() {
            if i > 0 {
                try await postShiftReturn(source: source, context: context)
            }
            for piece in chunk(segment, size: chunkSize) {
                try await postUnicode(piece, source: source, context: context)
            }
        }
    }

    // MARK: - Newline / segmentation helpers (pure, testable)

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func splitIntoLineSegments(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func chunk(_ s: String, size: Int) -> [String] {
        guard size > 0, !s.isEmpty else { return s.isEmpty ? [] : [s] }
        var result: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            result.append(String(s[idx..<end]))
            idx = end
        }
        return result
    }

    // MARK: - Low-level CGEvent posting

    private static func postUnicode(_ s: String, source: CGEventSource, context: SessionContext?) async throws {
        guard !s.isEmpty else { return }
        let utf16 = Array(s.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        try postIfActive(context: context) {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        try await Task.sleep(nanoseconds: interEventDelayNs * 2)
    }

    private static func postShiftReturn(source: CGEventSource, context: SessionContext?) async throws {
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        down.flags = .maskShift
        up.flags   = .maskShift
        try postIfActive(context: context) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        try await Task.sleep(nanoseconds: interEventDelayNs * 2)
    }

    /// Serialize each balanced key pair with session cancellation. The synchronous
    /// pair avoids leaving a key held when cancellation occurs between down/up.
    static func postIfActive(context: SessionContext?, action: () -> Void) throws {
        try Task.checkCancellation()
        if let context {
            guard context.performDeliveryEffect(action) else { throw CancellationError() }
        } else { action() }
        try Task.checkCancellation()
    }

    // MARK: - Focus detection

    /// Capture the frontmost PID before awaiting AX. All synchronous AX IPC runs
    /// off the main actor; total waiting is bounded even for an unresponsive app.
    static func currentDeliveryTarget() async -> DeliveryTargetSnapshot {
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let snapshot = await deliveryTarget(pid: pid)
        // Invalidate a sample taken across an app switch, even if the new app
        // happens to be the original stop target.
        let after = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let validated = deliverySnapshotAfterCollection(snapshot, frontmostPID: after)
        if IsSecureEventInputEnabled() {
            return DeliveryTargetSnapshot(pid: validated.pid, focusIdentity: validated.focusIdentity,
                signals: FocusSignals(secureInputActive: true, focus: .nonTextControl))
        }
        return validated
    }

    static func deliveryTarget(pid: Int32?) async -> DeliveryTargetSnapshot {
        let fallback = DeliveryTargetSnapshot(pid: pid, signals: FocusSignals(secureInputActive: IsSecureEventInputEnabled(), focus: .blindOrUnknown))
        return (try? await withAsyncDeadline(seconds: 0.5) {
            let worker = Task.detached(priority: .utility) { collectDeliveryTarget(pid: pid) }
            return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        }) ?? fallback
    }

    private static func collectDeliveryTarget(pid: Int32?) -> DeliveryTargetSnapshot {
        let secure = IsSecureEventInputEnabled()
        let blind = DeliveryTargetSnapshot(pid: pid, signals: FocusSignals(secureInputActive: secure, focus: .blindOrUnknown))
        guard let pid, !Task.isCancelled, AXIsProcessTrusted() else { return blind }
        let deadline = Date().addingTimeInterval(0.45)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return blind }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        func string(_ key: CFString) -> String? {
            guard !Task.isCancelled, Date() < deadline else { return nil }
            return copyStringAttribute(element, key)
        }
        let role = string(kAXRoleAttribute as CFString)
        let subrole = string(kAXSubroleAttribute as CFString)
        let isSecure = secure || isSecureFocus(role: role, subrole: subrole)
        let settable = !isSecure && Date() < deadline && !Task.isCancelled && isValueSettable(element)
        return DeliveryTargetSnapshot(pid: pid, focusIdentity: DeliveryFocusIdentity(element: element),
            signals: FocusSignals(secureInputActive: isSecure,
                focus: isSecure ? .nonTextControl : classifyFocus(role: role, isValueSettable: settable)))
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
        return value as? String
    }

    private static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

}
