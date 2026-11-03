import SwiftUI
import AppKit

/// Establishes the runtime before any shared services or SwiftUI app initialization.
@main
enum FlowTypeMain {
    @MainActor
    static func main() async {
        do {
            try await RuntimeEnvironment.run(arguments: CommandLine.arguments,
                                             temporaryDirectory: FileManager.default.temporaryDirectory) { context in
                switch context.mode {
                case .selfTest:
                    await SelfTest.runAndExit()
                case .smoke, .artifact:
                    RuntimeEnvironment.finishValidation()
                    FileHandle.standardError.write(Data("FlowType: validation mode unsupported\n".utf8))
                    exit(1)
                case .app:
                    FlowTypeApp.main()
                }
            }
        } catch {
            let failure = (error as? RuntimeBootstrapError) ?? .rootPreparation
            FileHandle.standardError.write(Data("FlowType: runtime bootstrap \(failure.rawValue)\n".utf8))
            exit(failure.exitCode)
        }
    }
}

struct FlowTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
                .onAppear {
                    WindowManager.shared.hideMainWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = ConfigurationStore.shared
        AppearanceController.apply(ConfigurationStore.shared.current.appearancePreference)
        // Model provisioning owns HF_ENDPOINT for the lifetime of each serialized operation.
        EnvMigration.migrateIfNeeded()
        // If a previous session crashed / was killed mid-recording, the system default
        // input device may still point at FlowType's configured mic. Restore it.
        AudioRecorder.restorePendingDeviceIfNeeded()
        StatusBarController.shared.setup()

        ReadinessMonitor.shared.onAccessibilityGranted = {
            WindowManager.shared.repairEventTap()
            PermissionReminderController.shared.showRestored()
            SoundFeedback.playPermissionGranted()
        }
        ReadinessMonitor.shared.refresh()

        AppLogger.log("[AppDelegate] Setting up global hotkey...")
        WindowManager.shared.setupGlobalHotkey()
        AppLogger.log("[AppDelegate] Flowtype launched successfully")

        if !ConfigurationStore.shared.current.hasCompletedOnboarding {
            showOnboarding()
        } else {
            let accessibility = ReadinessMonitor.shared.snapshot.accessibility
            if accessibility != .granted {
                PermissionReminderController.shared.showIfNeeded(accessibility: accessibility)
                ReadinessMonitor.shared.startPermissionWatchIfNeeded()
            }
        }

        // Load the ASR model in the background: checks for already-downloaded models and loads
        // them offline; auto-download of the hardware-recommended model is skipped only if onboarding is incomplete.
        Task {
            await loadQwenASRModel()
        }
    }

    @MainActor
    private func showOnboarding() {
        AppLogger.log("[AppDelegate] Showing first-run onboarding")
        let controller = OnboardingWindowController()
        controller.onClose = { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigurationStore.shared.flushPendingSave()
        // Cmd+Q mid-recording never reaches stopRecording's device restore; the
        // sentinel-based static restore covers it (no-op when nothing was overridden).
        AudioRecorder.restorePendingDeviceIfNeeded()
        AppLogger.log("[AppDelegate] App will terminate")
    }

    @MainActor
    private func loadQwenASRModel() async {
        AppLogger.log("[AppDelegate] Loading selected local ASR model...")
        await QwenModelState.shared.loadModel()
        if case .ready = QwenModelState.shared.status {
            AppLogger.log("[AppDelegate] Local ASR model loaded: \(QwenModelState.shared.activeLease?.identity.engine ?? "local")")
        } else {
            AppLogger.log("[AppDelegate] Local ASR model loading failed")
        }
    }
}
