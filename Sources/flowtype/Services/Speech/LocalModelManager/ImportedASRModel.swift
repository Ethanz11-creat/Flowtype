import Foundation

enum LocalASREngine: String, Codable, Sendable {
    case qwenMLX, whisperCoreML
}

/// A static inspection result, never evidence that a runtime is loaded or ready.
struct ImportedASRModel: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var directory: URL
    var engine: LocalASREngine
    var variant: String
    var bits: Int?
    var sizeBytes: Int64
    var tokenizerDirectory: URL?
    var fileFingerprint: String
    /// Validated packed U32 tensor payload only. Conservative admission reservation,
    /// not a measured OS residency requirement (paging/mmap may differ) or peak RAM.
    var minimumResidentBytes: UInt64? = nil

    /// Only for speech-swift's constructor selection; never a remote download target.
    var qwenCompatibilityModelID: String? {
        guard engine == .qwenMLX, ["0.6B", "1.7B"].contains(variant), let bits, [4, 8].contains(bits) else { return nil }
        return "local/Qwen3-ASR-\(variant)-MLX-\(bits)bit"
    }
}

struct ASRModelInspectionError: Error, LocalizedError, Equatable {
    enum Code: String, Sendable {
        case unreadable, metadataTooLarge, invalidMetadata, unsupportedFormat, incompleteModel
        case invalidTensor, invalidIndex, changedDuringInspection, chooseSubdirectory
    }
    let code: Code
    let detail: String
    var errorDescription: String? { detail }
}
