@preconcurrency import AVFoundation

enum AudioRecorderError: Error, Equatable {
    case permissionDenied
    case engineStartFailed
    case formatCreationFailed
}

final class AudioRecorder: @unchecked Sendable {
    // NOTE: Create a fresh engine for each session to avoid state issues.
    private var engine: AVAudioEngine?
    private nonisolated(unsafe) var audioBuffer: AVAudioPCMBuffer?
    private nonisolated(unsafe) var isRecording = false
    private nonisolated(unsafe) var isStopping = false
    private nonisolated(unsafe) var amplitudeContinuation: AsyncStream<Float>.Continuation?

    // Phase 2: Segment buffering for real-time refinement
    private nonisolated(unsafe) var segmentBuffers: [Data] = []
    private nonisolated(unsafe) var currentSegmentBuffer: AVAudioPCMBuffer?
    private let segmentDurationSeconds: Double = 3.0

    // Diagnostics
    private nonisolated(unsafe) var tapCallCount = 0

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

        // Fresh engine for each session
        let freshEngine = AVAudioEngine()
        self.engine = freshEngine

        let inputNode = freshEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        print("[AudioRecorder] Hardware input format: \(inputFormat)")

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
        isStopping = false
        tapCallCount = 0
        segmentBuffers = []
        currentSegmentBuffer = nil

        return AsyncStream { continuation in
            self.amplitudeContinuation = continuation

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                guard let self = self else {
                    print("[AudioRecorder] Tap callback: self is nil")
                    return
                }
                guard self.isRecording || self.isStopping else {
                    return
                }

                self.tapCallCount += 1
                let callIndex = self.tapCallCount
                let inputFrames = Int(buffer.frameLength)
                print("[AudioRecorder] Tap #\(callIndex) fired: inputFrames=\(inputFrames), time=\(time)")

                // Converted buffer capacity: same as input buffer size is sufficient
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
                    print("[AudioRecorder] Tap #\(callIndex): failed to create convertedBuffer")
                    return
                }
                var error: NSError?
                let inputBuffer = buffer
                var inputConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if !inputConsumed {
                        inputConsumed = true
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                }

                if let err = error {
                    print("[AudioRecorder] Tap #\(callIndex): converter error: \(err)")
                }
                let outputFrames = Int(convertedBuffer.frameLength)
                print("[AudioRecorder] Tap #\(callIndex): converted outputFrames=\(outputFrames)")

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
                        print("[AudioRecorder] Tap #\(callIndex): appended to audioBuffer, totalFrames=\(currentLength + newLength)")
                    } else {
                        print("[AudioRecorder] WARNING: Recording exceeded 60s, truncating")
                    }
                } else {
                    print("[AudioRecorder] Tap #\(callIndex): audioBuffer is nil or channel data missing")
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
                    self.amplitudeContinuation?.yield(avg)
                }
            }

            do {
                freshEngine.prepare()
                try freshEngine.start()
                print("[AudioRecorder] Engine prepared and started successfully")
            } catch {
                print("[AudioRecorder] Engine start FAILED: \(error)")
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
        print("[AudioRecorder] stopRecording called, tapCallCount=\(tapCallCount)")

        if tapCallCount == 0 {
            print("[AudioRecorder] CRITICAL: No tap callbacks received. Possible causes:")
            print("  - Microphone permission denied (check System Settings > Privacy > Microphone)")
            print("  - No input device available")
            print("  - AVAudioEngine failed to start")
        }

        // Graceful stop: allow final buffer to be processed before cutting off
        isStopping = true
        Thread.sleep(forTimeInterval: 0.05) // 50ms grace period for last frame

        // Prevent new callbacks from writing
        isRecording = false
        amplitudeContinuation?.finish()
        amplitudeContinuation = nil

        // Stop engine and remove tap
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        isStopping = false

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
            print("[AudioRecorder] stopRecording: audioBuffer is nil")
            return (nil, segments)
        }

        let rawFrames = Int(buffer.frameLength)
        print("[AudioRecorder] stopRecording: raw audioBuffer has \(rawFrames) frames")

        // Trim silence, normalize, convert to WAV
        let trimmedBuffer = AudioFormatConverter.trimSilence(buffer)
        let trimmedFrames = Int(trimmedBuffer.frameLength)
        print("[AudioRecorder] stopRecording: after trimSilence has \(trimmedFrames) frames")

        let fullData = AudioFormatConverter.normalizeAndConvertToWAV(trimmedBuffer)

        if let data = fullData {
            let payload = data.count - 44
            let duration = Double(payload) / 32000.0
            print("[AudioRecorder] stopRecording: final WAV \(data.count) bytes, ~\(String(format: "%.2f", duration))s")
        } else {
            print("[AudioRecorder] stopRecording: normalizeAndConvertToWAV returned nil")
        }

        // Debug dump if enabled
        if let data = fullData, Configuration.shared.dumpAudio {
            dumpWAVData(data)
        }

        return (fullData, segments)
    }

    nonisolated func getSegmentCount() -> Int {
        return segmentBuffers.count + (currentSegmentBuffer != nil ? 1 : 0)
    }

    private func createSegmentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frameCapacity = AVAudioFrameCount(format.sampleRate * segmentDurationSeconds)
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
    }

    private func dumpWAVData(_ data: Data) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "dump_\(formatter.string(from: Date())).wav"
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/langstream", isDirectory: true) else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url)
            print("[AudioRecorder] Dumped audio to \(url.path)")
        } catch {
            print("[AudioRecorder] Failed to dump audio: \(error)")
        }
    }
}
