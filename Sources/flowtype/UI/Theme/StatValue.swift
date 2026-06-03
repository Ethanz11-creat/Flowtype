import SwiftUI

/// One part of a stat value: a number, optionally followed by a small unit.
struct StatSegment: Equatable {
    let number: String
    let unit: String?   // nil = plain number (no unit, e.g. word count)
}

/// Pure formatters that turn raw stats into big-number/small-unit segments.
enum StatFormatting {
    /// Whole seconds → big-number/small-unit h/m segments (prototype: "3h08m"; minutes zero-padded when hours present).
    static func duration(seconds: Int) -> [StatSegment] {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 {
            return [StatSegment(number: "\(h)", unit: "h"),
                    StatSegment(number: String(format: "%02d", m), unit: "m")]
        }
        return [StatSegment(number: "\(m)", unit: "m")]
    }

    static func speed(_ wpm: Int) -> [StatSegment] {
        [StatSegment(number: "\(max(0, wpm))", unit: " 字/分")]   // leading space → "142 字/分"
    }

    /// Plain value with no unit (e.g. word count) — a single unchanged big number.
    static func plain(_ text: String) -> [StatSegment] {
        [StatSegment(number: text, unit: nil)]
    }
}

struct StatValueView: View {
    let segments: [StatSegment]
    var numberSize: CGFloat = 22
    var unitSize: CGFloat = 11
    var numberWeight: Font.Weight = .semibold     // prototype .d = 600
    var numberColor: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Text(seg.number)
                    .font(.system(size: numberSize, weight: numberWeight))
                    .monospacedDigit()
                    .foregroundColor(numberColor)
                if let unit = seg.unit {
                    Text(unit)
                        .font(.system(size: unitSize, weight: .regular))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
