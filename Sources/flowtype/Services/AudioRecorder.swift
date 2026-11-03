@preconcurrency import AVFoundation
import os

enum AudioRecorderError: Error, Equatable {
    case permissionDenied
    case engineStartFailed
    case formatCreationFailed
}

/// A single ordered visualization source; spectrum access remains source compatible.
struct RecordingOutput: Sendable {
    let visualizationFrames: RecordingVisualizationSequence

    init(spectrum: AsyncStream<[Float]>) {
        visualizationFrames = .init(frames: nil, legacySpectrum: spectrum)
    }

    init(visualizationFrames: AsyncStream<AudioVisualizationFrame>) {
        self.visualizationFrames = .init(frames: visualizationFrames, legacySpectrum: nil)
    }

    static func makeVisualizationStream() -> (stream: AsyncStream<AudioVisualizationFrame>, continuation: AsyncStream<AudioVisualizationFrame>.Continuation) {
        AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var spectrum: AsyncMapSequence<RecordingVisualizationSequence, [Float]> {
        visualizationFrames.map { $0.spectrum }
    }
}

final class AudioRecorder: @unchecked Sendable {
    // Security: hard cap at 30 minutes of 16kHz Float32 audio (~110 MB)
    private static let maxRawSamples = 28_800_000 // 16000 Hz * 60 s/min * 30 min

    private var engine: AVAudioEngine?
    private nonisolated(unsafe) var visualizationContinuation: AsyncStream<AudioVisualizationFrame>.Continuation?

    // Raw sample accumulator for batch ASR (Qwen3-ASR)
    private var rawSamples: [Float] = []
    private let sampleLock = OSAllocatedUnfairLock()

    // Recording state
    private let stateLock = OSAllocatedUnfairLock()
    private var _isRecording = false
    private var _isStopping = false

    /// Session owner for the current engine. A cancelled stage may still unwind
    /// after a new session starts; owner checks keep that cleanup from stopping
    /// or clearing the new session's capture.
    private let ownerLock = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private let lifecycleLock = OSAllocatedUnfairLock()

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
    }
    private let heartbeatLock = OSAllocatedUnfairLock<HeartbeatState>(uncheckedState: HeartbeatState())

    /// Callback to forward real-time audio buffers to a streaming recognizer.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Ordered 16kHz mono Float32 callback captured before engine start.
    var onPCMSamples: (@Sendable ([Float]) -> Void)?

    /// Called when no audio tap callbacks have been received for a while.
    var onRecordingFrozen: (() -> Void)?

    // MARK: - Heartbeat detection
    private let heartbeat = RecordingHeartbeat()

    func authorizationStatus() -> Int {
        AVAudioApplication.shared.recordPermission.rawValue
    }

