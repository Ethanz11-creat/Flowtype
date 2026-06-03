import SwiftUI

/// Frosted content surface, one step more opaque than the window shell so text stays legible
/// over the see-through window. Adaptive hairline bevel (lit-from-above), token radius, soft
/// appearance-aware shadow. `active: true` swaps the border to the solid accent (the gradient
/// lives only on the capsule now) for the selected/current item.
struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var active: Bool = false
    var cornerRadius: CGFloat = Brand.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(.thinMaterial))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: shadow, radius: active ? 12 : 8, x: 0, y: active ? 4 : 3)
    }

    private var border: AnyShapeStyle {
        if active { return AnyShapeStyle(Brand.accent) }
        let top    = scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
        let bottom = scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.08)
        return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
    }

    private var shadow: Color {
        if active { return Brand.accent.opacity(0.22) }
        return scheme == .dark ? .black.opacity(0.28) : .black.opacity(0.10)
    }
}

extension View {
    /// Apply the unified frosted-card surface. `active: true` for the selected/current item.
    /// Default radius is `Brand.Radius.card` (10); pass `Brand.Radius.panel` (14) for large panels.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = Brand.Radius.card) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
