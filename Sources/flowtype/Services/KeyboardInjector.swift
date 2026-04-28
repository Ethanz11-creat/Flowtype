import Foundation
import CoreGraphics
import AppKit

enum InjectionError: Error {
    case eventSourceCreationFailed
}

struct KeyboardInjector {

    // MARK: - Entry point: chooses paste for multi-line, keystroke for single-line

    static func insertText(_ text: String) async throws {
        // If text contains newlines, paste via clipboard to preserve formatting
        // without triggering "send" on Return key in chat apps.
        if text.contains("\n") || text.contains("\r") {
            try await pasteText(text)
        } else {
            try await typeText(text)
        }
    }

    // MARK: - Paste via clipboard (preserves formatting, no Return-key side effects)

    private static func pasteText(_ text: String) async throws {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents (all types for each item)
        let savedItems: [(types: [NSPasteboard.PasteboardType], dataMap: [NSPasteboard.PasteboardType: Data])]? =
            pasteboard.pasteboardItems?.compactMap { item in
                let types = item.types
                var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
                for type in types {
                    if let data = item.data(forType: type) {
                        dataMap[type] = data
                    }
                }
                return dataMap.isEmpty ? nil : (types: types, dataMap: dataMap)
            }

        // 2. Put our text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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

        cmdDown?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 5_000_000)
        vDown?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 5_000_000)
        vUp?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 5_000_000)
        cmdUp?.post(tap: .cghidEventTap)

        // 4. Wait for paste to complete, then restore clipboard
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        pasteboard.clearContents()
        if let savedItems = savedItems, !savedItems.isEmpty {
            for (_, dataMap) in savedItems {
                for (type, data) in dataMap {
                    pasteboard.setData(data, forType: type)
                }
            }
        }
    }

    // MARK: - Keystroke injection (single-line text only)

    private static func typeText(_ text: String) async throws {
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

    // MARK: - Public helpers

    /// Append only the delta text (difference between already-injected and new text)
    /// If newText doesn't start with alreadyInjected prefix, falls back to full replacement via backspace
    static func appendText(_ newText: String, replacing alreadyInjected: String) async throws {
        guard newText != alreadyInjected else { return }

        if newText.hasPrefix(alreadyInjected) {
            let delta = String(newText.dropFirst(alreadyInjected.count))
            guard !delta.isEmpty else { return }
            try await insertText(delta)
            return
        }

        try await deleteCharacters(alreadyInjected.count)
        try await insertText(newText)
    }

    /// Simulate backspace N times
    static func deleteCharacters(_ count: Int) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.eventSourceCreationFailed
        }

        let deleteKeyCode: CGKeyCode = 0x33 // kVK_Delete

        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000)
            keyUp?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
