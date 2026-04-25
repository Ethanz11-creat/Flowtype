import Foundation
import CoreGraphics

enum InjectionError: Error {
    case eventSourceCreationFailed
}

struct KeyboardInjector {
    static func insertText(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InjectionError.eventSourceCreationFailed
        }

        for character in text {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)

            let charString = String(character)
            let utf16Chars = Array(charString.utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)

            keyDown?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
            keyUp?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    /// Append only the delta text (difference between already-injected and new text)
    /// If newText doesn't start with alreadyInjected prefix, falls back to full replacement via backspace
    static func appendText(_ newText: String, replacing alreadyInjected: String) async throws {
        // Case 1: newText is same as alreadyInjected — nothing to do
        guard newText != alreadyInjected else { return }

        // Case 2: newText starts with alreadyInjected — just append the delta
        if newText.hasPrefix(alreadyInjected) {
            let delta = String(newText.dropFirst(alreadyInjected.count))
            guard !delta.isEmpty else { return }
            try await insertText(delta)
            return
        }

        // Case 3: newText is different — delete injected text and re-type
        // This is risky if user moved cursor, but we do our best
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
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000)
            keyUp?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
