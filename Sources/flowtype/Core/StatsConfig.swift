import Foundation
import CoreGraphics

/// Single home for all stats thresholds / conversion constants / layout sizes.
enum StatsConfig {
    // Baseline typing speed (chars/min) for "time saved".
    static let baselineCPM = 40

    // Heatmap: 5 levels (0=empty … 4=very high) → single-hue opacity.
    static let heatOpacity: [Double] = [0.25, 0.45, 0.65, 0.85, 1.0]
    static func days(for range: StatsRange) -> Int {
        switch range { case .d7: return 7; case .d30: return 30; case .all: return 365 }
    }

    // Footer conversions.
    static let keystrokesPerChar = 1.0
    static let secondsPerMovie = 7200      // ~120 min
    static let secondsPerCoffee = 300      // ~5 min  (low-value fallback)
    static let charsPerBook = 730_000      // 《红楼梦》

    // Window + grid layout.
    static let minWindowWidth: CGFloat = 1040
    static let minWindowHeight: CGFloat = 700
    // Overview content column width. MUST stay ≤ (minWindowWidth − sidebar 176 − divider 1 − OverviewPage padding 64 = 799)
    // so the column is the binding width constraint from the very first pixel of resize — otherwise the content grows
    // with the window until the cap is reached (the "content width changes when you widen" bug). See OverviewPage cap-then-center.
    static let contentMaxWidth: CGFloat = 780
    static let cardMinWidth: CGFloat = 220
    static let cardMaxWidth: CGFloat = 320
}
