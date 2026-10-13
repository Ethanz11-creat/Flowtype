import Foundation
import Cocoa
import ApplicationServices

/// 用 macOS Accessibility API 采集前台 app / 焦点元素 / 选中文本 / 网页 URL。
/// 任一步失败都静默返回已采集到的部分；无辅助功能权限时返回 nil（不阻断录音）。
final class AXContextProvider: ContextProvider, @unchecked Sendable {

    func collect() async -> ForegroundContext? {
        guard AXIsProcessTrusted() else {
            AppLogger.log("[AXContext] Accessibility permission not granted — skipping context")
            return nil
        }
        let appName = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        let system = AXUIElementCreateSystemWide()

        let focusedApp = elementAttribute(system, kAXFocusedApplicationAttribute as CFString)
        let focusedElement = focusedApp.flatMap { elementAttribute($0, kAXFocusedUIElementAttribute as CFString) }

        var elementText: String? = focusedElement.flatMap { collectElementText($0) }
        let selectedText = focusedElement.flatMap { stringAttribute($0, kAXSelectedTextAttribute as CFString) }
        let url = focusedApp.flatMap { stringAttribute($0, kAXDocumentAttribute as CFString) }

        // 只在没有更精确信号时才用 URL（避免把无关页面 URL 当上下文）。
        if elementText == nil && selectedText == nil { elementText = url }

        if elementText == nil && selectedText == nil && url == nil && appName == nil { return nil }
        return ForegroundContext(appName: appName, elementText: elementText,
                                 url: url, selectedText: selectedText)
    }

    // MARK: - AX helpers

    private func elementAttribute(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// 焦点元素自身文本，其次回退到其父级（多数编辑器把文本放在嵌套的 AXTextArea 上）。
    private func collectElementText(_ element: AXUIElement) -> String? {
        if let v = stringAttribute(element, kAXValueAttribute as CFString) { return v }
        if let v = stringAttribute(element, kAXTitleAttribute as CFString) { return v }
        var parent: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
           let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() {
            return stringAttribute((p as! AXUIElement), kAXValueAttribute as CFString)
        }
        return nil
    }
}
