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
        window.contentView = NSHostingView(rootView: Self.makeRootView(initialTab: initialTab, navigation: navigation, modelCenter: .shared))
        window.delegate = self
    }

    /// Window recreation uses the same app-lifetime check owner. Tests inject
    /// isolated services through this exact handoff without creating an NSWindow.
    static func makeRootView(initialTab: AppTab, navigation: SettingsNavigation,
                             connectionChecks: SettingsConnectionChecks? = nil,
                             modelCenter: ASRModelCenterEnvironment? = nil,
                             settingsPage: MainWindowView.SettingsPageFactory? = nil) -> MainWindowView {
        MainWindowView(initialTab: initialTab, navigation: navigation,
                       connectionChecks: connectionChecks, modelCenter: modelCenter, settingsPage: settingsPage)
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
