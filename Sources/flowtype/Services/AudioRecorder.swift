@preconcurrency import AVFoundation
import os

enum AudioRecorderError: Error, Equatable {
    case permissionDenied
    case engineStartFailed
    case formatCreationFailed
}

/// Output streams from a recording session.
struct RecordingOutput: @unchecked Sendable {
    /// Per-buffer frequency-band energies (0...1) for the visualizer.
    let spectrum: AsyncStream<[Float]>
}

final class AudioRecorder: @unchecked Sendable {
    // Security: hard cap at 30 minutes of 16kHz Float32 audio (~110 MB)
    private static let maxRawSamples = 28_800_000 // 16000 Hz * 60 s/min * 30 min

    private var engine: AVAudioEngine?
    private let spectrumAnalyzer = SpectrumAnalyzer()
    private nonisolated(unsafe) var spectrumContinuation: AsyncStream<[Float]>.Continuation?

    // Raw sample accumulator for batch ASR (Qwen3-ASR)
    private var rawSamples: [Float] = []
    private let sampleLock = OSAllocatedUnfairLock()

    // Recording state
    private let stateLock = OSAllocatedUnfairLock()
    private var _isRecording = false
    private var _isStopping = false

    var isRecording: Bool {
        stateLock.withLock { _isRecording }
    }
    var isStopping: Bool {
        stateLock.withLock { _isStopping }
    }

    // Original default input device to restore after recording
    private nonisolated(unsafe) var originalDeviceID: AudioObjectID = kAudioObjectUnknown

    // Diagnostics
    private struct HeartbeatState {
        var tapCallCount = 0
        var lastTapCallCount = 0
        var lastTapTimestamp: Date?
    }
    private let heartbeatLock = OSAllocatedUnfairLock<HeartbeatState>(uncheckedState: HeartbeatState())

    /// Callback to forward real-time audio buffers to a streaming recognizer.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when no audio tap callbacks have been received for a while.
    var onRecordingFrozen: (() -> Void)?

    // MARK: - Heartbeat detection
    private var heartbeatTimer = CancellableTimer()
    private let heartbeatInterval: TimeInterval = 2.0
    private let heartbeatTimeout: TimeInterval = 5.0

    func authorizationStatus() -> Int {
        AVAudioApplication.shared.recordPermission.rawValue
    }

