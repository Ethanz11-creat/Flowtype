import SwiftUI

extension Color {
    /// 0xRRGGBB → opaque sRGB Color.
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Solid (opaque) content theme — values transcribed from `docs/files/overview-prototype.html`
/// (dark = prototype-exact). The whole window is solid (no vibrancy/frost); light is a clean
/// solid variant so the appearance switch still works.
enum Theme {
    static let pageBackground    = Color(light: Color(hex: 0xF5F5F7), dark: Color(hex: 0x0C0C0F))
    static let sidebarBackground = Color(light: Color(hex: 0xECECEE), dark: Color(hex: 0x101013))
    static let cardBackground    = Color(light: .white,               dark: Color(hex: 0x17171C))
    static let cardBorder        = Color(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.07))
    static let textPrimary       = Color(light: Color(hex: 0x1A1A1C), dark: Color(hex: 0xF2F2F5))
    static let textSecondary     = Color(light: Color(hex: 0x6B6B72), dark: Color(hex: 0x8A8A92))
    static let accent            = Color(light: Color(hex: 0x6B4DE6), dark: Color(hex: 0x8E7DF5))  // fill
    static let accentBright      = Color(light: Color(hex: 0x6B4DE6), dark: Color(hex: 0xA99BFF))  // icons/peak bar
    static let accentText        = Color(light: Color(hex: 0x6B4DE6), dark: Color(hex: 0xB9AEFF))  // data numbers / active text
    static let warm              = Color(light: Color(hex: 0xE0901E), dark: Color(hex: 0xFFB454))  // achievements
    static let heatEmpty         = Color(light: Color(hex: 0xE6E6EA), dark: Color(hex: 0x1C1C22))
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 18
}
