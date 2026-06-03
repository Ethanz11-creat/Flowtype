import SwiftUI

/// Solid (opaque) content-card surface. `active: true` = subtle accent wash + accent border.
struct GlassCard: ViewModifier {
    var active: Bool = false
    var cornerRadius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(active ? AnyShapeStyle(Brand.accent.opacity(0.14)) : AnyShapeStyle(Theme.cardBackground)))
            .overlay(shape.strokeBorder(active ? Brand.accent.opacity(0.55) : Theme.cardBorder, lineWidth: 1))
    }
}

extension View {
    /// Solid content-card surface. `active: true` = accent wash + accent border.
    func glassCard(active: Bool = false, cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        modifier(GlassCard(active: active, cornerRadius: cornerRadius))
    }
}
