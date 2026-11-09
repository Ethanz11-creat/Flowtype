import CryptoKit
import Foundation

struct ASRValidationSample: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let sha256: String
    let label: String

    enum ValidationError: Error { case invalidSampleRate, emptySamples }

    /// Runtime samples use a fingerprint of canonical little-endian Float32 PCM bytes.
    init(samples: [Float], sampleRate: Int, label: String) throws {
        try Self.validate(samples: samples, sampleRate: sampleRate)
        var hash = SHA256()
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { hash.update(bufferPointer: $0) }
        }
        self.samples = samples
        self.sampleRate = sampleRate
        self.sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        self.label = label
    }

    /// Trusted sample resources may supply a fingerprint of their packaged container.
    /// The resource owner defines that fingerprint; it is not recomputed as PCM here.
    init(samples: [Float], sampleRate: Int, sha256: String, label: String) throws {
        try Self.validate(samples: samples, sampleRate: sampleRate)
        self.samples = samples
        self.sampleRate = sampleRate
        self.sha256 = sha256
        self.label = label
    }

    private static func validate(samples: [Float], sampleRate: Int) throws {
        guard sampleRate == 16_000 else { throw ValidationError.invalidSampleRate }
        guard !samples.isEmpty else { throw ValidationError.emptySamples }
    }
}
