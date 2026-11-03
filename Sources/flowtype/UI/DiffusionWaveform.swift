import Foundation

/// Audio events, not render ticks, determine the motion. Evaluate analytically at
/// any elapsed time so 30/60/120Hz rendering has the same attack, travel and decay.
struct DiffusionWaveform {
    static let barCount = 10
    static let staleAfter: TimeInterval = 0.25
    private var history: [AudioVisualizationFrame] = []

    mutating func accept(_ frame: AudioVisualizationFrame) {
        guard history.last.map({ frame.timestamp >= $0.timestamp }) ?? true else { return }
        history.append(frame)
        let cutoff = frame.timestamp - 3
        history.removeAll { $0.timestamp < cutoff }
        if history.count > 128 { history.removeFirst(history.count - 128) }
    }

    mutating func reset() { history.removeAll(keepingCapacity: true) }

    func heights(at time: TimeInterval, reduceMotion: Bool = false) -> [Double] {
        guard time.isFinite else { return Array(repeating: 2, count: Self.barCount) }
        return (0..<Self.barCount).map { index in
            let distance = abs(Double(index) - 4.5) - 0.5
            // Fixed offsets are stable across sessions; no random or synthetic activity.
            let delay = reduceMotion ? 0 : distance * 0.033 + (index < 5 ? 0 : 0.006)
            let sampleTime = time - delay
            var value = 0.0
            var cursor = history.first?.timestamp ?? sampleTime
            var target = 0.0
            var expiry = cursor
            func approach(_ end: Double) {
                guard end > cursor else { return }
                let tau = target > value ? 0.035 : 0.18
                value = target + (value - target) * exp(-(end - cursor) / tau)
                cursor = end
            }
            for frame in history where frame.timestamp <= sampleTime {
                if expiry < frame.timestamp {
                    approach(expiry)
                    target = 0
                }
                approach(frame.timestamp)
                let detailIndex = frame.spectrum.isEmpty ? nil : index * (frame.spectrum.count - 1) / 9
                let detail = detailIndex.map { Double(frame.spectrum[$0]) } ?? 0
                let attenuation = reduceMotion ? 0.72 : 1 - distance * 0.105
                let asymmetry = index < 5 ? 0.98 : 0.94
                target = frame.level * attenuation * asymmetry * (0.90 + 0.10 * detail)
                expiry = frame.timestamp + Self.staleAfter
            }
            if expiry < sampleTime {
                approach(expiry)
                target = 0
            }
            approach(sampleTime)
            // Snap tiny exponential tails to exact silence, with a strict 2…18 range.
            let height = min(18, max(2, 2 + 16 * value))
            return height < 2.01 ? 2 : height
        }
    }
}
