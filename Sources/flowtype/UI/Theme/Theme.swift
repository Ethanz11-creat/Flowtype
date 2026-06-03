import SwiftUI

/// Solid (opaque) content theme — adaptive light/dark. The window SHELL + sidebar stay frosted;
/// content panes use these solid surfaces for clean high-contrast (no frosted gray bleed).
enum Theme {
    static let pageBackground = Color(light: Color(red: 0.961, green: 0.961, blue: 0.969),  // #F5F5F7
                                      dark:  Color(red: 0.047, green: 0.047, blue: 0.059))   // #0C0C0F
    static let cardBackground = Color(light: .white,
                                      dark:  Color(red: 0.090, green: 0.090, blue: 0.110))   // #17171C
    static let cardBorder     = Color(light: Color.black.opacity(0.06),
                                      dark:  Color.white.opacity(0.06))
    static let textPrimary    = Color(light: Color(red: 0.10, green: 0.10, blue: 0.11),
                                      dark:  Color(red: 0.961, green: 0.961, blue: 0.969))
    static let textSecondary  = Color(light: Color(red: 0.42, green: 0.42, blue: 0.45),
                                      dark:  Color(red: 0.541, green: 0.541, blue: 0.573))
    static let heatEmpty      = Color(light: Color(red: 0.902, green: 0.902, blue: 0.918),   // #E6E6EA
                                      dark:  Color(red: 0.110, green: 0.110, blue: 0.133))    // #1C1C22
    static let accent = Brand.accent
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
}
