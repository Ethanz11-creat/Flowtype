import SwiftUI

/// The single source of the FlowType brand color (purple → blue), matching the capsule.
enum Brand {
    static let purple = Color(red: 0.52, green: 0.36, blue: 1.0)   // ~#855CFF
    static let blue   = Color(red: 0.30, green: 0.63, blue: 1.0)   // ~#4DA1FF

    /// Single-color accent for small/flat uses (selected state, links, small icons).
    static let accent = purple

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
