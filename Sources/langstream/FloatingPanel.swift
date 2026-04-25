import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    private var isDragging = false
    private var initialLocation: NSPoint = .zero

    init(view: AnyView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 70),
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

        // Apply capsule mask so the window itself is capsule-shaped
        let cornerRadius: CGFloat = 35
        let capsulePath = CGPath(
            roundedRect: NSRect(x: 0, y: 0, width: 320, height: 70),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let maskLayer = CAShapeLayer()
        maskLayer.path = capsulePath
        hostingView.layer?.mask = maskLayer

        self.contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        initialLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let screenLocation = NSEvent.mouseLocation
        let newOrigin = NSPoint(
            x: screenLocation.x - initialLocation.x,
            y: screenLocation.y - initialLocation.y
        )
        self.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}
