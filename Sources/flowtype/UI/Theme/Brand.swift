import SwiftUI
import AppKit

/// The single source of the FlowType brand color (purple → blue), matching the capsule.
enum Brand {
    static let purple = Color(red: 0.52, green: 0.36, blue: 1.0)   // ~#855CFF
    static let blue   = Color(red: 0.30, green: 0.63, blue: 1.0)   // ~#4DA1FF

    /// Single desaturated accent — the ONLY accent in window UI (active row, primary button,
    /// live dot). Adapts: a touch deeper in light mode, lighter in dark. Gradient stays on the capsule.
    static let accent = Color(light: Color(red: 0.42, green: 0.30, blue: 0.90),   // ~#6B4DE6
                              dark:  Color(red: 0.61, green: 0.50, blue: 0.88))   // ~#9B7FE0

    /// Hero gradient (diagonal) for anchor elements: progress ring, active strokes.
    static let gradient = LinearGradient(
        colors: [purple, blue],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Horizontal gradient for rows / wide elements.
    static let gradientH = LinearGradient(
        colors: [purple, blue],
        startPoint: .leading, endPoint: .trailing
    )
}

extension Brand {
    /// Token radius scale — every rounded shape uses one of these, `style: .continuous`.
    enum Radius {
        static let window: CGFloat = 18
        static let panel:  CGFloat = 14
        static let card:   CGFloat = 10
        static let chip:   CGFloat = 6
    }
}

extension Color {
    /// Appearance-adaptive color: resolves `light` in Aqua, `dark` in Dark Aqua.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }
}
