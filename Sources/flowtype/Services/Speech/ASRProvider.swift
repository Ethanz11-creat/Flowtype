import Foundation

/// 本地与云端 ASR provider 的统一接口。
///
/// 音频契约：`ASRRequest.samples` 是 **16kHz 单声道 Float32 裸样本**（非 WAV 容器）。
/// 需要容器的 provider（WAV / multipart）自行编码（见 `CloudASRProvider`）。
protocol ASRProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ASRCapabilities { get }
    var isAvailable: Bool { get async }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}
