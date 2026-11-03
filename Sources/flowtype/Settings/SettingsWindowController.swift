import AppKit
import SwiftUI

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let navigation = SettingsNavigation()

    convenience init(initialTab: AppTab = .overview) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: StatsConfig.initialWindowWidth, height: StatsConfig.initialWindowHeight),
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
        window.isOpaque = true
        window.backgroundColor = NSColor(Theme.pageBackground)

        self.init(window: window)
        navigation.requestedTab = initialTab
        window.contentView = NSHostingView(rootView: MainWindowView(initialTab: initialTab, navigation: navigation))
        window.delegate = self
    }

    func selectTab(_ tab: AppTab) {
        open(destination: .tab(tab))
    }

    func open(destination: ClientDestination) {
        navigation.navigate(to: destination)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
