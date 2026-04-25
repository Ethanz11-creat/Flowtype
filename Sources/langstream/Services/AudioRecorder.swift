@preconcurrency import AVFoundation

enum AudioRecorderError: Error, Equatable {
    case permissionDenied
    case engineStartFailed
    case formatCreationFailed
}

final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var audioBuffer: AVAudioPCMBuffer?
    private nonisolated(unsafe) var isRecording = false
    private nonisolated(unsafe) var amplitudeContinuation: AsyncStream<Float>.Continuation?

    // Phase 2: Segment buffering for real-time refinement
    private nonisolated(unsafe) var segmentBuffers: [Data] = []
    private nonisolated(unsafe) var currentSegmentBuffer: AVAudioPCMBuffer?
    private let segmentDurationSeconds: Double = 3.0

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // nonisolated — ensures installTap closure is NOT created on @MainActor
    nonisolated func startRecording() async throws -> AsyncStream<Float> {
        guard await requestPermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioRecorderError.formatCreationFailed
        }

        audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 60)!
        isRecording = true
        segmentBuffers = []
        currentSegmentBuffer = nil

        return AsyncStream { continuation in
            self.amplitudeContinuation = continuation

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self, self.isRecording else { return }

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else { return }
                var error: NSError?
                let inputBuffer = buffer
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                // Append to accumulated full buffer
                if let mainBuffer = self.audioBuffer,
                   let mainData = mainBuffer.floatChannelData?[0],
                   let convertedData = convertedBuffer.floatChannelData?[0] {
                    let currentLength = Int(mainBuffer.frameLength)
                    let newLength = Int(convertedBuffer.frameLength)
                    if currentLength + newLength <= Int(mainBuffer.frameCapacity) {
                        for i in 0..<newLength {
                            mainData[currentLength + i] = convertedData[i]
                        }
                        mainBuffer.frameLength = AVAudioFrameCount(currentLength + newLength)
                    }
                }

                // Phase 2: Append to current segment buffer
                if self.currentSegmentBuffer == nil {
                    self.currentSegmentBuffer = self.createSegmentBuffer(format: format)
                }
                if let segBuffer = self.currentSegmentBuffer,
                   let segData = segBuffer.floatChannelData?[0],
                   let convertedData = convertedBuffer.floatChannelData?[0] {
                    let segCurrent = Int(segBuffer.frameLength)
                    let segNew = Int(convertedBuffer.frameLength)
                    let segCapacity = Int(segBuffer.frameCapacity)
                    let toCopy = min(segNew, segCapacity - segCurrent)
                    if toCopy > 0 {
                        for i in 0..<toCopy {
                            segData[segCurrent + i] = convertedData[i]
                        }
                        segBuffer.frameLength += AVAudioFrameCount(toCopy)
                    }
                    // If segment is full, convert to WAV and start new segment
                    if segBuffer.frameLength >= segBuffer.frameCapacity {
                        if let wavData = AudioFormatConverter.convertToWAV(segBuffer) {
                            self.segmentBuffers.append(wavData)
                        }
                        self.currentSegmentBuffer = self.createSegmentBuffer(format: format)
                    }
                }

                // Yield average amplitude for VU meter
                if let data = convertedBuffer.floatChannelData?[0] {
                    let frames = Int(convertedBuffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frames {
                        sum += abs(data[i])
                    }
                    let avg = frames > 0 ? sum / Float(frames) : 0
                    continuation.yield(avg)
                }
            }

            do {
                try self.engine.start()
            } catch {
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.stopRecording()
                }
            }
        }
    }

    nonisolated func stopRecording() -> (fullData: Data?, segments: [Data]) {
        isRecording = false
        amplitudeContinuation?.finish()
        amplitudeContinuation = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        // Flush partial segment
        if let segBuffer = currentSegmentBuffer, segBuffer.frameLength > 0 {
            if let wavData = AudioFormatConverter.convertToWAV(segBuffer) {
                segmentBuffers.append(wavData)
            }
        }
        currentSegmentBuffer = nil

        let segments = segmentBuffers
        segmentBuffers = []

        guard let buffer = audioBuffer else {
            return (nil, segments)
        }
        let fullData = AudioFormatConverter.convertToWAV(buffer)
        return (fullData, segments)
    }

    nonisolated func getSegmentCount() -> Int {
        return segmentBuffers.count + (currentSegmentBuffer != nil ? 1 : 0)
    }

    private func createSegmentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frameCapacity = AVAudioFrameCount(format.sampleRate * segmentDurationSeconds)
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
    }
}