    func requestPermission() async -> Bool {
        guard ValidationEffects.live.allow(.permissionRequest) else { return false }
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

    nonisolated func startRecording(deviceID: String? = nil, ownerID: UInt64 = 0) async throws -> RecordingOutput {
        ownerLock.withLock { $0 = ownerID }
        guard await requestPermission() else {
            releaseOwner(ownerID)
            throw AudioRecorderError.permissionDenied
        }
        return try lifecycleLock.withLock {
            try startEngine(deviceID: deviceID, ownerID: ownerID)
        }
    }

    private func startEngine(deviceID: String?, ownerID: UInt64) throws -> RecordingOutput {
        guard ValidationEffects.live.allow(.audioDevice) else { throw AudioRecorderError.permissionDenied }
        try Task.checkCancellation()
        guard isOwner(ownerID) else { throw CancellationError() }

        // A tap owns its analyzer and continuation. Late old-session work cannot
        // contaminate a new session, even while the old callback finishes unwinding.
        let spectrumAnalyzer = SpectrumAnalyzer(bandCount: 10)

        let freshEngine = AVAudioEngine()
        guard isOwner(ownerID) else { throw CancellationError() }
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
                // Crash safety: persist the original device's UID BEFORE changing the
                // system default, so a crash/kill mid-recording can be repaired at next
                // launch via restorePendingDeviceIfNeeded(). Store the UID, not the
                // AudioObjectID — numeric IDs are not stable across launches.
                if originalDeviceID != kAudioObjectUnknown {
                    if let originalUID = AudioDeviceEnumerator.deviceUID(for: originalDeviceID) {
                        RuntimeEnvironment.defaults.set(originalUID, forKey: Self.pendingRestoreKey)
                        AppLogger.log("[AudioRecorder] Persisted device-restore sentinel (uid=\(originalUID))")
                    } else {
                        AppLogger.log("[AudioRecorder] Could not resolve original device UID; crash-restore sentinel not written")
                    }
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
                    // The system default was never changed — no restore owed.
                    RuntimeEnvironment.defaults.removeObject(forKey: Self.pendingRestoreKey)
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
            // We may have already switched the system default device above; this throw
            // skips stopRecording, so restore here or the switch leaks.
            restoreOriginalDeviceIfNeeded()
            releaseOwner(ownerID)
            throw AudioRecorderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            restoreOriginalDeviceIfNeeded()
            releaseOwner(ownerID)
            throw AudioRecorderError.formatCreationFailed
        }

        guard isOwner(ownerID) else {
            restoreOriginalDeviceIfNeeded()
            throw CancellationError()
        }

        stateLock.withLock {
            _isRecording = true
            _isStopping = false
        }
        heartbeatLock.withLock { state in
            state.tapCallCount = 0
        }
        sampleLock.withLock {
            rawSamples.removeAll(keepingCapacity: true)
        }
        let pcmSink = onPCMSamples
        let (visualizationStream, continuation) = RecordingOutput.makeVisualizationStream()
        guard self.isOwner(ownerID) else {
            continuation.finish()
            throw CancellationError()
        }
        self.visualizationContinuation = continuation
        heartbeat.start(ownerID: ownerID, isActive: { [weak self] in
            guard let self else { return false }
            return self.isOwner(ownerID) && self.isRecording && !self.isStopping
        }, onFrozen: { [weak self] in
            guard let self, self.isOwner(ownerID) else { return }
            AppLogger.log("[AudioRecorder] HEARTBEAT FAILURE: Audio callbacks stopped. Auto-stopping.")
            self.onRecordingFrozen?()
        }, finish: { continuation.finish() })


        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            guard self.isOwner(ownerID) else { return }
            guard self.isRecording || self.isStopping else { return }

            self.heartbeatLock.withLock { $0.tapCallCount += 1 }
            self.heartbeat.recordTap(ownerID: ownerID)

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
            guard self.isOwner(ownerID) else { return }
            guard error == nil,
                  Self.isValidPCM(frameCount: Int(convertedBuffer.frameLength),
                                  hasFloatChannel: convertedBuffer.floatChannelData != nil) else { return }
            self.onAudioBuffer?(convertedBuffer)

            // Accumulate raw samples for batch ASR
            if let data = convertedBuffer.floatChannelData?[0] {
                let frames = Int(convertedBuffer.frameLength)
                let samplesArray = Array(UnsafeBufferPointer(start: data, count: frames))
                self.sampleLock.withLock {
                    guard self.isRecording || self.isStopping else { return }
                    let remaining = Self.maxRawSamples - self.rawSamples.count
                    if remaining > 0 {
                        let accepted = Array(samplesArray.prefix(remaining))
                        self.rawSamples.append(contentsOf: accepted)
                        pcmSink?(accepted)
                    }
                }

                // PCM loudness and frequency detail travel in one bounded ordered frame.
                let spectrum = spectrumAnalyzer.process(samplesArray)
                if self.isOwner(ownerID) {
                    continuation.yield(AudioVisualizationFrame(samples: samplesArray, spectrum: spectrum))
                }
            }
        }

        RecordingEngineStartup.run(prepare: { freshEngine.prepare() }, start: {
            try freshEngine.start()
            AppLogger.log("[AudioRecorder] Engine prepared and started successfully")
        }, onFailure: {
            AppLogger.log("[AudioRecorder] Engine start failed")
            onRecordingFrozen?()
        }, finish: { continuation.finish() })
        return RecordingOutput(visualizationFrames: visualizationStream)
    }

    nonisolated func stopRecording() {
        guard let ownerID = ownerLock.withLock({ $0 }) else { return }
        stopRecording(ownerID: ownerID)
    }

    nonisolated func stopRecording(ownerID: UInt64) {
        lifecycleLock.withLock { stopEngine(ownerID: ownerID) }
    }

    private func stopEngine(ownerID: UInt64) {
        guard isOwner(ownerID) else {
            AppLogger.log("[AudioRecorder] Ignoring stop from stale owner \(ownerID)")
            return
        }
        let tapCount = heartbeatLock.withLock { $0.tapCallCount }
        AppLogger.log("[AudioRecorder] stopRecording(owner=\(ownerID)) called, tapCallCount=\(tapCount)")

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

        heartbeat.cancel(ownerID: ownerID)
        visualizationContinuation?.finish()
        visualizationContinuation = nil

        // Stop engine
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        onAudioBuffer = nil
        onPCMSamples = nil
        onRecordingFrozen = nil

        // Restore original default input device if we changed it
        restoreOriginalDeviceIfNeeded()

        sampleLock.withLock {
            stateLock.withLock { _isStopping = false }
        }
    }

