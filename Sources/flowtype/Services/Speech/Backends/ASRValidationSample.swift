import CryptoKit
import Foundation

struct ASRValidationSample: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let sha256: String
    let label: String

    enum ValidationError: Error { case invalidSampleRate, emptySamples, invalidSHA256 }

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

    /// A supplied fingerprint must match canonical PCM, independent of resource packaging.
    /// Container checksums belong in separate resource metadata.
    init(samples: [Float], sampleRate: Int, sha256: String, label: String) throws {
        try self.init(samples: samples, sampleRate: sampleRate, label: label)
        guard sha256 == self.sha256 else { throw ValidationError.invalidSHA256 }
    }

    private static func validate(samples: [Float], sampleRate: Int) throws {
        guard sampleRate == 16_000 else { throw ValidationError.invalidSampleRate }
        guard !samples.isEmpty else { throw ValidationError.emptySamples }
    }
}
