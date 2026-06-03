import SwiftUI

/// Flat frosted content surface — deliberately NOT skeuomorphic: a uniform hairline border,
/// no lit-from-above bevel, no drop shadow, so cards read as matte/premium rather than raised
/// physical buttons. `active: true` is a subtle accent wash + accent border for the
/// selected/current item.
struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var active: Bool = false
    var cornerRadius: CGFloat = Brand.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }

    private var fill: AnyShapeStyle {
        if active { return AnyShapeStyle(Brand.accent.opacity(0.12)) }
        return AnyShapeStyle(.thinMaterial)
    }

    private var border: AnyShapeStyle {
        if active { return AnyShapeStyle(Brand.accent.opacity(0.55)) }
        return AnyShapeStyle(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
    }
}

extension View {
    /// Apply the unified frosted-card surface. `active: true` for the selected/current item.
    /// Default radius is `Brand.Radius.card` (10); pass `Brand.Radius.panel` (14) for large panels.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = Brand.Radius.card) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
