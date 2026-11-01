import Foundation
@preconcurrency import Qwen3ASR
import SpeechVAD
import AudioCommon
import os

/// Thread-safe box for resuming a CheckedContinuation exactly once,
/// supporting cancellation of an underlying synchronous operation.
/// Internal (not private): also used by AppleSpeechProvider and exercised by SelfTest.
final class CancellableContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Void>()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock {
            if cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                self.continuation = continuation
            }
        }
    }

    func resume(returning value: T) {
        lock.withLock {
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: value)
            }
        }
    }

    func resume(throwing error: Error) {
        lock.withLock {
            if let cont = continuation {
                continuation = nil
                cont.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let cont = continuation {
                continuation = nil
                cont.resume(throwing: CancellationError())
            }
        }
    }
}

final class QwenASRProvider: ASRProvider, @unchecked Sendable {
    let name: String = "QwenASR"
    let id = ASRProviderID.qwenLocal
    let displayName = "本地 ASR (Qwen)"
    nonisolated let capabilities = ASRCapabilities(
        supportsLanguageHint: true,
        supportsContextHint: true,
        requiresNetwork: false,
        location: .onDevice
    )

    var isAvailable: Bool { get async { isLoaded } }

    private nonisolated(unsafe) var model: Qwen3ASRModel?
    private nonisolated(unsafe) var loadedModelId: String?
    private let queue = DispatchQueue(label: "flowtype.qwen-asr")

    /// Serial queue for the actual MLX inference. Qwen3ASRModel is not Sendable and its
    /// transcribe call is synchronous and uncancellable — a cancelled session's inference
    /// keeps running, so a follow-up session must QUEUE behind it, never run concurrently
    /// against the same model instance. Separate from `queue`: isLoaded does a main-thread
    /// queue.sync and must not block behind a multi-second inference.
    private let inferenceQueue = DispatchQueue(label: "flowtype.qwen-asr.inference", qos: .userInitiated)

    var isLoaded: Bool {
        queue.sync { model != nil }
    }

    // MARK: - Model Lifecycle

    func loadModel(
        modelId: String,
        cacheDir: URL? = nil,
        offlineMode: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        AppLogger.log("[QwenASR] Loading model: \(modelId) offline=\(offlineMode) cacheDir=\(cacheDir?.path ?? "default")")
        let loaded = try await Self.withProvisionErrors {
            try await Qwen3ASRModel.fromPretrained(
                modelId: modelId,
                cacheDir: cacheDir,
                offlineMode: offlineMode,
                progressHandler: progressHandler
            )
        }
        try Task.checkCancellation()
        queue.sync {
            model = loaded
            loadedModelId = modelId
        }
        AppLogger.log("[QwenASR] Model loaded successfully")
    }

    /// The provider boundary discards unsafe dependency strings before publishing recovery errors.
    static func withProvisionErrors<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw classifyProvisionError(error)
        }
    }

    private static func classifyProvisionError(_ error: any Error, depth: Int = 0) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let failure = error as? ModelProvisionError { return failure }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet:
                return ModelProvisionError.network()
            default: return ModelProvisionError.loadFailed()
            }
        }
        // speech-swift flattens arbitrary snapshot errors into this string-only wrapper.
        // Do not parse its text or multiply its existing three snapshot attempts.
        if error is DownloadError { return ModelProvisionError.loadFailed() }
        if depth < 4, let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error {
            return classifyProvisionError(underlying, depth: depth + 1)
        }
        return ModelProvisionError.loadFailed()
    }

    func unloadModel() {
        queue.sync {
            model = nil
            loadedModelId = nil
        }
        AppLogger.log("[QwenASR] Model unloaded")
    }

    func loadPreset(_ preset: ModelPreset, progressHandler: ((Double, String) -> Void)? = nil) async throws {
        let alreadyLoaded = queue.sync { loadedModelId == preset.repoId && model != nil }
        if alreadyLoaded { return }
        let dir = preset.localDirectory()
        let offline = ModelLocator.validateComplete(dir, minBytes: ModelLocator.minValidBytes(for: preset))
        try await loadModel(
            modelId: preset.repoId,
            cacheDir: dir,
            offlineMode: offline,
            progressHandler: progressHandler
        )
    }

    // MARK: - Transcription

    func transcribe(
        samples: [Float],
        sampleRate: Int = 16000,
        language: String? = nil,
        context: String? = nil
    ) async throws -> String {
        let currentModel: Qwen3ASRModel? = queue.sync { model }
        guard let currentModel else {
            throw SpeechProviderError.notAvailable
        }

        let options = Qwen3DecodingOptions(
            language: language,
            context: context,
            repetitionPenalty: 1.1,
            noRepeatNgramSize: 3
        )

        let box = CancellableContinuationBox<String>()
        let text: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                box.setContinuation(continuation)
                inferenceQueue.async {
                    // Cancelled while queued behind an earlier inference → skip the GPU work.
                    guard !box.isCancelled else { return }
                    let result = currentModel.transcribe(
                        audio: samples,
                        sampleRate: sampleRate,
                        options: options
                    )
                    box.resume(returning: result)
                }
            }
        }, onCancel: {
            box.cancel()
        })

        AppLogger.log("[QwenASR] Transcribed \(samples.count / sampleRate)s audio → \(text.count) chars")
        return text
    }

    // MARK: - ASRProvider Conformance

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let start = Date()
        let text = try await transcribe(
            samples: request.samples,
            sampleRate: request.sampleRate,
            language: request.language,
            context: composeProviderContext(request.context)
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return ASRResult(text: text, providerID: id, latencyMs: ms)
    }
}
