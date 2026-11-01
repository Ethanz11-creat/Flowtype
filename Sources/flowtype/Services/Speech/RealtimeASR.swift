import Foundation

/// Immutable, locally validated snapshot; no configuration store or key migration.
struct RealtimeASRConfiguration: Sendable, Equatable {
    static let sampleRate = 16_000
    let providerID: UUID
    let endpoint: URL
    let model: String
    let apiKey: String
    let language: String?

    init(provider: CloudASRProviderConfig, apiKey: String, language: String?) throws {
        guard provider.protocolKind == .dashScopeRealtime else {
            throw RealtimeASRConfigurationError.unsupportedProtocol
        }
        guard isValidRealtimeEndpoint(provider.baseURL), let endpoint = URL(string: provider.baseURL) else {
            throw RealtimeASRConfigurationError.invalidEndpoint
        }
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RealtimeASRConfigurationError.missingModel
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RealtimeASRConfigurationError.missingAPIKey
        }
        self.providerID = provider.id
        self.endpoint = endpoint
        self.model = provider.model
        self.apiKey = apiKey
        self.language = language
    }
}

/// Match settings' strict endpoint contract without trimming saved realtime URLs.
func isValidRealtimeEndpoint(_ value: String) -> Bool {
    guard !value.contains(where: { $0.isWhitespace }) else { return false }
    return (try? CloudASREndpoint.validateRealtimeURL(value)) != nil
}

enum RealtimeASRConfigurationError: Error, Equatable, LocalizedError {
    case unsupportedProtocol, invalidEndpoint, missingModel, missingAPIKey
    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol: return "请选择 DashScope 实时 WSS 协议"
        case .invalidEndpoint: return "实时 ASR 地址必须为有效 WSS 地址，使用有效端口，且不能包含空白、账号、密码、查询参数、片段或占位符"
        case .missingModel: return "请配置实时 ASR 模型，例如 paraformer-realtime-v2"
        case .missingAPIKey: return "请配置云端 ASR API Key"
        }
    }
}

/// Raw signed PCM16 little-endian, without a WAV header. Negative full scale
/// uses -32768, positive full scale uses 32767; nonfinite input is silence.
func encodePCM16LE(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let finite = sample.isFinite ? max(-1, min(1, sample)) : 0
        let scaled = finite < 0 ? finite * 32768 : finite * 32767
        let value = UInt16(bitPattern: Int16(scaled.rounded()))
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    return data
}

/// Documented DashScope task protocol, not the Qwen realtime protocol.
struct ParaformerClientMessage: Encodable, Sendable {
    struct Header: Encodable, Sendable {
        let action: String
        let taskID: String
        let streaming = "duplex"
        enum CodingKeys: String, CodingKey { case action, taskID = "task_id", streaming }
    }
    struct Parameters: Encodable, Sendable {
        let format = "pcm"
        let sampleRate = RealtimeASRConfiguration.sampleRate
        let languageHints: [String]?
        enum CodingKeys: String, CodingKey {
            case format, sampleRate = "sample_rate", languageHints = "language_hints"
        }
    }
    struct EmptyInput: Encodable, Sendable {}
    struct Payload: Encodable, Sendable {
        let taskGroup: String?
        let task: String?
        let function: String?
        let model: String?
        let parameters: Parameters?
        let input = EmptyInput()
        enum CodingKeys: String, CodingKey {
            case taskGroup = "task_group", task, function, model, parameters, input
        }
    }
    let header: Header
    let payload: Payload

    static func runTask(taskID: String, configuration: RealtimeASRConfiguration) -> Self {
        Self(header: Header(action: "run-task", taskID: taskID),
             payload: Payload(taskGroup: "audio", task: "asr", function: "recognition",
                              model: configuration.model,
                              parameters: Parameters(languageHints: configuration.language.map { [$0] })))
    }

    static func finishTask(taskID: String) -> Self {
        Self(header: Header(action: "finish-task", taskID: taskID),
             payload: Payload(taskGroup: nil, task: nil, function: nil, model: nil, parameters: nil))
    }

    func encodedText() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

/// Ignore unknown fields, including word-level detail and usage. No sentence_id
/// exists in the documented Paraformer schema; end_time is nullable even on finals.
struct ParaformerServerEvent: Decodable, Sendable {
    struct Header: Decodable, Sendable {
        let taskID: String
        let event: String
        let errorCode: String?
        let errorMessage: String?
        enum CodingKeys: String, CodingKey {
            case taskID = "task_id", event, errorCode = "error_code", errorMessage = "error_message"
        }
    }
    struct Sentence: Decodable, Sendable {
        let beginTime: Int
        let endTime: Int?
        let text: String
        let heartbeat: Bool
        let sentenceEnd: Bool
        enum CodingKeys: String, CodingKey {
            case beginTime = "begin_time", endTime = "end_time", text, heartbeat, sentenceEnd = "sentence_end"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heartbeat = try c.decode(Bool.self, forKey: .heartbeat)
            endTime = try c.decodeIfPresent(Int.self, forKey: .endTime)
            if heartbeat {
                // Heartbeats carry no recognition; null/missing details are harmless.
                beginTime = try c.decodeIfPresent(Int.self, forKey: .beginTime) ?? 0
                text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
                sentenceEnd = try c.decodeIfPresent(Bool.self, forKey: .sentenceEnd) ?? false
            } else {
                beginTime = try c.decode(Int.self, forKey: .beginTime)
                text = try c.decode(String.self, forKey: .text)
                sentenceEnd = try c.decode(Bool.self, forKey: .sentenceEnd)
            }
        }
    }
    struct Output: Decodable, Sendable { let sentence: Sentence? }
    struct Payload: Decodable, Sendable { let output: Output? }
    let header: Header
    let payload: Payload
}

/// begin_time is the application replacement key. Only sentence_end commits;
/// task-finished never promotes an uncommitted hypothesis.
struct ParaformerSentenceAssembler: Sendable {
    let taskID: String
    private var finalized: [Int: String] = [:]
    private var partial: ParaformerServerEvent.Sentence?

