import Foundation
import Combine

enum QwenModelStatus: Equatable {
    case notLoaded
    case downloading(progress: Double, speedMBps: Double, etaSeconds: Int)
    case stalled
    case loading
    case ready
    case error(reason: String, retryable: Bool)

    var isLoading: Bool {
        switch self {
        case .downloading, .loading, .stalled: return true
        default: return false
        }
    }
}

/// HF_ENDPOINT is process-wide. The gate remains held until even an uncancellable loader exits.
@MainActor
private enum ProvisionGate {
    static var busy = false
    static var waiters: [CheckedContinuation<Void, Never>] = []
    static func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    static func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

struct ModelProvisionEnvironment: Sendable {
    let read: @Sendable () -> String?
    let write: @Sendable (String?) -> Void
    static let process = Self(read: { getenv("HF_ENDPOINT").map { String(cString: $0) } }, write: {
        if let value = $0 { setenv("HF_ENDPOINT", value, 1) } else { unsetenv("HF_ENDPOINT") }
    })
}

private final class ProvisionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: Date
    private var fraction = 0.0
    private var finished = false
    init(now: Date) { tick = now }
    func update(_ value: Double, now: Date, bytes: Double) -> (Double, Int) {
        lock.withLock {
            guard value.isFinite, value > fraction else { return (0, 0) }
            let seconds = now.timeIntervalSince(tick)
            let speed = seconds > 0 ? (value - fraction) * bytes / seconds / 1_048_576 : 0
            tick = now; fraction = value; finished = value >= 1
            let estimate = speed > 0 ? max(0, (1 - value) * bytes / speed / 1_048_576) : 0
            return (speed, Int(min(estimate, Double(Int32.max))))
        }
    }
    func isStalled(now: Date) -> Bool { lock.withLock { !finished && now.timeIntervalSince(tick) >= 30 } }
}

@MainActor
final class QwenModelState: ObservableObject {
    static let shared = QwenModelState(commit: { lease in
        if let provider = lease.provider as? QwenASRProvider {
            ASRProviderRegistry.shared.adoptLocalProvider(provider)
        }
    })

    @Published private(set) var status: QwenModelStatus = .notLoaded
    @Published private(set) var activeLease: LocalASRLease?
    @Published private(set) var failure: ModelProvisionError?
    @Published private(set) var operationID: UUID?
    @Published private(set) var didAutoFallback = false

    private let preflight: @Sendable (ModelPreset, DownloadSource) async throws -> Void
    private let load: @Sendable (ModelProvisionTarget, Bool, @escaping @Sendable (Double) -> Void) async throws -> LocalASRLease
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let configuration: @MainActor () -> Configuration
    private let localModel: @Sendable (Configuration) -> ResolvedModel?
    private let destination: @Sendable (ModelPreset) -> URL
    private let availableDisk: @Sendable (URL) -> Int64?
    private let environment: ModelProvisionEnvironment
    private let commit: @MainActor (LocalASRLease) -> Void
    private var operation: Task<Void, Never>?
    private var attemptID: UUID?
    private var userCancelled = false

