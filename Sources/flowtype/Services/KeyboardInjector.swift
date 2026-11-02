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
            guard context.performDeliveryEvent(action) else { throw CancellationError() }
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

// MARK: - Experimental native paste

typealias PasteboardContents = [[String: Data]]

struct PasteboardWriteReceipt {
    /// Generation returned by clearContents, never a later read that could
    /// already belong to another application's concurrent Copy operation.
    let changeCount: Int
    let succeeded: Bool
}

/// nil means some advertised representation could not be materialized. Never clear
/// such a clipboard: a text-only backup would silently discard images/files/RTF.
@MainActor protocol DeliveryPasteboard: AnyObject {
    var changeCount: Int { get }
    func contents() -> PasteboardContents?
    @discardableResult func write(_ contents: PasteboardContents) -> PasteboardWriteReceipt?
}

@MainActor final class SystemDeliveryPasteboard: DeliveryPasteboard {
    private let board = NSPasteboard.general
    var changeCount: Int { board.changeCount }
    func contents() -> PasteboardContents? {
        guard let items = board.pasteboardItems else { return board.types?.isEmpty != false ? [] : nil }
        var result: PasteboardContents = []
        for item in items {
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations[type.rawValue] = data
            }
            result.append(representations)
        }
        return result
    }
    func write(_ contents: PasteboardContents) -> PasteboardWriteReceipt? {
        // Build all items before clearing the shared pasteboard.
        var items: [NSPasteboardItem] = []
        for representations in contents {
            let item = NSPasteboardItem()
            for (type, data) in representations {
                guard item.setData(data, forType: .init(type)) else { return nil }
            }
            items.append(item)
        }
        let generation = board.clearContents()
        guard board.changeCount == generation else {
            return PasteboardWriteReceipt(changeCount: generation, succeeded: false)
        }
        return PasteboardWriteReceipt(changeCount: generation, succeeded: items.isEmpty || board.writeObjects(items))
    }
}

enum PasteTransactionResult: Equatable {
    case dispatched, uncertain, notDispatched, unsafeSnapshot, cancelled, clipboardChanged
}

/// Main-actor serialization extends across the settling window and restoration.
/// A queued transaction never snapshots another transaction's temporary text.
@MainActor final class ClipboardTransaction {
    static let shared = ClipboardTransaction()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func paste(_ text: String, context: SessionContext, board: any DeliveryPasteboard,
               validate: @MainActor () async -> Bool,
               prepareDispatch: @MainActor () throws -> (@MainActor () -> Void),
               settle: @escaping @MainActor @Sendable () async -> Void = {
                   try? await Task.sleep(nanoseconds: 150_000_000)
               }) async -> PasteTransactionResult {
        await acquire()
        defer { release() }
        guard !Task.isCancelled, !context.isCancelled else { return .cancelled }
        // Revalidate after serialization, because a prior transaction may have waited.
        guard await validate() else { return .notDispatched }
        guard !Task.isCancelled, !context.isCancelled else { return .cancelled }
        let dispatch: @MainActor () -> Void
        do { dispatch = try prepareDispatch() } catch { return .notDispatched }
        let beforeCount = board.changeCount
        guard let original = board.contents() else { return .unsafeSnapshot }
        guard board.changeCount == beforeCount else { return .clipboardChanged }
        guard await validate() else { return .notDispatched }
        guard !Task.isCancelled, !context.isCancelled else { return .cancelled }
        let owned: PasteboardContents = [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
        // The last count check and mutation have no suspension between them.
        guard board.changeCount == beforeCount else { return .clipboardChanged }
        var receipt: PasteboardWriteReceipt?
        let active = context.performDeliveryEffectIf {
            receipt = board.write(owned)
            return receipt?.succeeded == true
        }
        guard active || receipt != nil else { return .cancelled }
        guard let receipt else { return .cancelled }
        let ownedCount = receipt.changeCount
        // A failed write may leave an empty/partial board. Capture it only while
        // its original write generation is still ours, so cleanup can restore it.
        let cleanupContents: PasteboardContents?
        if board.changeCount == ownedCount {
            cleanupContents = receipt.succeeded ? owned : board.contents()
        } else { cleanupContents = nil }
        var dispatched = false
        if receipt.succeeded, board.contents() == owned, board.changeCount == ownedCount {
            do {
                try KeyboardInjector.postIfActive(context: context) {
                    dispatched = true
                    dispatch()
                    context.deliveryEventDispatchedAt = Date()
                }
            } catch { /* cleanup still owns its complete settling window */ }
        }
        // Unstructured task has independent cancellation. Awaiting it does not
        // propagate session cancellation; the clipboard remains readable for 150ms.
        var restored = false
        let cleanup = Task { @MainActor in
            if dispatched { await settle() }
            guard let cleanupContents, board.changeCount == ownedCount, board.contents() == cleanupContents,
                  board.changeCount == ownedCount else { return }
            if let restore = board.write(original) { restored = restore.succeeded }
        }
        await cleanup.value
        if dispatched { return Task.isCancelled || context.isCancelled ? .uncertain : .dispatched }
        if Task.isCancelled || context.isCancelled { return .cancelled }
        return restored ? .notDispatched : .clipboardChanged
    }
}

extension KeyboardInjector {
    @MainActor static func preparePasteDispatch() throws -> (@MainActor () -> Void) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw InjectionError.eventSourceCreationFailed }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw InjectionError.eventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return {
            isInjecting.withLock { $0 = true }
            defer { isInjecting.withLock { $0 = false } }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    @MainActor static func pasteText(_ text: String, context: SessionContext,
                                    validate: @MainActor () async -> Bool) async -> PasteTransactionResult {
        await ClipboardTransaction.shared.paste(text, context: context, board: SystemDeliveryPasteboard(),
                                               validate: validate, prepareDispatch: preparePasteDispatch)
    }
}
