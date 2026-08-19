import Foundation

/// Encodes raw little-endian Float32 PCM samples into a 16-bit PCM WAV container.
///
/// Shared by every provider that must hand a WAV file/body to a remote or framework API:
/// - `CloudASRProvider` (multipart upload to an OpenAI-compatible speech endpoint)
/// - `AppleSpeechProvider` (`SFSpeechURLRecognitionRequest` needs a real WAV file)
///
/// `samples` is the `SpeechProvider.transcribe(audioData:)` contract format — raw
/// Float32 samples, NOT a WAV container.
enum WAVEncoder {
    static func encode(samples: Data, sampleRate: Int) -> Data? {
        let floatCount = samples.count / MemoryLayout<Float>.stride
        guard floatCount > 0 else { return nil }

        var wav = Data()

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * Int(numChannels) * Int(bitsPerSample) / 8
        let blockAlign = Int(numChannels) * Int(bitsPerSample) / 8
        let dataSize = floatCount * Int(bitsPerSample) / 8
        let chunkSize = 36 + dataSize

        wav.append("RIFF".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)

        wav.append("fmt ".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        wav.append("data".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })

        samples.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let floatPtr = buffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<floatCount {
                let sample = floatPtr[i]
                let clamped = max(-1.0, min(1.0, sample))
                let intSample = Int16(clamped * 32767.0)
                wav.append(withUnsafeBytes(of: intSample.littleEndian) { Data($0) })
            }
        }

        return wav
    }
}