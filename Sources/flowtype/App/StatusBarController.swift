import AppKit
import SwiftUI
import Combine

/// Owns the presented menu command and the session effect boundary.
@MainActor
final class DictationMenuController: NSObject {
    enum Command: Int { case start, stop, unavailable }

    let item: NSMenuItem
    private let session: SessionController
    private let actionGate: ValidationActionGate
    private var sessionCancellable: AnyCancellable?

    init(session: SessionController, actionGate: ValidationActionGate = .live) {
        self.session = session; self.actionGate = actionGate
        item = NSMenuItem(title: "", action: #selector(activate(_:)), keyEquivalent: "")
        super.init()
        item.target = self
        refresh(for: session.sessionState)
        // Session state is committed before MainActor publication. Update
        // synchronously, including during menu tracking.
        sessionCancellable = session.sessionStatePublisher.sink { [weak self] state in
            self?.refresh(for: state)
        }
    }

    func refresh(for state: SessionState) {
        item.title = StatusBarController.dictationMenuTitle(for: state)
        item.isEnabled = actionGate.isApp && StatusBarController.dictationMenuEnabled(for: state)
        switch state {
        case .preparing, .recording: item.tag = Command.stop.rawValue
        case .idle, .notice, .error: item.tag = Command.start.rawValue
        case .processing, .polishing, .injecting: item.tag = Command.unavailable.rawValue
        }
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard actionGate.allow(.dictation) else { return }
        guard sender.isEnabled, let command = Command(rawValue: sender.tag) else { return }
        // Dispatch the presented command, then validate against the live session.
        // A queued Stop selection must never turn into Start after capture ends.
        switch (command, session.sessionState) {
        case (.stop, .preparing), (.stop, .recording): session.endRecording()
        case (.start, .idle), (.start, .notice), (.start, .error): session.startRecording()
        default: break
        }
    }
}

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var statusMenuItem: NSMenuItem?
    private var sessionCancellable: AnyCancellable?
    private var readinessCancellable: AnyCancellable?
    private var dictationMenuController: DictationMenuController?
    private var lastDeliveryMenuController: LastDeliveryMenuController?
    private var originalStatusImage: NSImage?

    var isConfigured: Bool { statusItem?.button != nil && statusItem?.menu != nil }

    private let actionGate: ValidationActionGate
    private let actionEffects: ((ValidationAction) -> Void)?
    init(actionGate: ValidationActionGate = .live, actionEffects: ((ValidationAction) -> Void)? = nil) {
        self.actionGate = actionGate; self.actionEffects = actionEffects
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        if let url = AppResources.url(forResource: "status_bar_icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Flowtype")
        }

        originalStatusImage = button.image

        button.action = #selector(showMenu)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMenu()