    nonisolated private func isOwner(_ ownerID: UInt64) -> Bool {
        ownerLock.withLock { Self.shouldAcceptOwner(activeOwnerID: $0, eventOwnerID: ownerID) }
    }

    nonisolated func owns(_ ownerID: UInt64) -> Bool {
        isOwner(ownerID)
    }

    nonisolated func clearCallbacks(ownerID: UInt64) {
        guard isOwner(ownerID) else { return }
        onAudioBuffer = nil
        onPCMSamples = nil
        onRecordingFrozen = nil
    }

    nonisolated private func releaseOwner(_ ownerID: UInt64) {
        ownerLock.withLock {
            if $0 == ownerID { $0 = nil }
        }
    }

    nonisolated static func shouldAcceptOwner(activeOwnerID: UInt64?, eventOwnerID: UInt64) -> Bool {
        activeOwnerID == eventOwnerID
    }

    nonisolated static func isValidPCM(frameCount: Int, hasFloatChannel: Bool) -> Bool {
        frameCount > 0 && hasFloatChannel
    }

    // MARK: - Default input device restore (crash safety)

    /// UserDefaults key holding the UID of the original system default input device
    /// while it is temporarily overridden. Key present on disk ⇒ a restore is owed.
    private static let pendingRestoreKey = "flowtype.pendingInputDeviceRestoreUID"

    /// Restores the system default input device if startRecording changed it.
    /// Covers in-process paths: normal stop, cancel, freeze auto-stop, and the
    /// formatCreationFailed throws in startRecording. Clears the persisted sentinel
    /// on success; keeps it on failure so the next launch retries.
    private nonisolated func restoreOriginalDeviceIfNeeded() {
        guard originalDeviceID != kAudioObjectUnknown else { return }
        let restoreResult = Self.setSystemDefaultInputDevice(originalDeviceID)
        if restoreResult != noErr {
            AppLogger.log("[AudioRecorder] Failed to restore original input device: \(restoreResult)")
        } else {
            AppLogger.log("[AudioRecorder] Restored original input device")
            RuntimeEnvironment.defaults.removeObject(forKey: Self.pendingRestoreKey)
        }
        originalDeviceID = kAudioObjectUnknown
    }

    /// Crash/quit recovery: if a previous session (or the current one, on Cmd+Q while
    /// recording) left the system default input device overridden, restore it from the
    /// persisted UID sentinel. Clears the sentinel whether or not the restore succeeds —
    /// the original device may have been unplugged, and a stale sentinel must not
    /// clobber a default the user has since chosen by hand.
    static func restorePendingDeviceIfNeeded() {
        guard RuntimeEnvironment.current.role == .app else { return }
        guard let uid = RuntimeEnvironment.defaults.string(forKey: pendingRestoreKey) else { return }
        defer { RuntimeEnvironment.defaults.removeObject(forKey: pendingRestoreKey) }
        AppLogger.log("[AudioRecorder] Pending input-device restore found (uid=\(uid))")
        guard let deviceID = AudioDeviceEnumerator.findDeviceID(uid: uid) else {
            AppLogger.log("[AudioRecorder] Pending restore: device not found (unplugged?); clearing sentinel")
            return
        }
        let result = setSystemDefaultInputDevice(deviceID)
        if result == noErr {
            AppLogger.log("[AudioRecorder] Pending restore: system default input device restored")
        } else {
            AppLogger.log("[AudioRecorder] Pending restore failed: \(result); clearing sentinel")
        }
    }

    /// Sets the system-wide default input device. Returns the CoreAudio status.
    private static func setSystemDefaultInputDevice(_ deviceID: AudioObjectID) -> OSStatus {
        guard ValidationEffects.live.allow(.audioDevice) else { return -1 }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableDeviceID
        )
    }

    /// Take accumulated raw Float32 samples and clear the buffer.
    nonisolated func takeAccumulatedSamples(ownerID: UInt64? = nil) -> [Float] {
        if let ownerID, !isOwner(ownerID) {
            return []
        }
        return sampleLock.withLock {
            let samples = rawSamples
            rawSamples.removeAll(keepingCapacity: false)
            return samples
        }
    }

    static func availableInputDevices() -> [AudioDevice] {
        AudioDeviceEnumerator.availableInputDevices()
    }
}
