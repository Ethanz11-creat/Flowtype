import SwiftUI

/// Frequency-driven mirrored soundwave for the recording capsule.
struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    private static let barCount = 28
    private static let envelope = SpectrumMath.centerEnvelope(count: barCount)
    private let maxBarHeight: CGFloat = 24

    var body: some View {
        let active = session.sessionState.isRecordingIndicator
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                let level = barLevel(i, active: active)
                Capsule()
                    .fill(barColor(i, level: level))
                    .frame(width: 3, height: max(2, level * maxBarHeight))
                    .frame(maxHeight: .infinity, alignment: .center)   // grow up+down from center
            }
        }
        .frame(width: 112, height: maxBarHeight + 2)
        .animation(.easeOut(duration: 0.09), value: session.spectrum)  // tween between updates
    }

    /// Envelope-weighted band energy; a calm resting line when not recording.
    private func barLevel(_ i: Int, active: Bool) -> CGFloat {
        let env = CGFloat(Self.envelope[i])
        guard active else { return env * 0.06 }
        let band = i < session.spectrum.count ? CGFloat(session.spectrum[i]) : 0
        return env * max(band, 0.05)
    }

    /// Brand purple->blue gradient across bars; brighter where there's energy.
    private func barColor(_ i: Int, level: CGFloat) -> Color {
        let t = Double(i) / Double(Self.barCount - 1)
        let red = 0.55 + (0.30 - 0.55) * t
        let green = 0.35 + (0.65 - 0.35) * t
        let blue = 1.0
        let brightness = 0.45 + 0.55 * Double(min(level / 0.6, 1.0))
        return Color(red: red, green: green, blue: blue).opacity(brightness)
    }
}
