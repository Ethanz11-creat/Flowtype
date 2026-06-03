import SwiftUI

/// One part of a stat value: a number, optionally followed by a small unit.
struct StatSegment: Equatable {
    let number: String
    let unit: String?   // nil = plain number (no unit, e.g. word count)
}

/// Pure formatters that turn raw stats into big-number/small-unit segments.
enum StatFormatting {
    /// Whole seconds → 小时/分钟 segments (hours omitted when zero).
    static func duration(seconds: Int) -> [StatSegment] {
        let s = max(0, seconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours > 0 {
            return [StatSegment(number: "\(hours)", unit: "小时"),
                    StatSegment(number: "\(minutes)", unit: "分钟")]
        }
        return [StatSegment(number: "\(minutes)", unit: "分钟")]
    }

    static func speed(_ wpm: Int) -> [StatSegment] {
        [StatSegment(number: "\(max(0, wpm))", unit: "字/分")]
    }

    /// Plain value with no unit (e.g. word count) — a single unchanged big number.
    static func plain(_ text: String) -> [StatSegment] {
        [StatSegment(number: text, unit: nil)]
    }
}

/// Renders segments as big number + small muted unit, baseline-aligned, with spacing.
struct StatValueView: View {
    let segments: [StatSegment]
    var numberSize: CGFloat = 22
    var unitSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Text(seg.number)
                    .font(.system(size: numberSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                if let unit = seg.unit {
                    Text(" \(unit) ")
                        .font(.system(size: unitSize, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
