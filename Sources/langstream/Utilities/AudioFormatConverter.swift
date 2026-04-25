import Foundation
import AVFoundation

enum AudioFormatConverter {
    static func convertToWAV(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = Int32(buffer.format.sampleRate)
        let channels = UInt16(buffer.format.channelCount)

        // Convert float to Int16
        var int16Data = Data()
        int16Data.reserveCapacity(frameLength * 2)

        for i in 0..<frameLength {
            let sample = max(-1.0, min(1.0, channelData[i]))
            let int16Sample = Int16(sample * 32767.0)
            var value = int16Sample.littleEndian
            int16Data.append(UnsafeBufferPointer(start: &value, count: 1))
        }

        // WAV header
        let header = createWAVHeader(dataSize: int16Data.count, sampleRate: sampleRate, channels: channels)
        return header + int16Data
    }

    private static func createWAVHeader(dataSize: Int, sampleRate: Int32, channels: UInt16) -> Data {
        var header = Data()
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let totalSize = UInt32(36 + dataSize)

        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: totalSize.littleEndian, { Data($0) }))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian, { Data($0) })) // PCM
        header.append(withUnsafeBytes(of: channels.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: sampleRate.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: byteRate.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: blockAlign.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian, { Data($0) }))
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian, { Data($0) }))

        return header
    }
}
