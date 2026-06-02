import SwiftUI

/// The unified "restrained adaptive glass" surface. Translucent system material (adapts to
/// light/dark), hairline border, soft shadow. `active: true` swaps to a brand-gradient border
/// + subtle brand glow for the selected/current item — the ONLY place a card glows.
struct GlassCard: ViewModifier {
    var active: Bool = false
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        active ? AnyShapeStyle(Brand.gradient)
                               : AnyShapeStyle(Color.primary.opacity(0.08)),
                        lineWidth: active ? 1.5 : 1
                    )
            )
            .shadow(color: active ? Brand.purple.opacity(0.18) : .black.opacity(0.06),
                    radius: active ? 10 : 6, x: 0, y: 2)
    }
}

extension View {
    /// Apply the unified glass-card surface. Use `active: true` for the selected/current item.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
