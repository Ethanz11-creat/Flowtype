import Foundation
import Cocoa
import ApplicationServices

/// One capture-start snapshot. AX IPC is synchronous, so it lives exclusively on
/// a worker; the caller waits at most 0.5s and never joins a timed-out worker.
final class AXContextProvider: ContextProvider, @unchecked Sendable {
    static let messageTimeout: Float = 0.15
    static let totalTimeout: TimeInterval = 0.5

    func collect() async -> ForegroundContext? {
        guard ValidationEffects.live.allow(.foregroundContext) else { return nil }
        let identity = await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.processIdentifier, app?.localizedName)
        }
        guard !Task.isCancelled, let pid = identity.0 else { return nil }
        return await collectBoundedForegroundContext(timeout: Self.totalTimeout) {
            guard AXIsProcessTrusted() else { return nil }
            return Collector(deadline: Date().addingTimeInterval(Self.totalTimeout))
                .collect(pid: pid, appName: identity.1)
        }
    }

    private struct Collector {
        let deadline: Date

        func collect(pid: pid_t, appName: String?) -> ForegroundContext? {
            let app = AXUIElementCreateApplication(pid)
            guard let focused = element(app, kAXFocusedUIElementAttribute) else {
                return ForegroundContext(appName: appName, elementText: nil, url: nil, selectedText: nil)
            }
            guard let content = collectSafeElementContext(element: focused,
                parent: { element($0, kAXParentAttribute) },
                secure: { isSecureFocus(role: string($0, kAXRoleAttribute), subrole: string($0, kAXSubroleAttribute)) },
                selected: { string($0, kAXSelectedTextAttribute) },
                text: { node in
                    guard let value = string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) else { return nil }
                    return cursorNearContextText(value, selection: selectionRange(node))
                }) else { return nil }
            return ForegroundContext(appName: appName, elementText: content.text,
                                     url: string(app, kAXDocumentAttribute), selectedText: content.selected)
        }

        /// Limit every individual message, including metadata and range queries.
        func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
            guard !Task.isCancelled, Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, Self.messageTimeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
            guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func string(_ node: AXUIElement, _ key: String) -> String? {
            guard let value = attribute(node, key) as? String, !value.isEmpty else { return nil }
            return value
        }
        func selectionRange(_ node: AXUIElement) -> NSRange? {
            guard let value = attribute(node, kAXSelectedTextRangeAttribute),
                  CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        private static let messageTimeout = AXContextProvider.messageTimeout
    }
}
