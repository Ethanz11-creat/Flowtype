import Foundation

enum DashScopeRealtimeError: Error, Equatable {
    case startTimeout, finalTimeout, invalidEvent, transportClosed, notStarted
    case taskFailed(code: String?, message: String?)
}

/// A capture callback needs only ingress; async callers use session lifecycle.
struct RealtimeASRSessionHandle: Sendable {
    let session: any RealtimeASRSession
    let ingress: RealtimeAudioIngress
    let capabilities: ASRCapabilities
}

/// One task per socket. Lifecycle results are latched before registering waiters,
/// and all binary/finish sends belong to exactly one pump.
actor DashScopeRealtimeASR: RealtimeASRSession {
    static let capabilities = ASRCapabilities(supportsLanguageHint: true,
        supportsContextHint: false, requiresNetwork: true, location: .cloud)

    nonisolated let ingress: RealtimeAudioIngress
    private let configuration: RealtimeASRConfiguration
    private let transport: any WebSocketTransport
    private let taskID: String
    private let startTimeout: TimeInterval
    private let finalTimeout: TimeInterval
    private let started = RealtimeResultLatch<Void>()
    private let completed = RealtimeResultLatch<ASRResult>()
    private var assembler: ParaformerSentenceAssembler
    private var startInvoked = false
    private var startAcknowledged = false
    private var runTaskSent = false
    private var finishRequested = false
    private var finishSent = false
    private var terminal: Result<ASRResult, Error>?
    private var failureMonitor: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var audioWaiters: [CheckedContinuation<Void, Error>] = []
    private var startTime: ContinuousClock.Instant?

    init(configuration: RealtimeASRConfiguration,
         transport: any WebSocketTransport = URLSessionWebSocketTransport(),
         ingress: RealtimeAudioIngress = RealtimeAudioIngress(),
         taskID: String = UUID().uuidString,
         startTimeout: TimeInterval = 10, finalTimeout: TimeInterval = 10) {
        self.configuration = configuration
        self.transport = transport
        self.ingress = ingress
        self.taskID = taskID
        self.startTimeout = startTimeout
        self.finalTimeout = finalTimeout
        assembler = ParaformerSentenceAssembler(taskID: taskID)
    }

    func start() async throws {
        do {
            try checkFailure()
            try Task.checkCancellation()
            let first = !startInvoked
            startInvoked = true
            if first { startTime = .now }
            try await withAsyncDeadline(seconds: startTimeout) { [self] in
                if first { try await self.begin() }
                try await self.started.value()
            }
        } catch {
            let error = error is AsyncDeadlineError ? DashScopeRealtimeError.startTimeout : error
            await terminate(.failure(error))
            try checkFailure()
            throw error
        }
    }

    /// Async saved-audio callers await actual send completion, preventing a large
    /// recording from bulk-enqueuing beyond the live five-second capture bound.
    func append(samples: [Float]) async throws {
        do {
            try checkFailure()
            try Task.checkCancellation()
            try ingress.enqueue(samples: samples)
            guard !samples.isEmpty else { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if ingress.pendingSampleCount == 0 { continuation.resume() }
                    else { audioWaiters.append(continuation) }
                }
            } onCancel: { Task { await self.cancel() } }
            try Task.checkCancellation()
            try checkFailure()
        } catch {
            // A clean seal rejects late capture without undoing a valid finish.
            if (error as? RealtimeAudioIngressError) != .closed { await terminate(.failure(error)) }
            throw error
        }
    }

    func finish() async throws -> ASRResult {
        if terminal != nil { return try await completed.value() }
        guard startInvoked else { throw DashScopeRealtimeError.notStarted }
        finishRequested = true
        ingress.seal()
        do {
            return try await withAsyncDeadline(seconds: finalTimeout) { [self] in
                try await self.completed.value()
            }
        } catch {
            let error = error is AsyncDeadlineError ? DashScopeRealtimeError.finalTimeout : error
            await terminate(.failure(error))
            return try await completed.value()
        }
    }

    func cancel() async { await terminate(.failure(CancellationError())) }

    private func begin() async throws {
        try checkFailure()
        guard isValidRealtimeEndpoint(configuration.endpoint.absoluteString) else {
            throw RealtimeASRConfigurationError.invalidEndpoint
        }
        failureMonitor = Task { [self] in
            for await failure in ingress.failures {
                let error: Error = failure == .cancelled ? CancellationError() : failure
                await terminate(.failure(error))
                return
            }
        }
        var request = URLRequest(url: configuration.endpoint)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        try await transport.connect(request: request)
        try checkFailure()
        try Task.checkCancellation()
        receiver = Task { [self] in await receiveEvents() }
        try await transport.sendText(ParaformerClientMessage.runTask(taskID: taskID, configuration: configuration).encodedText())
        try checkFailure()
        runTaskSent = true
        beginSendingIfReady()
    }

    private func beginSendingIfReady() {
        guard startAcknowledged, runTaskSent, sender == nil, terminal == nil else { return }
        started.resolve(.success(()))
        sender = Task { [self] in await pumpAudio() }
    }

    private func receiveEvents() async {
        do {
            while terminal == nil {
                let frame = try await transport.receive()
                guard terminal == nil else { return }
                guard case .text(let text) = frame,
                      let data = text.data(using: .utf8) else { throw DashScopeRealtimeError.invalidEvent }
                // Filter by the header first: a foreign task's malformed payload
                // cannot poison this recording's lifecycle or transcript.
                let header = try JSONDecoder().decode(EventHeader.self, from: data)
                guard header.header.taskID == taskID else { continue }
                let event = try JSONDecoder().decode(ParaformerServerEvent.self, from: data)
                switch event.header.event {
                case "task-started":
                    guard !startAcknowledged else { continue }
                    startAcknowledged = true
                    beginSendingIfReady()
                case "result-generated":
                    guard startAcknowledged, event.payload.output?.sentence != nil else {
                        throw DashScopeRealtimeError.invalidEvent
                    }
                    assembler.consume(event)
                case "task-finished":
                    guard finishRequested, finishSent, ingress.isDrained else {
                        throw DashScopeRealtimeError.invalidEvent
                    }
                    let elapsed = startTime.map { $0.duration(to: .now) } ?? .zero
                    let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                    await terminate(.success(ASRResult(text: assembler.finalizedText,
                        providerID: ASRProviderID.cloud, latencyMs: ms)))
                case "task-failed":
                    throw DashScopeRealtimeError.taskFailed(code: event.header.errorCode, message: event.header.errorMessage)
                default: break // Unknown extension events do not change lifecycle.
                }
            }
        } catch {
            let failure: Error
            if error is DecodingError { failure = DashScopeRealtimeError.invalidEvent }
            else if error is WebSocketTransportError { failure = DashScopeRealtimeError.transportClosed }
            else { failure = error }
            await terminate(.failure(failure))
        }
    }

    private func pumpAudio() async {
        do {
            for await _ in ingress.wakeups {
                try await drainAudio()
                if terminal != nil || finishSent { return }
            }
            // Stream completion can precede observation (seal/overflow/cancel).
            try await drainAudio()
        } catch { await terminate(.failure(error)) }
    }

    private func drainAudio() async throws {
        try checkFailure()
        try Task.checkCancellation()
        while let chunk = try ingress.nextChunk() {
            try await transport.sendBinary(encodePCM16LE(chunk.samples))
            try checkFailure()
            try Task.checkCancellation()
            ingress.acknowledge(chunkID: chunk.id)
            if ingress.pendingSampleCount == 0 {
                let waiters = audioWaiters; audioWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if finishRequested, ingress.isDrained, !finishSent {
            finishSent = true
            try await transport.sendText(ParaformerClientMessage.finishTask(taskID: taskID).encodedText())
        }
    }

    private func checkFailure() throws {
        if case .failure(let error) = terminal { throw error }
    }

    private func terminate(_ result: Result<ASRResult, Error>) async {
        guard terminal == nil else { return }
        terminal = result
        failureMonitor?.cancel(); receiver?.cancel(); sender?.cancel()
        failureMonitor = nil; receiver = nil; sender = nil
        switch result {
        case .failure(let error):
            ingress.cancel()
            started.resolve(.failure(error))
            audioWaiters.forEach { $0.resume(throwing: error) }
        case .success:
            audioWaiters.forEach { $0.resume() }
        }
        audioWaiters.removeAll()
        // Close before releasing final consumers, so cleanup is observable.
        await transport.close()
        completed.resolve(result)
    }

    private struct EventHeader: Decodable {
        struct Header: Decodable {
            let taskID: String
            enum CodingKeys: String, CodingKey { case taskID = "task_id" }
        }
        let header: Header
    }
}

/// Completion is persistent, including when it precedes waiter registration.
/// Owners terminate their transport and resolve all waiters on cancellation.
private final class RealtimeResultLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let resolved = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let resolved { continuation.resume(with: resolved) }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            let pending = waiters; waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(with: result) }
    }
}
