import AppKit
import SwiftUI

/// A non-activating floating panel that serves purely as a visual indicator.
/// It never becomes the key window, so it never steals focus from the user's
/// active text input field. The user can continue typing, pressing Return,
/// and switching apps while the panel remains visible.
class FloatingPanel: NSPanel {
    private var isDragging = false
    private var initialLocation: NSPoint = .zero
    private let capsuleMask = CAShapeLayer()
    private nonisolated(unsafe) var monitors: [Any] = []

    init(view: AnyView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden

        let hostingView = NSHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.layer?.mask = capsuleMask
        self.contentView = hostingView
        setCapsuleSize(NSSize(width: 240, height: 70))

        setupDragMonitors()
    }

    deinit {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit can constrain a cross-screen presentation to the panel's previous
    // screen. This borderless overlay owns its global position and slide path;
    // keep the requested frame instead of pulling it back onto the old screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Keep the window and its hit-testable mask in sync with the recovery layout.
    /// Resizing preserves the capsule center and never activates the panel.
    func setCapsuleSize(_ size: NSSize) {
        let centerX = frame.midX
        setContentSize(size)
        setFrameOrigin(NSPoint(x: centerX - size.width / 2, y: frame.minY))
        capsuleMask.frame = NSRect(origin: .zero, size: size)
        capsuleMask.path = CGPath(roundedRect: NSRect(origin: .zero, size: size),
                                 cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
    }

    // MARK: - Drag via event monitors (avoids intercepting SwiftUI gestures)

    private func setupDragMonitors() {
        let down = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self else { return event }
            self.isDragging = false
            self.initialLocation = event.locationInWindow
            return event
        }

        let dragged = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self, event.window === self else { return event }

            if !self.isDragging {
                let moveDistance = hypot(
                    event.locationInWindow.x - self.initialLocation.x,
                    event.locationInWindow.y - self.initialLocation.y
                )
                if moveDistance > 3 {
                    self.isDragging = true
                }
            }

            guard self.isDragging else { return event }

            let screenLocation = NSEvent.mouseLocation
            let newOrigin = NSPoint(
                x: screenLocation.x - self.initialLocation.x,
                y: screenLocation.y - self.initialLocation.y
            )
            self.setFrameOrigin(newOrigin)
            return event
        }

        let up = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self, event.window === self else { return event }
            self.isDragging = false
            return event
        }

        monitors = [down, dragged, up].compactMap { $0 }
    }
}
