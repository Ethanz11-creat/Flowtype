import Combine
import CryptoKit
import Foundation

/// Persistable historical evidence. Contains no transcript, credential, or endpoint.
struct ASRServiceValidationRecord: Codable, Equatable, Sendable {
    let backendID: ASRBackendID
    let revision: UUID
    let credentialGeneration: UUID?
    let validatedAt: Date
}

enum ASRServiceValidationState: Equatable, Sendable {
    case idle, configurationValid, testing
    /// Transcription is transient UI state. Consumers may persist the date, never this text.
    case verified(at: Date, text: String)
    case failed(code: String)
}

/// Explicit validation owns no microphone, context, dictionary, configuration or credential store.
/// Production callers pass the generation from the same atomic snapshot as the credential.
@MainActor final class ASRServiceValidationCoordinator: ObservableObject {
    typealias ServiceRecognition = @MainActor (LocalASRServiceProfile, String?, ASRValidationSample) async throws -> String
    typealias CloudRecognition = @MainActor (CloudASRProviderConfig, String, ASRValidationSample) async throws -> String

    @Published private var states: [UUID: ASRServiceValidationState] = [:]
    @Published private var owners: [UUID: UUID] = [:]
    private var configurations: [UUID: String] = [:]
    private var operations: [UUID: Task<String, Error>] = [:]
    // Only for injected/manual callers without a store generation. No key hash is produced.
    private var fallbackCredentials: [UUID: (value: String?, generation: UUID)] = [:]
    private let now: @MainActor () -> Date
    private let onVerified: @MainActor (ASRServiceValidationRecord) -> Void
    private let serviceRecognition: ServiceRecognition
    private let cloudRecognition: CloudRecognition
    private let session: URLSession?
    private let resolver: LocalASRServiceEndpoint.Resolver

    init(session: URLSession? = nil,
         resolver: @escaping LocalASRServiceEndpoint.Resolver = LocalASRServiceEndpoint.resolve,
         now: @escaping @MainActor () -> Date = { Date() },
         onVerified: @escaping @MainActor (ASRServiceValidationRecord) -> Void = { _ in },
         serviceRecognition: ServiceRecognition? = nil, cloudRecognition: CloudRecognition? = nil) {
        self.session = session; self.resolver = resolver
        self.onVerified = onVerified; self.now = now
        self.serviceRecognition = serviceRecognition ?? { profile, credential, sample in
            let provider: any ASRProvider
            switch profile.protocolKind {
            case .openAICompatible: provider = try OpenAICompatibleASRAdapter(session: session, resolver: resolver).makeProvider(profile: profile, credential: credential)
            case .whisperCpp: provider = try WhisperCppASRAdapter(session: session, resolver: resolver).makeProvider(profile: profile, credential: credential)
            case .dashScopeRealtime: throw CloudASRError.unsupportedRealtimeTransport
            }
            return try await provider.transcribe(.init(samples: sample.samples, sampleRate: sample.sampleRate,
                language: nil, context: nil, timeout: 15)).text
        }
        self.cloudRecognition = cloudRecognition ?? { profile, key, sample in
            let configuration = CloudASRRequestConfiguration(provider: profile, apiKey: key, sendContext: false)
            let request = try CloudTranscriptionRequestBuilder.make(configuration: configuration, samples: sample.samples,
                language: nil, context: nil, timeout: 15)
            return try await ASRHTTPTransport(session: session).transcribe(request, originalHost: nil)
        }
    }

    func state(profileID: UUID) -> ASRServiceValidationState { states[profileID] ?? .idle }
    /// Includes cancelled work still draining. Disable another test until false.
    func isTesting(profileID: UUID) -> Bool { owners[profileID] != nil }

    func invalidate(profileID: UUID) {
        configurations.removeValue(forKey: profileID)
        states.removeValue(forKey: profileID)
        fallbackCredentials.removeValue(forKey: profileID)
        operations[profileID]?.cancel()
        // Keep the independent transport owner until that producer exits.
    }

    func checkConfiguration(profile: LocalASRServiceProfile, credential: String?, credentialGeneration: UUID? = nil) {
        prepare(profileID: profile.id, profile: profile, credential: credential, generation: credentialGeneration)
        guard !isTesting(profileID: profile.id) else { return }
        do { try validate(profile: profile, credential: credential); states[profile.id] = .configurationValid }
        catch { states[profile.id] = .failed(code: Self.code(error)) }
    }

    func checkConfiguration(cloudProfile: CloudASRProviderConfig, apiKey: String, credentialGeneration: UUID? = nil) {
        prepare(profileID: cloudProfile.id, profile: cloudProfile, credential: apiKey, generation: credentialGeneration)
        guard !isTesting(profileID: cloudProfile.id) else { return }
        do { try CloudTranscriptionRequestBuilder.validate(provider: cloudProfile, apiKey: apiKey); states[cloudProfile.id] = .configurationValid }
        catch { states[cloudProfile.id] = .failed(code: Self.code(error)) }
    }

    func test(profile: LocalASRServiceProfile, credential: String?, sample: ASRValidationSample, credentialGeneration: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        prepare(profileID: profile.id, profile: profile, credential: credential, generation: credentialGeneration)
        guard !isTesting(profileID: profile.id) else { return }
        do { try validate(profile: profile, credential: credential) }
        catch { states[profile.id] = .failed(code: Self.code(error)); return }
        let recognition = serviceRecognition
        await run(profileID: profile.id, backendID: .init(rawValue: "service:" + profile.id.uuidString),
                  revision: profile.revision, credentialGeneration: credentialGeneration) {
            try await recognition(profile, credential, sample)
        }
    }

