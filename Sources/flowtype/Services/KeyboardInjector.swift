import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import os

enum InjectionError: Error {
    case eventSourceCreationFailed
    case textTooLong
}

enum FocusState: Equatable {
    case secureField   // focused element is a password / secure text field
    case present       // some focused element exists — assume injectable
    case noFocus       // no focused UI element at all
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
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        keyUp?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }

    private static func postShiftReturn(source: CGEventSource) async throws {
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        down?.flags = .maskShift
        up?.flags   = .maskShift
        down?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
        up?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: interEventDelayNs)
    }

    // MARK: - Focus detection

    /// Classifies the system-wide focused element. Fails toward `.present`/`.noFocus`
    /// (never blocks normal injection on a transient AX hiccup).
    static func currentFocusState() -> FocusState {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .noFocus
        }
        let element = focusedValue as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == "AXSecureTextField" {
            return .secureField
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField" {
            return .secureField
        }
        return .present
    }

    // MARK: - Temporary shim (removed in Task 4)

    /// Kept only until InjectionStage migrates to `currentFocusState()`.
    static func isFocusedElementSecure() -> Bool {
        currentFocusState() == .secureField
    }
}
