import AppKit
import SwiftUI

/// A replaced or manually dismissed message no longer owns the panel's timeout.
struct PermissionReminderLifetime {
    private var activeID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    mutating func dismiss() {
        activeID = nil
    }
}

@MainActor
final class PermissionReminderController {
    static let shared = PermissionReminderController()

    private var shownThisLaunch = false
    private var panel: PermissionReminderPanel?
    private var dismissTask: Task<Void, Never>?
    private var lifetime = PermissionReminderLifetime()

    private init() {}

    deinit {
        dismissTask?.cancel()
    }

    nonisolated static func shouldShow(accessibility: PermissionState, hasShownThisLaunch: Bool) -> Bool {
        !hasShownThisLaunch && accessibility != .granted
    }

    func showIfNeeded(accessibility: PermissionState) {
        guard Self.shouldShow(accessibility: accessibility, hasShownThisLaunch: shownThisLaunch) else { return }
        shownThisLaunch = true
        show(restored: false, duration: .seconds(20))
    }

    func showRestored() {
        show(restored: true, duration: .milliseconds(2_500))
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        lifetime.dismiss()
        panel?.orderOut(nil)
    }

    private func show(restored: Bool, duration: Duration) {
        dismissTask?.cancel()
        let id = lifetime.begin()
        let panel = self.panel ?? PermissionReminderPanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PermissionReminderContent(
            restored: restored,
            openSettings: { [weak self] in
                PermissionHelper.openAccessibilitySettings()
                ReadinessMonitor.shared.startPermissionWatchIfNeeded()
                self?.dismiss()
            },
            dismiss: { [weak self] in self?.dismiss() }
        ))
        panel.setContentSize(NSSize(width: 360, height: 96))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.minY + 170))
        }
        panel.orderFrontRegardless()
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.lifetime.finish(id) else { return }
            self.dismiss()
        }
    }
}

@MainActor
private final class PermissionReminderPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PermissionReminderContent: View {
    let restored: Bool
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(restored ? "辅助功能权限已生效" : "需要辅助功能权限")
                .font(.system(size: 14, weight: .semibold))
            if !restored {
                Text("开启后才能用全局热键；也可以从菜单开始听写。")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 12) {
                    Button("打开设置", action: openSettings)
                    Button("稍后", action: dismiss)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 360, height: 96, alignment: .leading)
        .background(FrostMaterial(material: .hudWindow, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
