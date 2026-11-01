import AppKit
import SwiftUI
import Combine

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var statusMenuItem: NSMenuItem?
    private var sessionCancellable: AnyCancellable?
    private var readinessCancellable: AnyCancellable?
    private var dictationMenuItem: NSMenuItem?
    private var originalStatusImage: NSImage?

    private override init() {
        super.init()
    }

    func setup() {
        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        if let image = Bundle.module.image(forResource: "status_bar_icon") {
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

        sessionCancellable = SessionController.shared.$sessionState
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

        let dictationItem = NSMenuItem(title: "", action: #selector(toggleDictation), keyEquivalent: "")
        dictationItem.target = self
        dictationMenuItem = dictationItem
        menu.addItem(dictationItem)
        updateMenuItems()
        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "显示 Flowtype", action: #selector(showSettings), keyEquivalent: ",")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

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

        statusItem?.menu = menu
    }

    @objc private func showMenu() {
        guard let button = statusItem?.button else { return }
        statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    @objc private func showSettings() {
        openSettings(tab: .settings)
    }

    func openSettings(tab: AppTab = .settings) {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(initialTab: tab)
            controller.onClose = { [weak self] in
                self?.settingsWindowController = nil
            }
            settingsWindowController = controller
        }
        settingsWindowController?.selectTab(tab)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLogs() {
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
        case .blocked, .degraded(.accessibilityMissing): statusMenuItem?.isEnabled = true
        default: statusMenuItem?.isEnabled = false
        }
        let state = SessionController.shared.sessionState
        dictationMenuItem?.title = Self.dictationMenuTitle(for: state)
        dictationMenuItem?.isEnabled = Self.dictationMenuEnabled(for: state)
    }

    @objc private func repairReadiness() {
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

    @objc private func toggleDictation() {
        let session = SessionController.shared
        switch session.sessionState {
        case .preparing, .recording: session.endRecording()
        case .idle, .notice, .error: session.startRecording()
        case .processing, .polishing, .injecting: break
        }
    }

    @objc private func reloadConfiguration() {
        let defaultsKey = "flowtype.config"
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
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
        let monitor = ReadinessMonitor.shared
        monitor.refresh()
        WindowManager.shared.repairEventTap()
        monitor.startPermissionWatchIfNeeded()
        updateMenuItems()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showOnboarding() {
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
