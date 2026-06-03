import SwiftUI

/// Soundwave for the recording capsule. Broadly middle-tall / edges-short (a center envelope
/// shapes the silhouette), but each bar is driven by its OWN frequency sample so the wave
/// flickers naturally and is NOT a rigid left/right mirror — closer to how Typeless looks.
/// Overall height rises and falls with loudness; a calm low line shows when not recording.
struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    private static let barCount = 9
    private static let center = barCount / 2
    private static let envelope = SpectrumMath.centerEnvelope(count: barCount)
    private let maxBarHeight: CGFloat = 20
    private let minBarHeight: CGFloat = 3

    var body: some View {
        let active = session.sessionState.isRecordingIndicator
        let spec = session.spectrum
        let samples = Self.sample(spec, count: Self.barCount)     // per-bar freq detail (asymmetric)
        let loud = spec.isEmpty ? 0 : CGFloat(spec.max() ?? 0)    // overall loudness 0...1
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let level = barLevel(i, active: active, detail: samples[i], loud: loud)
                Capsule()
                    .fill(barColor(i, level: level))
                    .frame(width: 3, height: minBarHeight + level * (maxBarHeight - minBarHeight))
            }
        }
        .frame(width: 40, height: 24)  // original compact footprint, left of the status circle
        .animation(.easeOut(duration: 0.08), value: session.spectrum)  // tween between updates
    }

    /// Sample the (low→high) spectrum at `count` points so each bar gets a DISTINCT band — this is
    /// what breaks the rigid mirror symmetry and gives a natural, lively, slightly-uneven flicker.
    private static func sample(_ spec: [Float], count: Int) -> [CGFloat] {
        guard !spec.isEmpty, count > 0 else { return Array(repeating: 0, count: count) }
        let n = spec.count
        return (0..<count).map { i in
            let idx = count == 1 ? 0 : i * (n - 1) / (count - 1)
            return CGFloat(spec[Swift.min(idx, n - 1)])
        }
    }

    /// Silhouette = center envelope (broad middle-tall / short edges); per-bar frequency detail adds
    /// the asymmetric flicker; overall amplitude follows loudness. Deliberately NOT a strict mirror.
    private func barLevel(_ i: Int, active: Bool, detail: CGFloat, loud: CGFloat) -> CGFloat {
        let env = CGFloat(Self.envelope[i])
        guard active else { return env * 0.12 }
        let shape = 0.22 + 0.78 * env                 // broad middle-tall silhouette
        let flicker = 0.55 + 0.45 * detail            // distinct per-bar band → asymmetric motion
        let level = shape * flicker * (0.45 + 0.55 * loud)
        return Swift.min(Swift.max(level, 0.04), 1.0)
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
