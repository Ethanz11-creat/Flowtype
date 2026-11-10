import Foundation

enum LocalASRRuntimeFactory {
    /// Bump the adapter compatibility component whenever native loading/decoding changes.
    static func engineVersion(for engine: LocalASREngine) -> String {
        switch engine {
        case .qwenMLX: return "speech-swift/0.0.15;swift-transformers/1.1.9;FlowType-Qwen/1"
        case .whisperCoreML: return "WhisperKit/0.18.0;swift-transformers/1.1.9;FlowType-Whisper/1"
        }
    }

    @MainActor
    static func load(_ model: ImportedASRModel, registry: LocalASRRuntimeRegistry = .standard,
                     inspect: @escaping @Sendable (URL) throws -> ImportedASRModel = { try ASRModelInspector.inspect(directory: $0) },
                     beforeAllocation: @escaping @MainActor (ImportedASRModel) throws -> Void = { _ in }) async throws -> LocalASRLease {
        try Task.checkCancellation()
        // Every adapter goes through the same fresh inspection before runtime allocation.
        let current = try await LocalModelInspection.inspect(directory: model.directory, using: inspect)
        guard current.fileFingerprint == model.fileFingerprint, current.engine == model.engine,
              current.tokenizerDirectory == model.tokenizerDirectory,
              current.qwenCompatibilityModelID == model.qwenCompatibilityModelID else {
            throw ASRModelInspectionError(code: .changedDuringInspection, detail: "模型文件已改变，请重新检测。")
        }
        // Preserve the library identity while using freshly inspected resource metadata.
        var candidate = current; candidate.id = model.id; candidate.name = model.name
        let usage = try NativeModelUsageRegistry.shared.acquire(modelID: candidate.id)
        let lease = try await registry.load(candidate, beforeAllocation: beforeAllocation)
        return lease.retainingUsage(usage)
    }
}
