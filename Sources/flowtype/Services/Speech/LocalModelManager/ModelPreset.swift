import Foundation

struct ModelPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let repoId: String
    let expectedSizeBytes: Int64
    let recommendedTiers: Set<HardwareTier>
    let isDefaultForTier: Bool
    let minMemoryBytes: Int64
    let modelDescription: String

    static let modelsDirectory: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Flowtype/models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func localDirectory() -> URL {
        // Hub-style layout: <modelsDir>/<org>/<model>, e.g.
        //   .../Flowtype/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit
        // speech-swift's HubApi.snapshot() materializes downloads at
        //   <downloadBase>/models/<org>/<model>
        // so passing this directory as `cacheDir` makes weights land exactly here.
        // A flat `<org>_<model>` folder would fail the downloader's suffix-based
        // download-base derivation and write the weights to the wrong location.
        var dir = Self.modelsDirectory
        for component in repoId.split(separator: "/") {
            dir = dir.appendingPathComponent(String(component), isDirectory: true)
        }
        return dir
    }

    static let qwen306B = ModelPreset(
        id: "qwen3-0.6b-4bit",
        name: "Qwen3-ASR 0.6B (4-bit)",
        repoId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
        expectedSizeBytes: 675 * 1024 * 1024,
        recommendedTiers: [.low, .mid, .high],
        isDefaultForTier: true,
        minMemoryBytes: 4 * 1024 * 1024 * 1024,
        modelDescription: "轻量模型，体积小、速度快，适合内存 <12GB 的设备"
    )

    static let qwen317B = ModelPreset(
        id: "qwen3-1.7b-4bit",
        name: "Qwen3-ASR 1.7B (4-bit)",
        repoId: "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
        expectedSizeBytes: 1800 * 1024 * 1024,
        recommendedTiers: [.mid, .high],
        isDefaultForTier: false,
        minMemoryBytes: 8 * 1024 * 1024 * 1024,
        modelDescription: "精度更高，识别效果更好，推荐内存 ≥12GB 的设备使用"
    )

    static let allPresets: [ModelPreset] = [.qwen306B, .qwen317B]

    static func recommendedModel(for tier: HardwareTier) -> ModelPreset {
        switch tier {
        case .low:
            return .qwen306B
        case .mid, .high:
            return .qwen317B
        }
    }

    static func preset(forID id: String?) -> ModelPreset? {
        guard let id else { return nil }
        return allPresets.first { $0.id == id }
    }

    static func hardwareTierDescription(_ tier: HardwareTier) -> String {
        let memoryGB = currentMemoryGB()
        switch tier {
        case .low:
            return "当前设备内存 \(String(format: "%.0f", memoryGB))GB（低端配置，推荐 0.6B 模型）"
        case .mid:
            return "当前设备内存 \(String(format: "%.0f", memoryGB))GB（中端配置，推荐 1.7B 模型）"
        case .high:
            return "当前设备内存 \(String(format: "%.0f", memoryGB))GB（高端配置，推荐 1.7B 模型）"
        }
    }

    private static func currentMemoryGB() -> Double {
        let bytes = HardwareProfiler.currentMemoryBytes()
        return Double(bytes) / (1024 * 1024 * 1024)
    }
}
