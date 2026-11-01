import Foundation

protocol OfflineWhisperBackend: Sendable {
    var verifiedMetadata: WhisperRuntimeMetadata? { get }
    func transcribe(samples: [Float], language: String?, prompt: String?) async throws -> [String]
}

extension OfflineWhisperBackend {
    var verifiedMetadata: WhisperRuntimeMetadata? { nil }
}

struct WhisperOfflineLoadOptions: Sendable, Equatable {
    let modelDirectory: URL
    let tokenizerDirectory: URL
    let download = false
    let load = false
}

/// A task chain is the exclusive permit, not actor isolation alone. Cancellation releases
/// the caller's continuation, never the permit. Uncancellable old compute must finish
/// before the next operation begins. Cancelled queued operations do not touch the backend.
private actor WhisperInferenceQueue {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async throws -> [String]) async throws -> [String] {
        let box = CancellableContinuationBox<[String]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.setContinuation(continuation)
                let previous = tail
                tail = Task {
                    await previous?.value
                    guard !box.isCancelled else { return }
                    do { box.resume(returning: try await operation()) }
                    catch { box.resume(throwing: error) }
                }
            }
        } onCancel: { box.cancel() }
    }
}

final class WhisperASRProvider: ASRProvider, @unchecked Sendable {
    let id = ASRProviderID.local
    let identity: LocalModelIdentity
    var displayName: String { identity.displayName }
    let verifiedMetadata: WhisperRuntimeMetadata?
    let capabilities: ASRCapabilities
    private let backend: any OfflineWhisperBackend
    private let inference = WhisperInferenceQueue()
    var isAvailable: Bool { get async { true } }

    init(identity: LocalModelIdentity, backend: any OfflineWhisperBackend) {
        self.identity = identity
        self.backend = backend
        verifiedMetadata = backend.verifiedMetadata
        capabilities = ASRCapabilities(supportsLanguageHint: backend.verifiedMetadata?.isMultilingual ?? true,
                                       supportsContextHint: true, requiresNetwork: false, location: .onDevice)
    }

    static func load(model: ImportedASRModel,
                     backendFactory: @Sendable (WhisperOfflineLoadOptions) async throws -> any OfflineWhisperBackend = { try await WhisperKitBackend.load($0) }) async throws -> WhisperASRProvider {
        guard model.engine == .whisperCoreML, let tokenizerDirectory = model.tokenizerDirectory,
              model.directory.isFileURL, tokenizerDirectory.isFileURL else {
            throw OfflineWhisperError.invalidLocalDirectory
        }
        try Task.checkCancellation()
        let backend = try await backendFactory(WhisperOfflineLoadOptions(modelDirectory: model.directory, tokenizerDirectory: tokenizerDirectory))
        try Task.checkCancellation()
        let variant = backend.verifiedMetadata?.variant ?? model.variant
        return WhisperASRProvider(identity: LocalModelIdentity(id: model.id.uuidString,
            displayName: "\(model.name) · Whisper \(variant)", engine: model.engine.rawValue,
            repoID: nil, directory: model.directory), backend: backend)
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        guard request.sampleRate == 16_000 else { throw OfflineWhisperError.invalidSampleRate }
        try Task.checkCancellation()
        let start = Date()
        let backend = backend
        let segments = try await inference.run {
            try await backend.transcribe(samples: request.samples, language: request.language,
                                         prompt: composeProviderContext(request.context))
        }
        try Task.checkCancellation()
        let text = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return ASRResult(text: text, providerID: id, latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}
