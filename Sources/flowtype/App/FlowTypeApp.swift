import SwiftUI
import AppKit

/// Process entry point. Intercepts `--self-test` (runnable without Xcode/XCTest)
/// before launching the GUI; otherwise hands off to the SwiftUI app.
@main
enum FlowTypeMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.runAndExit()
        }
        FlowTypeApp.main()
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
        // Point HF at the chosen mirror BEFORE the first model load (the .app inherits no shell env).
        let downloadSource = ConfigurationStore.shared.current.downloadSource
        if let endpoint = downloadSource.endpoint(isChina: DownloadSource.systemIsLikelyChina()) {
            setenv("HF_ENDPOINT", endpoint, 1)
        }
        EnvMigration.migrateIfNeeded()
        // If a previous session crashed / was killed mid-recording, the system default
        // input device may still point at FlowType's configured mic. Restore it.
        AudioRecorder.restorePendingDeviceIfNeeded()
        StatusBarController.shared.setup()

        AppLogger.log("[AppDelegate] Setting up global hotkey...")
        WindowManager.shared.setupGlobalHotkey()
        AppLogger.log("[AppDelegate] Flowtype launched successfully")

        if !ConfigurationStore.shared.current.hasCompletedOnboarding {
            showOnboarding()
        } else {
            let hasAccessibility = PermissionHelper.checkAccessibility()
            if !hasAccessibility {
                PermissionHelper.showPermissionGuide()
            }
        }

        // Load the ASR model in the background regardless of onboarding state — onboarding's
        // own load (if any) dedups via QwenModelState, so this never double-loads.
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
        let provider = await SessionController.shared.qwenProvider
        AppLogger.log("[AppDelegate] Loading Qwen3-ASR model...")
        await QwenModelState.shared.loadModel(provider: provider)
        if case .ready = await QwenModelState.shared.status {
            AppLogger.log("[AppDelegate] Qwen3-ASR model loaded successfully")
        } else {
            AppLogger.log("[AppDelegate] Qwen3-ASR model loading failed")
        }
    }
}
