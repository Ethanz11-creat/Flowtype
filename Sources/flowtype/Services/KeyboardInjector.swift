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

    static func insertText(_ text: String) async throws {
        let canProceed = injectionLock.withLock { state in
            if state { return false }
            state = true
            return true
        }
        guard canProceed else {
            AppLogger.log("[KeyboardInjector] Injection already in progress, ignoring duplicate")
            return
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
            AppLogger.log("[KeyboardInjector] Injected \(text.count) chars in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }

        isInjecting.withLock { $0 = true }
        defer { isInjecting.withLock { $0 = false } }

        let segments = splitIntoLineSegments(normalizeNewlines(text))
        for (i, segment) in segments.enumerated() {
            if i > 0 {
                try await postShiftReturn(source: source)
            }
            for piece in chunk(segment, size: chunkSize) {
                try await postUnicode(piece, source: source)
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

    private static func postUnicode(_ s: String, source: CGEventSource) async throws {
        guard !s.isEmpty else { return }
        let utf16 = Array(s.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        keyUp.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }

    private static func postShiftReturn(source: CGEventSource) async throws {
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        down.flags = .maskShift
        up.flags   = .maskShift
        down.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }

    // MARK: - Focus detection

    /// Gathers the signals the delivery decision needs from the live system. Bounds AX
    /// latency with a 0.25 s messaging timeout and fails open to `.blindOrUnknown` so a
    /// transient AX miss never blocks injection. Must be called on the main thread.
    static func currentFocusSignals() -> FocusSignals {
        let systemWide = AXUIElementCreateSystemWide()
        // Global default timeout for all AX messages — prevents a hung target app from
        // blocking the main thread for the ~6 s system default.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        let secureGlobal = IsSecureEventInputEnabled()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return FocusSignals(secureInputActive: secureGlobal, focus: .blindOrUnknown)
        }
        let element = value as! AXUIElement
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString)

        // A real password field reports role AXTextField + subrole AXSecureTextField; the
        // subrole check is the reliable one. The role check + global flag are belt-and-suspenders.
        if secureGlobal || role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return FocusSignals(secureInputActive: true, focus: .nonTextControl)
        }
        let kind = classifyFocus(role: role, isValueSettable: isValueSettable(element))
        return FocusSignals(secureInputActive: false, focus: kind)
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
