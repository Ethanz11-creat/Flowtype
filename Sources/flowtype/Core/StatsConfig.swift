import Foundation
import CoreGraphics

/// Single home for all stats thresholds / conversion constants / layout sizes.
enum StatsConfig {
    // Baseline typing speed (字/min) for the "节省时间" estimate. FIXED by design — NOT user-editable:
    // a realistic "average person" rate (40–50 字/min) keeps 节省时间 honest. Too low a baseline would
    // inflate 节省时间 and read as fake for a production tool. 节省时间 = max(0, 字数/baselineCPM − 录音分钟).
    static let baselineCPM = 45

    // Heatmap: index by level (0 = empty → uses Theme.heatEmpty, so [0] is a placeholder).
    // PRD §8: levels 1…4 = #8E7DF5 at 0.35 / 0.6 / 0.85 / 1.0.
    static let heatOpacity: [Double] = [0, 0.35, 0.6, 0.85, 1.0]

    // Streak milestones (days) + per-tier flame colors (PRD §6). Colors are 0xRRGGBB; views map via Color(hex:).
    static let milestones: [Int] = [3, 7, 14, 30, 60, 100, 365]
    static let milestoneStartHex: UInt = 0xFFB454            // flame color while streak < first milestone
    static let milestoneTierHex: [Int: UInt] = [
        3: 0xFFB454, 7: 0xFF8A3D, 14: 0xFF6B35, 30: 0xFF4D4D,
        60: 0xE0479E, 100: 0xA99BFF, 365: 0xFFD24D,
    ]
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