    func requestPermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        AppLogger.log("AudioRecorder: mic status = \(status) (undetermined/denied/granted)")
        guard status == .undetermined else {
            AppLogger.log("AudioRecorder: mic status is not undetermined, skipping request")
            return status == .granted
        }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        AppLogger.log("AudioRecorder: mic request result = \(granted)")
        return granted
    }

    nonisolated func startRecording(deviceID: String? = nil) async throws -> RecordingOutput {
        guard await requestPermission() else {
            throw AudioRecorderError.permissionDenied
        }

        // Fresh visualizer state per session. Relies on start/stop being serial (the same
        // assumption the engine reuse makes): after this, only the audio tap touches the
        // analyzer, one buffer at a time.
        spectrumAnalyzer.reset()

        let freshEngine = AVAudioEngine()
        self.engine = freshEngine

        // Route to specific device if requested
        if let requestedDeviceID = deviceID {
            if let audioDeviceID = AudioDeviceEnumerator.findDeviceID(uid: requestedDeviceID) {
                AppLogger.log("[AudioRecorder] Routing to device: \(requestedDeviceID)")
                // Save original default device
                var propertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var originalSize = UInt32(MemoryLayout<AudioObjectID>.size)
                let originalResult = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    &originalSize,
                    &originalDeviceID
                )
                if originalResult != noErr {
                    AppLogger.log("[AudioRecorder] Failed to save original device: \(originalResult)")
                    originalDeviceID = kAudioObjectUnknown
                }
                // Set requested device
                var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
                var mutableAudioDeviceID = audioDeviceID
                let setResult = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    deviceIDSize,
                    &mutableAudioDeviceID
                )
                if setResult != noErr {
                    AppLogger.log("[AudioRecorder] Failed to set default input device: \(setResult), falling back")
                    originalDeviceID = kAudioObjectUnknown
                }
            } else {
                AppLogger.log("[AudioRecorder] Requested device \(requestedDeviceID) not found, using default")
            }
        }

        let inputNode = freshEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        AppLogger.log("[AudioRecorder] Hardware input format: \(inputFormat)")

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

        stateLock.withLock {
            _isRecording = true
            _isStopping = false
        }
        heartbeatLock.withLock { state in
            state.tapCallCount = 0
            state.lastTapCallCount = 0
            state.lastTapTimestamp = Date()
        }
        sampleLock.withLock {
            rawSamples.removeAll(keepingCapacity: true)
        }
        heartbeatTimer.schedule(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] in
            guard let self = self else { return }
            guard self.isRecording && !self.isStopping else { return }
            let (currentCount, lastCount, lastTimestamp) = self.heartbeatLock.withLock { state in
                (state.tapCallCount, state.lastTapCallCount, state.lastTapTimestamp)
            }
            let now = Date()
            if currentCount > lastCount {
                self.heartbeatLock.withLock { state in
                    state.lastTapCallCount = currentCount
                    state.lastTapTimestamp = now
                }
            } else if let lastTap = lastTimestamp, now.timeIntervalSince(lastTap) > self.heartbeatTimeout {
                guard self.isRecording && !self.isStopping else { return }
                AppLogger.log("[AudioRecorder] HEARTBEAT FAILURE: No tap callbacks for \(self.heartbeatTimeout)s. Auto-stopping.")
                self.heartbeatTimer.cancel()
                // Notify first (sets the freeze flag), then end the spectrum stream so
                // RecordingStage's `for await` returns instead of suspending forever.
                // finish() is idempotent, so a later stopRecording() is safe.
                self.onRecordingFrozen?()
                self.spectrumContinuation?.finish()
            }
        }

        let spectrumStream = AsyncStream<[Float]> { continuation in
            self.spectrumContinuation = continuation

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                guard let self = self else { return }
                guard self.isRecording || self.isStopping else { return }

                self.heartbeatLock.withLock { $0.tapCallCount += 1 }

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
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

                // Forward to streaming recognizer (AppleSpeech preview)
                self.onAudioBuffer?(convertedBuffer)

                // Accumulate raw samples for batch ASR
                if let data = convertedBuffer.floatChannelData?[0] {
                    let frames = Int(convertedBuffer.frameLength)
                    let samplesArray = Array(UnsafeBufferPointer(start: data, count: frames))
                    self.sampleLock.withLock {
                        let remaining = Self.maxRawSamples - self.rawSamples.count
                        if remaining > 0 {
                            self.rawSamples.append(contentsOf: samplesArray.prefix(remaining))
                        }
                    }

                    // Yield the frequency spectrum for the visualizer.
                    let spectrum = self.spectrumAnalyzer.process(samplesArray)
                    self.spectrumContinuation?.yield(spectrum)
                }
            }

            do {
                freshEngine.prepare()
                try freshEngine.start()
                AppLogger.log("[AudioRecorder] Engine prepared and started successfully")
            } catch {
                AppLogger.log("[AudioRecorder] Engine start FAILED: \(error)")
                let nsError = error as NSError
                if nsError.domain == "com.apple.coreaudio.avfaudio" {
                    AppLogger.log("[AudioRecorder] CoreAudio error detected, device may have been disconnected")
                    onRecordingFrozen?()
                }
                continuation.finish()
            }
        }

        return RecordingOutput(spectrum: spectrumStream)
    }

    nonisolated func stopRecording() {
        let tapCount = heartbeatLock.withLock { $0.tapCallCount }
        AppLogger.log("[AudioRecorder] stopRecording called, tapCallCount=\(tapCount)")

        let wasRecording = stateLock.withLock {
            let was = _isRecording || _isStopping
            _isStopping = true
            _isRecording = false
            return was
        }
        if !wasRecording {
            AppLogger.log("[AudioRecorder] stopRecording: already stopped")
            return
        }

        if heartbeatLock.withLock({ $0.tapCallCount }) == 0 {
            AppLogger.log("[AudioRecorder] CRITICAL: No tap callbacks received.")
        }

        heartbeatTimer.cancel()
        heartbeatLock.withLock { $0.lastTapTimestamp = nil }
        spectrumContinuation?.finish()
        spectrumContinuation = nil

        // Stop engine
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil

        // Restore original default input device if we changed it
        if originalDeviceID != kAudioObjectUnknown {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
            var mutableOriginalID = originalDeviceID
            let restoreResult = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                deviceIDSize,
                &mutableOriginalID
            )
            if restoreResult != noErr {
                AppLogger.log("[AudioRecorder] Failed to restore original input device: \(restoreResult)")
            } else {
                AppLogger.log("[AudioRecorder] Restored original input device")
            }
            originalDeviceID = kAudioObjectUnknown
        }

        stateLock.withLock {
            _isStopping = false
        }
    }

    /// Take accumulated raw Float32 samples and clear the buffer.
    nonisolated func takeAccumulatedSamples() -> [Float] {
        sampleLock.withLock {
            let samples = rawSamples
            rawSamples.removeAll(keepingCapacity: false)
            return samples
        }
    }

    static func availableInputDevices() -> [AudioDevice] {
        AudioDeviceEnumerator.availableInputDevices()
    }
}
