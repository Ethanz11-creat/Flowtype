import SwiftUI

/// Compact frequency-driven soundwave for the recording capsule — one bar per frequency
/// band. Each bar rises and falls with the energy in its band, so the wave reacts to what
/// you actually say in real time; a calm low line shows when not recording.
struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    private static let barCount = 9
    private static let envelope = SpectrumMath.centerEnvelope(count: barCount)
    private let maxBarHeight: CGFloat = 20
    private let minBarHeight: CGFloat = 3

    var body: some View {
        let active = session.sessionState.isRecordingIndicator
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let level = barLevel(i, active: active)
                Capsule()
                    .fill(barColor(i, level: level))
                    .frame(width: 3, height: minBarHeight + level * (maxBarHeight - minBarHeight))
            }
        }
        .frame(width: 40, height: 24)  // original compact footprint, left of the status circle
        .animation(.easeOut(duration: 0.08), value: session.spectrum)  // tween between updates
    }

    /// Per-band energy drives each bar; a faint resting line when not recording. The band
    /// itself supplies the motion — the envelope only nudges the wave toward a voice-like
    /// shape so the center sits a touch taller than the edges.
    private func barLevel(_ i: Int, active: Bool) -> CGFloat {
        let env = CGFloat(Self.envelope[i])
        guard active else { return env * 0.12 }
        let band = i < session.spectrum.count ? CGFloat(session.spectrum[i]) : 0
        let shaped = band * (0.7 + 0.3 * env)
        return min(max(shaped, 0.04), 1.0)
    }

    /// Brand purple->blue gradient across bars; brighter where there's energy.
    private func barColor(_ i: Int, level: CGFloat) -> Color {
        let t = Double(i) / Double(Self.barCount - 1)
        let red = 0.55 + (0.30 - 0.55) * t
        let green = 0.35 + (0.65 - 0.35) * t
        let blue = 1.0
        let brightness = 0.5 + 0.5 * Double(min(level / 0.6, 1.0))
        return Color(red: red, green: green, blue: blue).opacity(brightness)
    }
}
