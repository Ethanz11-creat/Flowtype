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

        // 安全输入（密码）字段：不采集任何元素派生内容（值、选中文本、标题）。
        // 与 collectElementText 使用同一判定（含父级），避免两处守卫不一致。
        if let element = focusedElement, isSecureIncludingParent(element) {
            AppLogger.log("[AXContext] Secure field focused — skipping element context")
            return nil
        }

        let elementText = focusedElement.flatMap { collectElementText($0) }
        let selectedText = focusedElement.flatMap { stringAttribute($0, kAXSelectedTextAttribute as CFString) }
        let url = focusedApp.flatMap { stringAttribute($0, kAXDocumentAttribute as CFString) }

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

    /// 元素是否为安全输入（密码）字段。读取 role/subrole，命中即不可采集其值。
    private func isSecure(_ element: AXUIElement) -> Bool {
        isSecureFocus(role: stringAttribute(element, kAXRoleAttribute as CFString),
                      subrole: stringAttribute(element, kAXSubroleAttribute as CFString))
    }

    /// 元素自身或其父级是否为安全输入字段。
    /// 多数 App 把安全字段嵌在外层容器内，只看自身会漏判，故采集前统一用本判定。
    private func isSecureIncludingParent(_ element: AXUIElement) -> Bool {
        if isSecure(element) { return true }
        guard let parent = elementAttribute(element, kAXParentAttribute as CFString) else { return false }
        return isSecure(parent)
    }

    /// 焦点元素自身文本，其次回退到其父级（多数编辑器把文本放在嵌套的 AXTextArea 上）。
    /// 焦点或其父级为安全输入字段时直接返回 nil——绝不读取其值。
    private func collectElementText(_ element: AXUIElement) -> String? {
        if isSecureIncludingParent(element) { return nil }
        if let v = stringAttribute(element, kAXValueAttribute as CFString) { return v }
        if let v = stringAttribute(element, kAXTitleAttribute as CFString) { return v }
        guard let parent = elementAttribute(element, kAXParentAttribute as CFString) else { return nil }
        return stringAttribute(parent, kAXValueAttribute as CFString)
    }
}
