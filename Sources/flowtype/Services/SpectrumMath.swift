import Foundation

/// Pure DSP helpers for the audio visualizer (no FFT here — see SpectrumAnalyzer).
enum SpectrumMath {

    /// Raised-cosine (Hann) envelope across `count` bar positions: ~0 at the edges,
    /// 1 at the center. Used to weight bars into a center-high soundwave silhouette.
    static func centerEnvelope(count: Int) -> [Float] {
        guard count > 1 else { return count == 1 ? [1] : [] }
        return (0..<count).map { i in
            let x = Float(i) / Float(count - 1)        // 0...1
            return 0.5 - 0.5 * cos(2 * Float.pi * x)   // 0 at edges, 1 at center
        }
    }

    /// Maps an FFT magnitude spectrum (length fftSize/2) into `bandCount` log-spaced
    /// bands across [minHz, maxHz], averaging magnitudes within each band.
    static func logBin(_ magnitudes: [Float], sampleRate: Float, fftSize: Int,
                       bandCount: Int, minHz: Float, maxHz: Float) -> [Float] {
        guard bandCount > 0, magnitudes.count > 1, maxHz > minHz, minHz > 0 else {
            return [Float](repeating: 0, count: max(bandCount, 0))
        }
        let binHz = sampleRate / Float(fftSize)
        let logMin = log(minHz)
        let logMax = log(maxHz)
        var bands = [Float](repeating: 0, count: bandCount)
        var counts = [Int](repeating: 0, count: bandCount)
        for bin in 1..<magnitudes.count {              // skip DC (bin 0)
            let hz = Float(bin) * binHz
            if hz < minHz || hz > maxHz { continue }
            let t = (log(hz) - logMin) / (logMax - logMin)
            var band = Int(t * Float(bandCount))
            if band >= bandCount { band = bandCount - 1 }
            if band < 0 { band = 0 }
            bands[band] += magnitudes[bin]
            counts[band] += 1
        }
        for i in 0..<bandCount where counts[i] > 0 {
            bands[i] /= Float(counts[i])
        }
        return bands
    }

    /// Normalizes band energies to 0...1 against a reference level.
    static func normalize(_ bands: [Float], reference: Float) -> [Float] {
        let ref = Swift.max(reference, 1e-6)
        return bands.map { Swift.min(Swift.max($0, 0) / ref, 1.0) }
    }

    /// Per-band attack-fast / decay-slow smoothing toward `target`.
    static func smooth(previous: [Float], target: [Float], attack: Float, decay: Float) -> [Float] {
        guard previous.count == target.count else { return target }
        return zip(previous, target).map { prev, tgt in
            let rate = tgt > prev ? attack : decay
            return prev + (tgt - prev) * rate
        }
    }
}
