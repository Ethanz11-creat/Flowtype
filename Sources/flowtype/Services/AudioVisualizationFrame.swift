import Foundation

/// Absolute PCM energy and normalized frequency detail from the same audio buffer.
/// Timestamp uses system uptime, shared with the visualizer's monotonic render clock.
struct AudioVisualizationFrame: Sendable, Equatable {
    let spectrum: [Float]
    let rms: Float
    let timestamp: TimeInterval

    static let silence = AudioVisualizationFrame(samples: [], spectrum: [], timestamp: 0)

    init(samples: [Float], spectrum: [Float], timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.spectrum = spectrum.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        // Double accumulation avoids Float overflow. Invalid PCM contributes silence;
        // values beyond the physical PCM range are clipped only for visualization.
        let squareSum = samples.reduce(0.0) { sum, sample in
            let value = sample.isFinite ? min(1, max(-1, Double(sample))) : 0
            return sum + value * value
        }
        rms = samples.isEmpty ? 0 : Float(sqrt(squareSum / Double(samples.count)))
        self.timestamp = timestamp.isFinite ? max(0, timestamp) : 0
    }

    /// Fixed dB mapping, never an adaptive normalization that erases quiet/loud differences.
    var level: Double {
        guard rms > 0.001 else { return 0 }
        let db = 20 * log10(Double(rms))
        return pow(min(1, max(0, (db + 60) / 48)), 1.3)
    }
}

/// Lazy compatibility adapter: exactly one input iterator, with no forwarding Task,
/// duplicate stream or extra queue. Legacy spectrum fixtures honestly carry zero RMS.
struct RecordingVisualizationSequence: AsyncSequence, Sendable {
    typealias Element = AudioVisualizationFrame
    let frames: AsyncStream<AudioVisualizationFrame>?
    let legacySpectrum: AsyncStream<[Float]>?

    struct AsyncIterator: AsyncIteratorProtocol {
        var frames: AsyncStream<AudioVisualizationFrame>.Iterator?
        var legacySpectrum: AsyncStream<[Float]>.Iterator?
        mutating func next() async -> AudioVisualizationFrame? {
            if frames != nil { return await frames?.next() }
            guard let bands = await legacySpectrum?.next() else { return nil }
            return AudioVisualizationFrame(samples: [], spectrum: bands)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(frames: frames?.makeAsyncIterator(), legacySpectrum: legacySpectrum?.makeAsyncIterator())
    }
}
