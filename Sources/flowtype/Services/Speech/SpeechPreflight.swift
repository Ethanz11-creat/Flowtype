import Foundation

enum SpeechPreflightUnknownReason: Equatable, Sendable {
    case tooShort, unsupportedSampleRate, invalidSamples, detectorUnavailable
}

enum SpeechPreflightDecision: Equatable, Sendable {
    case emptyCapture, clearlySilent, possiblySpeech
    case indeterminate(SpeechPreflightUnknownReason)
}

struct SpeechPreflightPolicy: Sendable {
    let sampleRate: Int
    let frameSamples: Int
    let minimumSamples: Int
    let maximumFrameRMS: Float
    let maximumPeak: Float

    // Float32 candidate thresholds for initial calibration, not microphone validation.
    static let conservative = SpeechPreflightPolicy(sampleRate: 16000, frameSamples: 320,
        minimumSamples: 1600, maximumFrameRMS: 0.0003, maximumPeak: 0.001)

    private init(sampleRate: Int, frameSamples: Int, minimumSamples: Int,
                 maximumFrameRMS: Float, maximumPeak: Float) {
        self.sampleRate = sampleRate
        self.frameSamples = frameSamples
        self.minimumSamples = minimumSamples
        self.maximumFrameRMS = maximumFrameRMS
        self.maximumPeak = maximumPeak
    }
}

typealias SpeechPreflightAnalyzer = @Sendable ([Float], Int) throws -> SpeechPreflightDecision

enum SpeechPreflight {
    nonisolated static func analyze(samples: [Float], sampleRate: Int = 16000,
                                    policy: SpeechPreflightPolicy = .conservative) throws -> SpeechPreflightDecision {
        try Task.checkCancellation()
        guard !samples.isEmpty else { return .emptyCapture }
        guard sampleRate == policy.sampleRate else { return .indeterminate(.unsupportedSampleRate) }

        var peak: Float = 0
        var exceedsFrameRMS = false
        var frameStart = 0
        while frameStart < samples.count {
            try Task.checkCancellation()
            let frameEnd = min(frameStart + policy.frameSamples, samples.count)
            var sumSquares: Double = 0
            for index in frameStart..<frameEnd {
                let sample = samples[index]
                guard sample.isFinite, abs(sample) <= 1 else { return .indeterminate(.invalidSamples) }
                peak = max(peak, abs(sample))
                let value = Double(sample)
                sumSquares += value * value
            }
            // Accumulate in Double but compare at the specified Float32 boundary.
            let rms = Float(sqrt(sumSquares / Double(frameEnd - frameStart)))
            if rms > policy.maximumFrameRMS { exceedsFrameRMS = true }
            // Keep scanning after sound so malformed tails never become possiblySpeech.
            frameStart = frameEnd
        }
        try Task.checkCancellation()
        guard samples.count >= policy.minimumSamples else { return .indeterminate(.tooShort) }
        return exceedsFrameRMS || peak > policy.maximumPeak ? .possiblySpeech : .clearlySilent
    }

    nonisolated static func evaluate(samples: [Float], sampleRate: Int = 16000,
        using analyzer: @escaping SpeechPreflightAnalyzer = { try SpeechPreflight.analyze(samples: $0, sampleRate: $1) }
    ) async throws -> SpeechPreflightDecision {
        try Task.checkCancellation()
        // A synchronous seam keeps production and responsiveness tests on the
        // same detached execution boundary, even when called from MainActor.
        let worker = Task.detached {
            try Task.checkCancellation()
            return try analyzer(samples, sampleRate)
        }
        return try await withTaskCancellationHandler {
            do {
                let decision = try await worker.value
                // An analyzer may finish just as cancellation arrives, or ignore
                // it itself. Await its exit, then suppress any obsolete result.
                try Task.checkCancellation()
                return decision
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }
}
