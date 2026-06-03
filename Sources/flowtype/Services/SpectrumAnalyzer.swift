import Accelerate

/// Turns 16 kHz mono Float32 audio buffers into smoothed, normalized frequency-band
/// energies for the capsule visualizer. Holds the FFT setup + smoothing state, so a
/// fresh instance should be used per recording session.
///
/// Not thread-safe: a single instance must be called serially (it is driven from the
/// audio tap callback, one buffer at a time).
final class SpectrumAnalyzer {
    let bandCount: Int
    let fftSize: Int
    let sampleRate: Float
    private let minHz: Float
    private let maxHz: Float
    private let attack: Float
    private let decay: Float

    /// Below this input RMS the buffer is treated as silence — bars decay flat instead of
    /// jittering on the mic noise floor (samples are normalized −1...1 Float32). Tune on device.
    private let silenceRMS: Float = 0.006

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let hann: [Float]
    private var smoothed: [Float]
    private var rollingMax: Float = 1e-6

    init(bandCount: Int = 28, fftSize: Int = 1024, sampleRate: Float = 16000,
         minHz: Float = 80, maxHz: Float = 6000, attack: Float = 0.7, decay: Float = 0.30) {
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.minHz = minHz
        self.maxHz = maxHz
        self.attack = attack
        self.decay = decay
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.hann = window
        self.smoothed = [Float](repeating: 0, count: bandCount)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Process one audio buffer → smoothed, normalized band energies (0...1, length bandCount).
    func process(_ samples: [Float]) -> [Float] {
        // Noise gate: when nobody is speaking, let the bars settle flat instead of jittering on
        // the mic noise floor (which reads as a constant "looping" wiggle).
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        if sqrt(meanSquare) < silenceRMS {
            smoothed = SpectrumMath.smooth(previous: smoothed,
                                           target: [Float](repeating: 0, count: bandCount),
                                           attack: attack, decay: decay)
            return smoothed
        }
        let mags = magnitudes(samples)
        let bands = SpectrumMath.logBin(mags, sampleRate: sampleRate, fftSize: fftSize,
                                        bandCount: bandCount, minHz: minHz, maxHz: maxHz)
        let peak = bands.max() ?? 0
        // Fast-decaying adaptive reference: it follows the recent speech envelope (~0.5s) instead
        // of latching onto a single loud syllable, so normal-volume speech keeps filling the bars.
        rollingMax = Swift.max(peak, rollingMax * 0.90)
        let normalized = SpectrumMath.normalize(bands, reference: rollingMax)
        smoothed = SpectrumMath.smooth(previous: smoothed, target: normalized, attack: attack, decay: decay)
        return smoothed
    }

    /// Resets smoothing state between sessions.
    func reset() {
        smoothed = [Float](repeating: 0, count: bandCount)
        rollingMax = 1e-6
    }

    /// Hann-windowed magnitude spectrum (length fftSize/2). Input is zero-padded or
    /// truncated to `fftSize`.
    func magnitudes(_ samples: [Float]) -> [Float] {
        let halfN = fftSize / 2
        var frame = [Float](repeating: 0, count: fftSize)
        let n = Swift.min(samples.count, fftSize)
        for i in 0..<n { frame[i] = samples[i] }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: DSPComplex.self).baseAddress {
                        vDSP_ctoz(base, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
            }
        }
        return mags
    }
}