    func test(cloudProfile: CloudASRProviderConfig, apiKey: String, sample: ASRValidationSample, credentialGeneration: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        prepare(profileID: cloudProfile.id, profile: cloudProfile, credential: apiKey, generation: credentialGeneration)
        guard !isTesting(profileID: cloudProfile.id) else { return }
        do { try CloudTranscriptionRequestBuilder.validate(provider: cloudProfile, apiKey: apiKey) }
        catch { states[cloudProfile.id] = .failed(code: Self.code(error)); return }
        // The current realtime implementation validates WSS configuration separately from a recording.
        guard cloudProfile.protocolKind != .dashScopeRealtime else { states[cloudProfile.id] = .configurationValid; return }
        let recognition = cloudRecognition
        await run(profileID: cloudProfile.id, backendID: .init(rawValue: "cloud:" + cloudProfile.id.uuidString),
                  revision: cloudProfile.revision, credentialGeneration: credentialGeneration) {
            try await recognition(cloudProfile, apiKey, sample)
        }
    }

    private func validate(profile: LocalASRServiceProfile, credential: String?) throws {
        switch profile.protocolKind {
        case .openAICompatible: _ = try OpenAICompatibleASRAdapter(session: session, resolver: resolver).makeProvider(profile: profile, credential: credential)
        case .whisperCpp: _ = try WhisperCppASRAdapter(session: session, resolver: resolver).makeProvider(profile: profile, credential: credential)
        case .dashScopeRealtime: throw CloudASRError.unsupportedRealtimeTransport
        }
    }

    private func prepare<P: Encodable>(profileID: UUID, profile: P, credential: String?, generation: UUID?) {
        let effectiveGeneration: UUID
        if let generation { effectiveGeneration = generation }
        else if let prior = fallbackCredentials[profileID], prior.value == credential { effectiveGeneration = prior.generation }
        else {
            effectiveGeneration = UUID()
            fallbackCredentials[profileID] = (credential, effectiveGeneration)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Full profiles cover revision and every wire field; the random generation covers credentials.
        let encoded = (profile as? CloudASRProviderConfig).flatMap { try? encoder.encode($0.asrValidationIdentity) }
            ?? (try? encoder.encode(profile))
        var data = encoded ?? Data()
        data.append(contentsOf: effectiveGeneration.uuidString.utf8)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if configurations[profileID] != fingerprint {
            states.removeValue(forKey: profileID)
            operations[profileID]?.cancel()
            configurations[profileID] = fingerprint
        }
    }

    private func run(profileID: UUID, backendID: ASRBackendID, revision: UUID, credentialGeneration: UUID?,
                     recognition: @escaping @MainActor () async throws -> String) async {
        let owner = UUID()
        let fingerprint = configurations[profileID]
        owners[profileID] = owner
        states[profileID] = .testing
        let operation = Task { try Task.checkCancellation(); return try await recognition() }
        operations[profileID] = operation
        defer {
            if owners[profileID] == owner {
                owners.removeValue(forKey: profileID)
                operations.removeValue(forKey: profileID)
            }
        }
        let result = await withTaskCancellationHandler {
            await operation.result
        } onCancel: { operation.cancel() }
        guard owners[profileID] == owner, configurations[profileID] == fingerprint else { return }
        guard !Task.isCancelled, !operation.isCancelled else { states[profileID] = .idle; return }
        switch result {
        case .success(let value):
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { states[profileID] = .failed(code: "invalidResponse"); return }
            let date = now()
            states[profileID] = .verified(at: date, text: text)
            // A state observer may invalidate while receiving the publication above.
            guard owners[profileID] == owner, configurations[profileID] == fingerprint,
                  !Task.isCancelled, !operation.isCancelled else { return }
            onVerified(.init(backendID: backendID, revision: revision,
                             credentialGeneration: credentialGeneration, validatedAt: date))
        case .failure(let error):
            states[profileID] = Self.isCancellation(error) ? .idle : .failed(code: Self.code(error))
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled = error as? CloudASRError { return true }
        let underlying = error as NSError
        return underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled
    }

    /// Only stable categories reach UI state; arbitrary server/network descriptions never do.
    private static func code(_ error: Error) -> String {
        if isCancellation(error) { return "cancelled" }
        guard let error = error as? CloudASRError else { return "network" }
        switch error {
        case .apiError(let status, _):
            switch status {
            case 401, 403: return "auth"
            case 400, 404: return "invalidModel"
            case 413: return "uploadTooLarge"
            case 429: return "rateLimit"
            default: return "http"
            }
        case .timeout: return "timeout"
        case .noAPIKey: return "auth"
        case .noModel: return "invalidModel"
        case .invalidURL: return "invalidURL"
        case .invalidResponse: return "invalidResponse"
        case .unsupportedRealtimeTransport: return "unsupportedProtocol"
        case .audioEncodingFailed: return "audioEncoding"
        case .noActiveProvider: return "unavailable"
        case .cancelled: return "cancelled"
        case .networkError(let underlying):
            let ns = underlying as NSError
            return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut ? "timeout" : "network"
        }
    }
}

extension CloudASRProviderConfig {
    /// Only this legacy display flag is excluded. Revision and every other field remain bound.
    var asrValidationIdentity: Self {
        var result = self; result.isActive = false; return result
    }
}
