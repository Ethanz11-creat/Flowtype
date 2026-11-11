// Research runner: direct offline Qwen3ASR inference, no application or fallback.
import Foundation
import Qwen3ASR
import AudioCommon
import MLX

private struct Input: Decodable {
    let id: String
    let path: String
}

private struct Prediction: Encodable {
    let id: String
    let text: String
    let status: String
    let error: String?
    let latency_seconds: Double
    let audio_seconds: Double?
}

@main
struct NativeASRBaseline {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else {
            throw NSError(domain: "Usage: runner model-directory inputs.jsonl predictions.jsonl limit(0=all)", code: 1)
        }
        let inputs = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Input.self, from: Data($0.utf8))
        }
        guard Set(inputs.map(\.id)).count == inputs.count else {
            throw NSError(domain: "Duplicate input IDs", code: 2)
        }
        guard !FileManager.default.fileExists(atPath: args[3]), let limit = Int(args[4]), limit >= 0 else {
            throw NSError(domain: "Output must be new and limit nonnegative", code: 3)
        }
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
            cacheDir: URL(fileURLWithPath: args[1]), offlineMode: true
        )
        guard model.textDecoder != nil else {
            throw NSError(domain: "Missing text decoder", code: 4)
        }
        let options = Qwen3DecodingOptions(
            maxTokens: 448, language: nil, context: nil,
            repetitionPenalty: 1.1, noRepeatNgramSize: 3, temperature: 0
        )
        FileManager.default.createFile(atPath: args[3], contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (index, input) in inputs.prefix(limit == 0 ? inputs.count : limit).enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            let prediction: Prediction = autoreleasepool {
                do {
                    let (audio, rate) = try AudioFileLoader.loadWAV(url: URL(fileURLWithPath: input.path))
                    guard rate == 16000, !audio.isEmpty, audio.allSatisfy(\.isFinite) else {
                        throw NSError(domain: "Expected nonempty finite 16kHz audio", code: 5)
                    }
                    let text = model.transcribe(audio: audio, sampleRate: rate, options: options)
                    return Prediction(id: input.id, text: text, status: "ok", error: nil,
                        latency_seconds: ProcessInfo.processInfo.systemUptime - start,
                        audio_seconds: Double(audio.count) / Double(rate))
                } catch {
                    return Prediction(id: input.id, text: "", status: "error", error: String(describing: error),
                        latency_seconds: ProcessInfo.processInfo.systemUptime - start, audio_seconds: nil)
                }
            }
            try handle.write(contentsOf: encoder.encode(prediction) + Data([10]))
            try handle.synchronize()
            Memory.clearCache()
            FileHandle.standardError.write(Data("completed \(index + 1)/\(limit == 0 ? inputs.count : min(limit, inputs.count)) id=\(input.id) \(prediction.status) latency=\(prediction.latency_seconds)\n".utf8))
        }
    }
}
