import SwiftUI

/// Ten audio-driven bars in the capsule's fixed 40 × 24 region.
struct AudioVisualizer: View {
    @EnvironmentObject var session: SessionController

    var body: some View {
        WaveformBars(frame: session.visualizationFrame, active: session.sessionState.isRecordingIndicator)
            .id(session.currentSessionIdentifier)
    }
}

private struct WaveformBars: View {
    let frame: AudioVisualizationFrame
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = DiffusionWaveform()

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 60, paused: !active)) { _ in
            let heights = active
                ? motion.heights(at: ProcessInfo.processInfo.systemUptime, reduceMotion: reduceMotion)
                : Array(repeating: 2, count: DiffusionWaveform.barCount)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<DiffusionWaveform.barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor(index))
                        .frame(width: 2, height: heights[index])
                }
            }
            .frame(width: 40, height: 24)
        }
        .transaction { $0.animation = nil }
        .onChange(of: frame, initial: true) { _, next in
            if active { motion.accept(next) }
        }
        .onChange(of: active) { _, recording in
            motion.reset()
            if recording { motion.accept(frame) }
        }
    }

    private func barColor(_ index: Int) -> Color {
        let edge = abs(Double(index) - 4.5) / 4.5
        return Color(red: 0.522 - 0.22 * edge, green: 0.361 + 0.27 * edge, blue: 1)
    }
}
