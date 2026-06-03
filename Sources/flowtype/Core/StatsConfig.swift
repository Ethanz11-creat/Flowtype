import Foundation
import CoreGraphics

/// Single home for all stats thresholds / conversion constants / layout sizes.
enum StatsConfig {
    // Baseline typing speed (chars/min) for "time saved".
    static let baselineCPM = 40

    // Heatmap: 5 levels (0=empty … 4=very high) → single-hue opacity.
    static let heatOpacity: [Double] = [0.08, 0.30, 0.55, 0.80, 1.0]
    static func days(for range: StatsRange) -> Int {
        switch range { case .d7: return 7; case .d30: return 30; case .all: return 365 }
    }

    // Footer conversions.
    static let keystrokesPerChar = 1.0
    static let secondsPerMovie = 7200      // ~120 min
    static let secondsPerCoffee = 300      // ~5 min  (low-value fallback)
    static let charsPerBook = 730_000      // 《红楼梦》

    // Window + grid layout.
    static let minWindowWidth: CGFloat = 900
    static let minWindowHeight: CGFloat = 600
    static let cardMinWidth: CGFloat = 220
    static let cardMaxWidth: CGFloat = 320
}