    init(taskID: String) { self.taskID = taskID }

    var finalizedText: String {
        finalized.keys.sorted().compactMap { finalized[$0] }.joined()
    }

    var text: String {
        var sentences = finalized
        if let partial, sentences[partial.beginTime] == nil { sentences[partial.beginTime] = partial.text }
        return sentences.keys.sorted().compactMap { sentences[$0] }.joined()
    }

    mutating func consume(_ event: ParaformerServerEvent) {
        guard event.header.taskID == taskID, event.header.event == "result-generated",
              let sentence = event.payload.output?.sentence, !sentence.heartbeat else { return }
        if sentence.sentenceEnd {
            finalized[sentence.beginTime] = sentence.text
            if partial?.beginTime == sentence.beginTime { partial = nil }
        } else if finalized[sentence.beginTime] == nil {
            partial = sentence
        }
    }
}

enum RealtimeAudioIngressError: Error, Equatable {
    case overflow, closed, cancelled
}

/// Capture callbacks enqueue synchronously without creating a Task. One sender
/// consumes wakeups, drains nextChunk, then acknowledges only after its send
/// completes. Capacity includes queued AND in-flight audio. Wakeups are hints:
/// after every wakeup (and stream completion), inspect nextChunk/isDrained.
final class RealtimeAudioIngress: @unchecked Sendable {
    struct Chunk: Sendable {
        let id: UUID
        let samples: [Float]
    }

    let maxPendingSamples: Int
    let wakeups: AsyncStream<Void>
    /// Independent terminal signal; observing it never steals pump wakeups.
    let failures: AsyncStream<RealtimeAudioIngressError>
    private let failureContinuation: AsyncStream<RealtimeAudioIngressError>.Continuation
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var queue: [Chunk] = []
    private var inFlight: Chunk?
    private var pendingSamples = 0
    private var sealed = false
    private var failure: RealtimeAudioIngressError?

    init(maxPendingSamples: Int = RealtimeASRConfiguration.sampleRate * 5) {
        precondition(maxPendingSamples > 0)
        self.maxPendingSamples = maxPendingSamples
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = stream.stream
        continuation = stream.continuation
        let failures = AsyncStream<RealtimeAudioIngressError>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.failures = failures.stream
        failureContinuation = failures.continuation
    }

    deinit { continuation.finish(); failureContinuation.finish() }

    var pendingSampleCount: Int { lock.withLock { pendingSamples } }
    var isDrained: Bool { lock.withLock { sealed && pendingSamples == 0 && failure == nil } }

    func enqueue(samples: [Float]) throws {
        try lock.withLock {
            if let failure { throw failure }
            guard !sealed else { throw RealtimeAudioIngressError.closed }
            guard !samples.isEmpty else { return }
            guard samples.count <= maxPendingSamples - pendingSamples else {
                failure = .overflow
                failureContinuation.yield(.overflow)
                failureContinuation.finish()
                queue.removeAll()
                inFlight = nil
                pendingSamples = 0
                continuation.yield(())
                continuation.finish()
                throw RealtimeAudioIngressError.overflow
            }
            queue.append(Chunk(id: UUID(), samples: samples))
            pendingSamples += samples.count
            continuation.yield(())
        }
    }

    func nextChunk() throws -> Chunk? {
        try lock.withLock {
            if let failure { throw failure }
            guard inFlight == nil, !queue.isEmpty else { return nil }
            let chunk = queue.removeFirst()
            inFlight = chunk
            return chunk
        }
    }

    func acknowledge(chunkID: UUID) {
        lock.withLock {
            guard let chunk = inFlight, chunk.id == chunkID else { return }
            pendingSamples -= chunk.samples.count
            inFlight = nil
            continuation.yield(())
            if sealed && pendingSamples == 0 { continuation.finish() }
        }
    }

    func seal() {
        lock.withLock {
            sealed = true
            continuation.yield(())
            if pendingSamples == 0 { continuation.finish() }
        }
    }

    func cancel() {
        lock.withLock {
            if failure == nil {
                failure = .cancelled
                failureContinuation.yield(.cancelled)
                failureContinuation.finish()
            }
            sealed = true
            queue.removeAll()
            inFlight = nil
            pendingSamples = 0
            continuation.yield(())
            continuation.finish()
        }
    }
}
