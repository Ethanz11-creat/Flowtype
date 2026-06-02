import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import os

enum InjectionError: Error {
    case eventSourceCreationFailed
}

struct KeyboardInjector {

    private static let injectionLock = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    static let isInjecting = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

    // MARK: - Entry point: chooses paste for multi-line, keystroke for single-line

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

        defer {
            injectionLock.withLock { state in
                state = false
            }
        }
        let startTime = Date()
        defer {
            AppLogger.log("[KeyboardInjector] Total injection time: \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        }
        // If text contains newlines or is long, paste via clipboard to preserve formatting
        // and avoid slow keystroke simulation. Short single-line text uses keystrokes for
        // better compatibility with apps that don't handle paste well.
        if text.contains("\n") || text.contains("\r") || text.count > 50 {
            AppLogger.log("[KeyboardInjector] Using pasteText (chars=\(text.count), hasNewline=\(text.contains("\n")))")
            try await pasteText(text)
        } else {
            AppLogger.log("[KeyboardInjector] Using typeText (chars=\(text.count))")
            try await typeText(text)
        }
    }

    // MARK: - Paste via clipboard (preserves formatting, no Return-key side effects)

    private static func pasteText(_ text: String) async throws {
        let pasteStart = Date()
        defer {
            AppLogger.log("[KeyboardInjector] pasteText completed in \(String(format: "%.2f", Date().timeIntervalSince(pasteStart)))s")
        }
        let pasteboard = NSPasteboard.general

        // 1. Snapshot the current clipboard so we can restore it afterwards.
        let snapshot = snapshotPasteboard(pasteboard)

        // If the clipboard holds promise/lazy content we cannot faithfully capture
        // (a copied file, image, on-demand RTF), do not clobber it: type the text
        // instead when it is short enough for keystroke injection.
        if snapshot.isLossy && text.count <= 100 && !text.contains("\n") && !text.contains("\r") {
            AppLogger.log("[KeyboardInjector] Clipboard un-snapshottable; typing \(text.count) chars to preserve it")
            try await typeText(text)
            return
        }

        // 2. Put our text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Defer: restore the original clipboard on exit — but ONLY if we captured it
        // faithfully. Writing back a lossy snapshot would replace the user's rich
        // clipboard with a stripped/empty copy, so in that case we leave our text.
        defer {
            if snapshot.isLossy {
                AppLogger.log("[KeyboardInjector] Clipboard had un-snapshottable content; left injected text instead of restoring a degraded copy")
            } else {
                restore(snapshot, to: pasteboard)
            }
        }

        // 3. Post Command+V
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.eventSourceCreationFailed
        }

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)  // kVK_Command
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // kVK_ANSI_V
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand

        isInjecting.withLock { $0 = true }
        defer { isInjecting.withLock { $0 = false } }

        cmdDown?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 5_000_000)
        vDown?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 5_000_000)
        vUp?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 5_000_000)
        cmdUp?.post(tap: .cghidEventTap)

        // 4. Wait for the target app to read the clipboard before the defer restores it.
        // There is no API that signals "paste consumed" (a read does not bump
        // changeCount), so this is a bounded best-effort wait that exits early only if
        // the target app itself rewrites the clipboard.
        let injectedChangeCount = pasteboard.changeCount
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if pasteboard.changeCount != injectedChangeCount { break }
        }
        // Clipboard restored by defer above (only when the snapshot was faithful)
    }

    // MARK: - Clipboard snapshot / restore (faithful round-trip detection)

    struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        /// True when at least one advertised type could not be materialized (a
        /// promise/lazy type), meaning the snapshot is NOT a faithful copy and must
        /// not be written back over the user's clipboard.
        let isLossy: Bool
    }

    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var lossy = false
        for item in pasteboard.pasteboardItems ?? [] {
            var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataMap[type] = data
                } else {
                    lossy = true
                }
            }
            if dataMap.isEmpty && !item.types.isEmpty {
                lossy = true
            }
            items.append(dataMap)
        }
        return PasteboardSnapshot(items: items, isLossy: lossy)
    }

    static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        var newItems: [NSPasteboardItem] = []
        for dataMap in snapshot.items where !dataMap.isEmpty {
            let item = NSPasteboardItem()
            for (type, data) in dataMap {
                item.setData(data, forType: type)
            }
            newItems.append(item)
        }
        if !newItems.isEmpty {
            pasteboard.writeObjects(newItems)
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

    // MARK: - Keystroke injection (single-line text only)

    private static func typeText(_ text: String) async throws {
        let typeStart = Date()
        defer {
            AppLogger.log("[KeyboardInjector] typeText completed in \(String(format: "%.2f", Date().timeIntervalSince(typeStart)))s")
        }
        // Security: cap keystroke injection to prevent unbounded blocking
        guard text.count <= 100 else {
            AppLogger.log("[KeyboardInjector] typeText rejected: \(text.count) chars exceeds 100-char cap")
            throw InjectionError.eventSourceCreationFailed
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.eventSourceCreationFailed
        }

        for character in text {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)

            let charString = String(character)
            let utf16Chars = Array(charString.utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)

            keyDown?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000)
            keyUp?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Secure field detection

    /// Whether the system-wide focused UI element is a secure (password) text field.
    /// Fails open (returns false) if Accessibility cannot answer, so normal dictation
    /// is never blocked by a transient AX error.
    static func isFocusedElementSecure() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        // Safe force-cast: the CFGetTypeID check above confirms this is an AXUIElement.
        let element = focusedValue as! AXUIElement

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == "AXSecureTextField" {
            return true
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField" {
            return true
        }
        return false
    }

}
