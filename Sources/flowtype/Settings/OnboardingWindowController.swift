import AppKit
import SwiftUI

@MainActor
class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var flow: OnboardingFlow?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1040, height: 700)
        window.title = "FlowType 设置向导"
        window.isReleasedWhenClosed = false
        window.center()

        // Shared services are resolved only at this production composition boundary.
        let store = ConfigurationStore.shared
        let monitor = ReadinessMonitor.shared
        let coordinator = QwenModelState.shared
        let presenter = TrialSessionPresenter(configuration: store, resources: .shared,
            refreshReadiness: { monitor.refresh(); return monitor.rawLevel },
            readinessLevel: { monitor.refresh(); return monitor.rawLevel },
            copy: { KeyboardInjector.copyText($0) })
        let flow = OnboardingFlow(trial: presenter, navigation: SettingsNavigation(),
            onNavigate: { StatusBarController.shared.openSettings(destination: $0) }) { [weak window] in
            var config = store.current
            config.hasCompletedOnboarding = true
            store.save(config)
            window?.close()
        }
        let view = OnboardingView(flow: flow, store: store, monitor: monitor,
            modelState: coordinator, downloader: .shared,
            importedActions: ImportedASRModelActions(coordinator: coordinator, configuration: { store.current }),
            checks: CloudASRConnectionCheck(), draftChecks: CloudASRConnectionCheck())
        window.contentView = NSHostingView(rootView: view)
        self.init(window: window)
        self.flow = flow
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        flow?.close()
        onClose?()
    }
}