    init(
        preflight: @escaping @Sendable (ModelPreset, DownloadSource) async throws -> Void = { preset, source in
            _ = try await ModelMetadataPreflight().check(repoID: preset.repoId,
                endpoint: source.validatedEndpoint(isChina: DownloadSource.systemIsLikelyChina()))
        },
        load: (@Sendable (ModelProvisionTarget, Bool, @escaping @Sendable (Double) -> Void) async throws -> LocalASRLease)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        configuration: @escaping @MainActor () -> Configuration = { ConfigurationStore.shared.current },
        localModel: @escaping @Sendable (Configuration) -> ResolvedModel? = { ModelLocator.resolveActiveModel(config: $0) },
        destination: @escaping @Sendable (ModelPreset) -> URL = { $0.localDirectory() },
        availableDisk: @escaping @Sendable (URL) -> Int64? = { directory in
            var existing = directory
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                existing.deleteLastPathComponent()
            }
            return (try? FileManager.default.attributesOfFileSystem(forPath: existing.path)[.systemFreeSize] as? NSNumber)?.int64Value
        },
        environment: ModelProvisionEnvironment = .process,
        commit: @escaping @MainActor (LocalASRLease) -> Void = { _ in }
    ) {
        self.preflight = preflight; self.sleep = sleep; self.now = now
        self.configuration = configuration; self.localModel = localModel; self.destination = destination
        self.availableDisk = availableDisk; self.environment = environment; self.commit = commit
        self.load = load ?? { target, offline, progress in
            let directory: URL
            let repo: String
            let identity: LocalModelIdentity
            switch target {
            case .preset(let preset):
                directory = destination(preset); repo = preset.repoId
                identity = .init(id: preset.id, displayName: preset.name, engine: "qwen", repoID: repo, directory: directory)
            case .offline(let resolved):
                directory = resolved.directory; repo = resolved.modelId
                let preset = ModelPreset.allPresets.first { $0.repoId == repo }
                identity = .init(id: preset?.id ?? repo, displayName: preset?.name ?? directory.lastPathComponent,
                                 engine: "qwen", repoID: repo, directory: directory)
            }
            if !offline { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let candidate = QwenASRProvider()
            try await candidate.loadModel(modelId: repo, cacheDir: directory, offlineMode: offline,
                                          progressHandler: { value, _ in progress(value) })
            return LocalASRLease(id: UUID(), identity: identity, provider: candidate)
        }
    }

    /// Legacy injection adapter: the callback replaces model I/O, not coordinator state transitions.
    /// Its success lease is a harmless stub; production uses the default candidate loader above.
    convenience init(loadDownloadedPreset: @escaping @MainActor (ModelPreset) async throws -> Void) {
        let directory: @Sendable (ModelPreset) -> URL = {
            URL(fileURLWithPath: "/injected-model", isDirectory: true).appendingPathComponent($0.id)
        }
        self.init(preflight: { _, _ in }, load: { target, _, _ in
            let preset: ModelPreset
            switch target {
            case .preset(let value): preset = value
            case .offline(let resolved):
                guard let value = ModelPreset.allPresets.first(where: { $0.repoId == resolved.modelId }) else {
                    throw ModelProvisionError.incompleteLocal()
                }
                preset = value
            }
            try await loadDownloadedPreset(preset)
            return LocalASRLease(id: UUID(), identity: .init(id: preset.id, displayName: preset.name,
                engine: "qwen", repoID: preset.repoId, directory: directory(preset)), provider: QwenASRProvider())
        }, configuration: { Configuration() }, localModel: { _ in nil }, destination: directory,
           availableDisk: { _ in Int64.max }, environment: .init(read: { nil }, write: { _ in }))
    }

    func perform(_ request: ModelProvisionRequest) async {
        guard operationID == nil, !Task.isCancelled else { return }
        let id = UUID()
        operationID = id; failure = nil; didAutoFallback = false; userCancelled = false
        status = .loading
        let task = Task { await run(request, id: id) }
        operation = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: {
            // Mark the operation cancelled synchronously, before a queued main-actor callback
            // could race with candidate commit. The actor callback also suppresses UI progress.
            task.cancel()
            Task { @MainActor [weak self] in if self?.operationID == id { self?.cancel() } }
        })
    }

    func cancel() {
        guard operationID != nil else { return }
        userCancelled = true
        operation?.cancel()
    }

    func loadModel(provider: QwenASRProvider) async {
        guard operationID == nil else { return }
        if activeLease != nil { return }
        let config = configuration()
        let explicitPath = [config.customLocalModelPath, config.localModelPath].compactMap { $0 }.first { !$0.isEmpty }
        if let explicitPath {
            let wanted = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath).resolvingSymlinksInPath()
            guard let resolved = localModel(config), resolved.directory.resolvingSymlinksInPath() == wanted else {
                publish(.incompleteLocal()); return
            }
            // A verified explicit directory remains an import, including legacy selection IDs.
            await perform(.init(target: .offline(resolved), source: config.downloadSource, origin: .offlineImport))
            return
        }

        let selectedPreset = ModelPreset.preset(forID: config.selectedLocalModelID)
        // The locator treats an unknown ID like automatic selection. Reject it before allowing
        // an unrelated installed preset to satisfy an explicit user choice.
        if config.selectedLocalModelID != nil, selectedPreset == nil {
            publish(.incompleteLocal()); return
        }
        let origin: ModelProvisionOrigin = config.selectedLocalModelID == nil ? .automatic : .manual
        if let resolved = localModel(config) {
            guard let installedPreset = ModelPreset.allPresets.first(where: { $0.repoId == resolved.modelId }),
                  selectedPreset == nil || selectedPreset?.id == installedPreset.id else {
                publish(.incompleteLocal()); return
            }
            // Preserve preset identity and origin so a failed automatic local 1.7B can try
            // 0.6B. Before onboarding, local loading is allowed but network fallback is not.
            let target: ModelProvisionTarget = config.hasCompletedOnboarding ? .preset(installedPreset) : .offline(resolved)
            await perform(.init(target: target, source: config.downloadSource, origin: origin))
            return
        }
        guard config.hasCompletedOnboarding else { return }
        let preset = selectedPreset ?? ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())
        await perform(.init(target: .preset(preset), source: config.downloadSource, origin: origin))
    }

    func handleDownloadCompleted(preset: ModelPreset) async {
        await perform(.init(target: .offline(.init(directory: destination(preset), modelId: preset.repoId)),
                            source: configuration().downloadSource, origin: .manual))
    }

    private func run(_ request: ModelProvisionRequest, id: UUID) async {
        await ProvisionGate.acquire()
        defer {
            ProvisionGate.release()
            if operationID == id { operationID = nil; operation = nil; attemptID = nil }
        }
        do {
            try Task.checkCancellation()
            let candidate: LocalASRLease
            do { candidate = try await provision(request.target, source: request.source, attempts: 3, id: id) }
            catch {
                try checkOwnership(id)
                guard !(error is CancellationError), request.origin == .automatic,
                      case .preset(let preset) = request.target, preset.id == ModelPreset.qwen317B.id else { throw error }
                didAutoFallback = true
                candidate = try await provision(.preset(.qwen306B), source: request.source, attempts: 1, id: id)
            }
            try checkOwnership(id)
            activeLease = candidate; commit(candidate); failure = nil; status = .ready
        } catch is CancellationError {
            status = activeLease == nil ? .notLoaded : .ready
        } catch {
            if userCancelled { status = activeLease == nil ? .notLoaded : .ready }
            else { publish(error as? ModelProvisionError ?? .loadFailed()) }
        }
    }

    private func checkOwnership(_ id: UUID) throws {
        try Task.checkCancellation()
        if userCancelled || operationID != id { throw CancellationError() }
    }

    private func provision(_ target: ModelProvisionTarget, source: DownloadSource, attempts: Int, id: UUID) async throws -> LocalASRLease {
        if case .offline = target { return try await attempt(target, offline: true, id: id) }
        guard case .preset(let preset) = target else { throw ModelProvisionError.incompleteLocal() }
        var config = Configuration()
        config.selectedLocalModelID = preset.id
        if let resolved = localModel(config) {
            return try await attempt(.offline(resolved), offline: true, id: id)
        }
        let directory = destination(preset)
        if let free = availableDisk(directory), free < preset.expectedSizeBytes * 2 { throw ModelProvisionError.insufficientDisk() }
        // Validate once, then keep exactly this endpoint for preflight and the entire bottom load.
        let endpoint = try source.validatedEndpoint(isChina: DownloadSource.systemIsLikelyChina())
        let original = environment.read()
        environment.write(endpoint.absoluteString == "https://huggingface.co" ? nil : endpoint.absoluteString)
        defer { environment.write(original) }
        for index in 0..<attempts {
            try checkOwnership(id)
            do {
                try await preflight(preset, .custom(endpoint.absoluteString))
                try checkOwnership(id)
                // speech-swift currently retries each snapshot 3 times (5s/15s backoff).
                // This caps provider invocations, NOT HTTP requests: primary <=9 snapshots,
                // plus <=3 for fallback; each snapshot can request multiple files.
                return try await attempt(target, offline: false, id: id)
            } catch {
                try checkOwnership(id)
                if error is CancellationError { throw error }
                let failure = error as? ModelProvisionError ?? .loadFailed()
                guard failure.isRetryable, index + 1 < attempts else { throw failure }
                try await sleep(.seconds((index + 1) * 10))
            }
        }
        throw ModelProvisionError.loadFailed()
    }

    private func attempt(_ target: ModelProvisionTarget, offline: Bool, id: UUID) async throws -> LocalASRLease {
        try checkOwnership(id)
        let token = UUID(); attemptID = token
        let progress = ProvisionProgress(now: now())
        let totalBytes: Double
        if case .preset(let preset) = target { totalBytes = Double(preset.expectedSizeBytes) } else { totalBytes = 0 }
        status = offline ? .loading : .downloading(progress: 0, speedMBps: 0, etaSeconds: 0)
        let load = self.load, now = self.now
        let work = Task {
            try await load(target, offline) { [weak self] fraction in
                let (speed, eta) = progress.update(fraction, now: now(), bytes: totalBytes)
                Task { @MainActor in
                    guard let self, self.operationID == id, self.attemptID == token, !self.userCancelled,
                          case .downloading = self.status, fraction.isFinite else { return }
                    self.status = fraction >= 1 ? .loading : .downloading(progress: max(0, fraction), speedMBps: speed, etaSeconds: eta)
                }
            }
        }
        var timedOut = false
        let watchdog = Task {
            guard !offline else { return }
            while !Task.isCancelled {
                do { try await sleep(.seconds(5)) } catch { return }
                guard !Task.isCancelled, attemptID == token else { return }
                if progress.isStalled(now: now()) {
                    timedOut = true; status = .stalled; work.cancel(); return
                }
            }
        }
        defer { watchdog.cancel(); if attemptID == token { attemptID = nil } }
        do {
            let candidate = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try checkOwnership(id)
            if timedOut { throw ModelProvisionError.stalled() }
            return candidate
        } catch {
            try checkOwnership(id)
            if timedOut { throw ModelProvisionError.stalled() }
            throw error
        }
    }

    private func publish(_ error: ModelProvisionError) {
        failure = error
        // A user can repair local files and retry a terminal load failure. This UI affordance
        // does not make loadFailed eligible for automatic same-model retries.
        let allowsManualRetry: Bool
        if case .loadFailed = error { allowsManualRetry = true } else { allowsManualRetry = error.isRetryable }
        status = .error(reason: "模型准备失败，可在设置中重试或指定已下载的模型文件夹。", retryable: allowsManualRetry)
    }
}
