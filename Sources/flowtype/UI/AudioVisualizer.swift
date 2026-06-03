import SwiftUI

/// Mirror-spectrum soundwave for the recording capsule. The bars are symmetric around the
/// center: the middle shows the LOW-frequency band (where speech energy concentrates, so it
/// sits tallest), and the two ends show progressively HIGHER frequencies (quieter, so they
/// sit lower). Each tier still reacts to its own band's energy, so the wave reflects what you
/// actually say; a calm low line shows when not recording.
struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    private static let barCount = 9
    private static let center = barCount / 2          // index 4
    private static let tierCount = 5                  // center tier + 4 mirrored tiers outward
    private static let envelope = SpectrumMath.centerEnvelope(count: barCount)
    private let maxBarHeight: CGFloat = 20
    private let minBarHeight: CGFloat = 3

    var body: some View {
        let active = session.sessionState.isRecordingIndicator
        let tiers = Self.fold(session.spectrum, into: Self.tierCount)
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let level = barLevel(i, active: active, tiers: tiers)
                Capsule()
                    .fill(barColor(i, level: level))
                    .frame(width: 3, height: minBarHeight + level * (maxBarHeight - minBarHeight))
            }
        }
        .frame(width: 40, height: 24)  // original compact footprint, left of the status circle
        .animation(.easeOut(duration: 0.08), value: session.spectrum)  // tween between updates
    }

    /// Average the (low→high) spectrum into `count` frequency tiers (tier 0 = lowest band).
    private static func fold(_ spec: [Float], into count: Int) -> [CGFloat] {
        guard !spec.isEmpty, count > 0 else { return Array(repeating: 0, count: count) }
        let n = spec.count
        return (0..<count).map { j in
            let lo = j * n / count
            let hi = Swift.max(lo + 1, (j + 1) * n / count)
            let slice = spec[lo..<Swift.min(hi, n)]
            return CGFloat(slice.reduce(0, +) / Float(slice.count))
        }
    }

    /// Mirror layout: center bar = tier 0 (low freq), ends = tier 4 (high freq). A light center
    /// envelope keeps the silhouette middle-tall even when a high-frequency tier briefly spikes.
    private func barLevel(_ i: Int, active: Bool, tiers: [CGFloat]) -> CGFloat {
        let env = CGFloat(Self.envelope[i])
        guard active else { return env * 0.12 }
        let tier = Swift.min(abs(i - Self.center), tiers.count - 1)
        let band = tiers[tier]
        let shaped = band * (0.6 + 0.4 * env)
        return Swift.min(Swift.max(shaped, 0.04), 1.0)
    }

    /// Symmetric color: center is brighter brand-purple, ends fade toward blue; brighter with energy.
    private func barColor(_ i: Int, level: CGFloat) -> Color {
        let d = Double(abs(i - Self.center)) / Double(Self.center)   // 0 = center … 1 = ends
        let red = 0.55 + (0.30 - 0.55) * d
        let green = 0.35 + (0.60 - 0.35) * d
        let blue = 1.0
        let brightness = 0.45 + 0.55 * Double(min(level / 0.6, 1.0))
        return Color(red: red, green: green, blue: blue).opacity(brightness)
    }
}