        sessionCancellable = SessionController.shared.sessionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:
                    self.statusItem?.button?.toolTip = readinessMenuTitle(ReadinessMonitor.shared.snapshot)
                case .preparing:
                    self.statusItem?.button?.toolTip = "FlowType — 正在准备麦克风..."
                case .recording:
                    self.statusItem?.button?.toolTip = "FlowType — 录音中..."
                case .processing, .polishing:
                    self.statusItem?.button?.toolTip = "FlowType — \(state.statusTitle)"
                case .injecting:
                    self.statusItem?.button?.toolTip = "FlowType — 输入中..."
                case .notice(let msg):
                    self.statusItem?.button?.toolTip = "FlowType — \(msg)"
                case .error(let msg):
                    self.statusItem?.button?.toolTip = "FlowType — 错误: \(msg)"
                }
            }

        let monitor = ReadinessMonitor.shared
        readinessCancellable = monitor.$level.combineLatest(monitor.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level, snapshot in
                self?.updateReadinessPresentation(level: level, snapshot: snapshot)
            }
    }

    private func updateReadinessPresentation(level: ReadinessLevel, snapshot: ReadinessSnapshot) {
        updateMenuItems()
        guard let button = statusItem?.button else { return }
        switch level {
        case .ready:
            button.image = originalStatusImage
            button.contentTintColor = nil
        case .degraded:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "FlowType")
            button.contentTintColor = .systemOrange
        case .blocked:
            button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "FlowType")
            button.contentTintColor = .systemRed
        }
        // Readiness can change during capture or delivery; session copy keeps ownership.
        if case .idle = SessionController.shared.sessionState {
            button.toolTip = readinessMenuTitle(snapshot)
        }
    }

    nonisolated static func dictationMenuTitle(for state: SessionState) -> String {
        switch state {
        case .preparing, .recording: return "停止听写"
        case .processing, .polishing, .injecting: return "处理中…"
        case .idle, .notice, .error: return "开始听写"
        }
    }

    nonisolated static func dictationMenuEnabled(for state: SessionState) -> Bool {
        switch state {
        case .processing, .polishing, .injecting: return false
        default: return true
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.autoenablesItems = false
        let readinessItem = NSMenuItem(title: "", action: #selector(repairReadiness), keyEquivalent: "")
        readinessItem.target = self
        statusMenuItem = readinessItem
        menu.addItem(readinessItem)

        let dictation = DictationMenuController(session: SessionController.shared)
        dictationMenuController = dictation
        menu.addItem(dictation.item)
        let lastDelivery = LastDeliveryMenuController(session: SessionController.shared)
        lastDeliveryMenuController = lastDelivery
        menu.addItem(lastDelivery.item)
        updateMenuItems()
        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "显示 Flowtype", action: #selector(showSettings), keyEquivalent: ",")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "关于 FlowType", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let viewLogsItem = NSMenuItem(title: "查看日志...", action: #selector(openLogs), keyEquivalent: "")
        viewLogsItem.target = self
        menu.addItem(viewLogsItem)

        let reloadItem = NSMenuItem(title: "重新加载配置", action: #selector(reloadConfiguration), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        let onboardingItem = NSMenuItem(title: "重新打开引导", action: #selector(showOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(NSMenuItem.separator())

        let permissionItem = NSMenuItem(title: "重新检测权限", action: #selector(checkPermissions), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Flowtype", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if !actionGate.isApp { for item in menu.items where item.action != nil { item.isEnabled = false } }
        statusItem?.menu = menu
    }

    func finishValidation() {
        guard RuntimeEnvironment.current.role != .app else { return }
        sessionCancellable = nil; readinessCancellable = nil
        dictationMenuController = nil; lastDeliveryMenuController = nil
        statusItem?.menu?.delegate = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func showMenu() {
        guard actionGate.allow(.menuWindow) else { return }
        if let actionEffects { actionEffects(.menuWindow); return }
        guard let button = statusItem?.button else { return }
        statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    @objc private func showSettings() {
        guard actionGate.allow(.menuWindow) else { return }
        if let actionEffects { actionEffects(.menuWindow); return }
        openSettings(tab: .settings)
    }

    func openSettings(tab: AppTab = .settings) {
        openSettings(destination: .tab(tab))
    }

    func openSettings(destination: ClientDestination) {
        guard actionGate.allow(.menuWindow) else { return }
        if let actionEffects { actionEffects(.menuWindow); return }
        guard ValidationEffects.live.allow(.window) else { return }
        if settingsWindowController == nil {
            let controller = SettingsWindowController(initialTab: destination.tab)
            controller.onClose = { [weak self] in
                self?.settingsWindowController = nil
            }
            settingsWindowController = controller
        }
        settingsWindowController?.open(destination: destination)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        guard actionGate.allow(.menuWindow) else { return }
        if let actionEffects { actionEffects(.menuWindow); return }
        guard RuntimeEnvironment.current.role == .app else { return }
        let alert = NSAlert()
        alert.messageText = "关于 FlowType"
        alert.informativeText = AppLogger.identity.aboutDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openLogs() {
        guard actionGate.allow(.menuWindow) else { return }
        if let actionEffects { actionEffects(.menuWindow); return }
        AppLogger.openLogInFinder()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // AppKit invokes menu delegates on the main thread. Match the synchronous
        // MainActor bridge used by main-runloop callbacks in WindowManager.
        MainActor.assumeIsolated {
            ReadinessMonitor.shared.refresh()
            updateMenuItems()
        }
    }

    private func updateMenuItems() {
        let monitor = ReadinessMonitor.shared
        statusMenuItem?.title = readinessMenuTitle(monitor.snapshot)
        switch monitor.rawLevel {
        case .blocked, .degraded(.accessibilityMissing): statusMenuItem?.isEnabled = actionGate.isApp
        default: statusMenuItem?.isEnabled = false
        }
        let state = SessionController.shared.sessionState
        dictationMenuController?.refresh(for: state)
        lastDeliveryMenuController?.refresh(for: SessionController.shared.lastDeliverySummary)
    }

    @objc private func repairReadiness() {
        guard actionGate.allow(.repair) else { return }
        if let actionEffects { actionEffects(.repair); return }
        let monitor = ReadinessMonitor.shared
        monitor.refresh()
        switch monitor.rawLevel {
        case .blocked(.microphoneDenied):
            PermissionHelper.openMicrophoneSettings()
        case .blocked(.noEngine):
            openSettings(tab: .settings)
        case .degraded(.accessibilityMissing):
            PermissionHelper.openAccessibilitySettings()
            monitor.startPermissionWatchIfNeeded()
        default:
            break
        }
    }

    @objc private func reloadConfiguration() {
        guard actionGate.allow(.configuration) else { return }
        if let actionEffects { actionEffects(.configuration); return }
        let defaultsKey = "flowtype.config"
        if let data = RuntimeEnvironment.defaults.data(forKey: defaultsKey),
           let config = try? JSONDecoder().decode(Configuration.self, from: data) {
            ConfigurationStore.shared.current = config
        }
        WindowManager.shared.reloadHotkey()

        if let button = statusItem?.button {
            let originalTitle = button.title
            button.title = "已重新加载"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                button.title = originalTitle
            }
        }
    }

    @objc private func checkPermissions() {
        guard actionGate.allow(.permission) else { return }
        if let actionEffects { actionEffects(.permission); return }
        let monitor = ReadinessMonitor.shared
        monitor.refresh()
        WindowManager.shared.repairEventTap()
        monitor.startPermissionWatchIfNeeded()
        updateMenuItems()
    }

    @objc private func quit() {
        guard actionGate.allow(.quit) else { return }
        if let actionEffects { actionEffects(.quit); return }
        NSApp.terminate(nil)
    }

    @objc private func showOnboarding() {
        guard actionGate.allow(.menuWindow) else { return }
        if let actionEffects { actionEffects(.menuWindow); return }
        if onboardingWindowController == nil {
            let controller = OnboardingWindowController()
            controller.onClose = { [weak self] in
                self?.onboardingWindowController = nil
            }
            onboardingWindowController = controller
        }
        onboardingWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
