import Foundation
import Darwin
import Qwen3ASR
import AudioCommon
import MLX

private struct Request: Decodable { let request_id: String; let id: String; let path: String }
private let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    try protocolOutput.write(contentsOf: data + Data([10]))
}
@main
struct NativeASRBench {
    static func main() async throws {
        _ = protocolOutput
        dup2(STDERR_FILENO, STDOUT_FILENO) // dependency diagnostics cannot enter JSONL protocol
        let args = CommandLine.arguments
        guard args.count == 3, ["qwen-1.7b", "qwen-0.6b"].contains(args[2]) else {
            throw NSError(domain: "Expected model directory and model id", code: 1)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let repo = args[2] == "qwen-1.7b" ? "aufklarer/Qwen3-ASR-1.7B-MLX-4bit" : "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        let model = try await Qwen3ASRModel.fromPretrained(modelId: repo, cacheDir: URL(fileURLWithPath: args[1]), offlineMode: true)
        guard model.textDecoder != nil else { throw NSError(domain: "Missing text decoder", code: 2) }
        let options = Qwen3DecodingOptions(maxTokens: 448, language: nil, context: nil, repetitionPenalty: 1.1, noRepeatNgramSize: 3, temperature: 0)
        try emit(["event":"ready", "model_id":args[2], "load_seconds":ProcessInfo.processInfo.systemUptime - start])
        while let line = readLine() {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            let begin = ProcessInfo.processInfo.systemUptime
            let result: [String: Any] = autoreleasepool {
                var result: [String: Any] = ["id":request.id, "request_id":request.request_id, "model_id":args[2]]
                do {
                    let (audio, rate) = try AudioFileLoader.loadWAV(url: URL(fileURLWithPath: request.path))
                    guard rate == 16000, !audio.isEmpty, audio.allSatisfy(\.isFinite) else { throw NSError(domain: "invalid_audio", code: 3) }
                    result["text"] = model.transcribe(audio: audio, sampleRate: rate, options: options)
                    result["status"] = "ok"; result["error_code"] = NSNull()
                    result["audio_seconds"] = Double(audio.count) / Double(rate)
                } catch {
                    result["text"] = ""; result["status"] = "error"; result["error_code"] = "native_inference_error"
                }
                result["latency_seconds"] = ProcessInfo.processInfo.systemUptime - begin
                return result
            }
            try emit(result)
            Memory.clearCache()
        }
    }
}
