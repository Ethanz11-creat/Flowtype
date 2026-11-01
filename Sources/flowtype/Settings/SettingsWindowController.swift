import AppKit
import SwiftUI

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let navigation = SettingsNavigation()

    convenience init(initialTab: AppTab = .overview) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowType"
        window.contentMinSize = NSSize(width: StatsConfig.minWindowWidth, height: StatsConfig.minWindowHeight)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear

        self.init(window: window)
        navigation.requestedTab = initialTab
        window.contentView = NSHostingView(rootView: MainWindowView(initialTab: initialTab, navigation: navigation))
        window.delegate = self
    }

    func selectTab(_ tab: AppTab) {
        navigation.requestedTab = tab
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
