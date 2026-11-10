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
    static let process = Self(read: {
        guard ValidationEffects.live.allow(.environment) else { return nil }
        return getenv("HF_ENDPOINT").map { String(cString: $0) }
    }, write: {
        guard ValidationEffects.live.allow(.environment) else { return }
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
    static let shared = QwenModelState(saveConfiguration: { ConfigurationStore.shared.save($0) },
        persistActivation: { try ConfigurationStore.shared.commitNativeASRActivation($0) })

    @Published private(set) var status: QwenModelStatus = .notLoaded
    @Published private(set) var activeLease: LocalASRLease?
    @Published private(set) var failure: ModelProvisionError?
    @Published private(set) var validationFailure: NativeASRActivationError?
    @Published private(set) var operationID: UUID?
    @Published private(set) var didAutoFallback = false
    @Published private(set) var target: ModelProvisionTarget?
    @Published private(set) var operationSource: DownloadSource?
    @Published private(set) var hardwareAssessment: LocalModelHardwareAssessment?
    @Published private(set) var importFailureDetail: String?
    private(set) var pendingImportDirectory: URL?
    // Selection intent survives mutable attempt targets (especially automatic fallback).
    private var selectionRequest: ModelProvisionRequest?

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
    private let inspect: @Sendable (URL) throws -> ImportedASRModel
    private let assessHardware: @Sendable (ImportedASRModel, UInt64?) -> LocalModelHardwareAssessment
    private let saveConfiguration: @MainActor (Configuration) -> Void
    private var operation: Task<Void, Never>?
    private var attemptID: UUID?
    private var userCancelled = false
    private let persistActivation: @MainActor (Configuration) throws -> Void
    private let sampleProvider: @MainActor () throws -> ASRValidationSample
    private let engineVersion: @Sendable (LocalASREngine) -> String
    private let validationSleep: @Sendable (Duration) async throws -> Void
    private let canUnload: @MainActor () -> Bool

    init(
        preflight: @escaping @Sendable (ModelPreset, DownloadSource) async throws -> Void = { preset, source in
            guard ValidationEffects.live.allow(.modelDownload) else { throw ModelProvisionError.loadFailed() }
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
        inspect: @escaping @Sendable (URL) throws -> ImportedASRModel = {
            guard ValidationEffects.live.allow(.modelScan) else { throw ModelProvisionError.incompleteLocal() }
            return try ASRModelInspector.inspect(directory: $0)
        },
        assessHardware: @escaping @Sendable (ImportedASRModel, UInt64?) -> LocalModelHardwareAssessment = {
            LocalModelHardwareAssessment.current(model: $0, activeModelBytes: $1)
        },
        saveConfiguration: @escaping @MainActor (Configuration) -> Void = { _ in },
        commit: @escaping @MainActor (LocalASRLease) -> Void = { _ in },
        persistActivation: @escaping @MainActor (Configuration) throws -> Void = { _ in throw NativeASRActivationError.validationRequired },
        sampleProvider: @escaping @MainActor () throws -> ASRValidationSample = { throw NativeASRActivationError.validationRequired },
        engineVersion: @escaping @Sendable (LocalASREngine) -> String = { LocalASRRuntimeFactory.engineVersion(for: $0) },
        validationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        canUnload: @escaping @MainActor () -> Bool = { false }
    ) {
        self.preflight = preflight; self.sleep = sleep; self.now = now
        self.configuration = configuration; self.localModel = localModel; self.destination = destination
        self.availableDisk = availableDisk; self.environment = environment; self.commit = commit
        self.inspect = inspect; self.assessHardware = assessHardware; self.saveConfiguration = saveConfiguration
        self.persistActivation = persistActivation; self.sampleProvider = sampleProvider
        self.engineVersion = engineVersion; self.validationSleep = validationSleep; self.canUnload = canUnload
        self.load = load ?? { target, offline, progress in
            guard ValidationEffects.live.allow(.modelLoad) else { throw ModelProvisionError.loadFailed() }
            let directory: URL
            let repo: String
            let identity: LocalModelIdentity
            switch target {
            case .uninspectedDirectory: throw ModelProvisionError.incompleteLocal()
            case .imported(let model): return try await LocalASRRuntimeFactory.load(model)
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
            return LocalASRLease(id: UUID(), identity: identity, provider: candidate,
                drain: { await candidate.drainInference() })
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
            case .imported, .uninspectedDirectory: throw ModelProvisionError.incompleteLocal()
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

    func perform(_ request: ModelProvisionRequest) async { _ = await execute(request) }

    /// Each caller retains its own completion. A newer operation may begin after the
    /// gate releases, before an earlier awaiting caller resumes on the main actor.
    private func execute(_ request: ModelProvisionRequest) async -> Result<LocalASRLease, Error> {
        guard !Task.isCancelled else { return .failure(CancellationError()) }
        guard operationID == nil else { return .failure(NativeASRActivationError.busy) }
        let id = UUID()
        let generation = ActivationGeneration(configuration())
        operationID = id; failure = nil; validationFailure = nil; didAutoFallback = false; userCancelled = false
        hardwareAssessment = nil; importFailureDetail = nil
        if case .imported(let model) = request.target { pendingImportDirectory = model.directory }
        else if case .uninspectedDirectory(let directory) = request.target { pendingImportDirectory = directory }
        else { pendingImportDirectory = nil }
        selectionRequest = request
        target = request.target; operationSource = request.source
        status = .loading
        var completion: Result<LocalASRLease, Error> = .failure(CancellationError())
        let task = Task { completion = await run(request, id: id, generation: generation) }
        operation = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: {
            // Mark the operation cancelled synchronously, before a queued main-actor callback
            // could race with candidate commit. The actor callback also suppresses UI progress.
            task.cancel()
            Task { @MainActor [weak self] in if self?.operationID == id { self?.cancel() } }
        })
        return completion
    }

    /// All identities here are importedModelID, never the installation/job UUID.
    func activate(modelID: UUID, sample: ASRValidationSample) async throws -> LocalASRLease {
        guard operationID == nil else { throw NativeASRActivationError.busy }
        guard let model = configuration().importedASRModels.first(where: { $0.id == modelID }) else {
            throw NativeASRActivationError.missingModel
        }
        let result = await execute(.init(target: .imported(model), source: configuration().downloadSource,
                                         origin: .offlineImport, validationSample: sample))
        try Task.checkCancellation()
        return try result.get()
    }

    /// Cancel and drain the owned task before a single gate-covered check and release.
    /// A retained recording lease remains valid; the injected registry decides when release is allowed.
    func unloadCurrentAfterDrain() async throws {
        if let operation { cancel(); await operation.value }
        try Task.checkCancellation()
        guard operationID == nil else { throw NativeASRActivationError.busy }
        let id = UUID(); operationID = id; userCancelled = false
        await ProvisionGate.acquire()
        defer { ProvisionGate.release(); if operationID == id { operationID = nil } }
        try checkOwnership(id)
        guard canUnload() else { throw NativeASRActivationError.resourcesInUse }
        activeLease = nil
        failure = nil; validationFailure = nil
        status = .notLoaded
    }

    func cancel() {
        guard operationID != nil else { return }
        userCancelled = true
        operation?.cancel()
    }

    func loadModel(provider: QwenASRProvider? = nil) async {
        guard operationID == nil else { return }
        if activeLease != nil { return }
        await prepareConfiguredModel(allowDownload: configuration().hasCompletedOnboarding, restoring: true)
    }

    /// Explicit settings actions may download during onboarding and replace a usable lease.
    func retryConfiguredModel() async {
        await prepareConfiguredModel(allowDownload: true)
    }

    func retrySelection(source: DownloadSource) async {
        guard let request = selectionRequest else { await retryConfiguredModel(); return }
        await perform(.init(target: request.target, source: source, origin: request.origin))
    }

    /// Forget a removed folder intent without unloading the lease recordings may still use.
    func resetConfiguredRecovery() {
        guard operationID == nil else { return }
        target = nil
        selectionRequest = nil
        operationSource = nil
        failure = nil
        importFailureDetail = nil
        hardwareAssessment = nil
        pendingImportDirectory = nil
        didAutoFallback = false
        status = activeLease == nil ? .notLoaded : .ready
    }

    private func prepareConfiguredModel(allowDownload: Bool, restoring: Bool = false) async {
        guard operationID == nil else { return }
        let config = configuration()
        operationSource = config.downloadSource
        target = nil
        selectionRequest = nil
        if restoring, !config.pendingLegacyNativeResolution, let selection = config.asrBackendSelection {
            // Resolved backend references are authoritative. An automatic fallback's
            // actual preset must survive a restart even when hardware prefers 1.7B.
            guard let nativeID = [selection.primary, selection.fallback].compactMap({ $0 })
                .first(where: { $0.rawValue.hasPrefix("native:") }) else { return }
            if nativeID.rawValue.hasPrefix("native:preset:") {
                let presetID = String(nativeID.rawValue.dropFirst("native:preset:".count))
                guard let preset = ModelPreset.preset(forID: presetID) else { publish(.incompleteLocal()); return }
                var lookup = config
                lookup.activeImportedASRModelID = nil
                lookup.localModelPath = nil; lookup.customLocalModelPath = nil
                lookup.selectedLocalModelID = preset.id
                guard let resolved = localModel(lookup), resolved.modelId == preset.repoId else {
                    publish(.incompleteLocal()); return
                }
                await perform(.init(target: .offline(resolved), source: config.downloadSource,
                    origin: config.selectedLocalModelID == nil ? .automatic : .manual, restoringValidatedRuntime: true))
            } else if nativeID.rawValue.hasPrefix("native:import:"),
                      let modelID = UUID(uuidString: String(nativeID.rawValue.dropFirst("native:import:".count))),
                      let model = config.importedASRModels.first(where: { $0.id == modelID }) {
                await perform(.init(target: .imported(model), source: config.downloadSource,
                    origin: .offlineImport, restoringValidatedRuntime: true))
            } else { publish(.incompleteLocal()) }
            return
        }
        if let activeID = config.activeImportedASRModelID {
            guard let model = config.importedASRModels.first(where: { $0.id == activeID }) else {
                publish(.incompleteLocal()); return
            }
            await perform(.init(target: .imported(model), source: config.downloadSource, origin: .offlineImport, restoringValidatedRuntime: restoring))
            return
        }
        let explicitPath = [config.customLocalModelPath, config.localModelPath].compactMap { $0 }.first { !$0.isEmpty }
        if let explicitPath {
            do {
                if restoring {
                    await perform(.init(target: .uninspectedDirectory(URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)),
                        source: config.downloadSource, origin: .offlineImport, restoringValidatedRuntime: true))
                } else { try await importOfflineModel(at: URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)) }
            }
            catch is CancellationError { }
            catch { if failure == nil { publish(.incompleteLocal()) } }
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
            // Startup restores only offline historical validation. Explicit automatic
            // recovery retains preset origin and its bounded 1.7B -> 0.6B fallback.
            let target: ModelProvisionTarget = allowDownload && !restoring ? .preset(installedPreset) : .offline(resolved)
            await perform(.init(target: target, source: config.downloadSource, origin: origin, restoringValidatedRuntime: restoring))
            return
        }
        guard !restoring else { validationFailure = .validationRequired; publish(.incompleteLocal()); return }
        guard allowDownload else { return }
        let preset = selectedPreset ?? ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())
        await perform(.init(target: .preset(preset), source: config.downloadSource, origin: origin))
    }

    /// All folder pickers share this strictly offline entry point. Only the coordinator persists selection.
    func importOfflineModel(at directory: URL) async throws {
        guard operationID == nil else { throw ModelProvisionError.loadFailed() }
        let result = await execute(.init(target: .uninspectedDirectory(directory), source: configuration().downloadSource, origin: .offlineImport))
        try Task.checkCancellation()
        _ = try result.get()
    }

    func useImportedModel(_ model: ImportedASRModel) async throws {
        guard operationID == nil else { throw ModelProvisionError.loadFailed() }
        let result = await execute(.init(target: .imported(model), source: configuration().downloadSource, origin: .offlineImport))
        try Task.checkCancellation()
        _ = try result.get()
    }

    /// Removing intent never invalidates an active lease or a recording's retained provider.
    func removeImportedModel(id: UUID) {
        guard operationID == nil else { return }
        let config = configuration()
        let removed = config.importedASRModels.first { $0.id == id }
        saveConfiguration(LocalModelLibrary.removing(id: id, from: config))
        if case .imported(let model) = target, model.id == id { resetConfiguredRecovery() }
        else if let removed, pendingImportDirectory?.standardizedFileURL.resolvingSymlinksInPath()
                    == removed.directory.standardizedFileURL.resolvingSymlinksInPath() { resetConfiguredRecovery() }
    }

    func selectPreset(_ preset: ModelPreset?, automatic: Bool = false) async {
        await perform(.init(target: .preset(preset ?? ModelPreset.recommendedModel(for: HardwareProfiler.currentTier())),
                            source: configuration().downloadSource, origin: automatic ? .automatic : .manual))
    }

    func handleDownloadCompleted(preset: ModelPreset) async {
        await perform(.init(target: .offline(.init(directory: destination(preset), modelId: preset.repoId)),
                            source: configuration().downloadSource, origin: .manual))
    }

    private func run(_ request: ModelProvisionRequest, id: UUID, generation: ActivationGeneration) async -> Result<LocalASRLease, Error> {
        await ProvisionGate.acquire()
        defer {
            ProvisionGate.release()
            if operationID == id { operationID = nil; operation = nil; attemptID = nil }
        }
        do {
            try Task.checkCancellation()
            let capturedSelection = generation.selection
            guard SelectionGeneration(configuration()) == capturedSelection else { throw NativeASRActivationError.changedCandidate }
            let candidate: LocalASRLease
            do { candidate = try await provision(request.target, source: request.source, attempts: 3, id: id, generation: generation) }
            catch {
                try checkOwnership(id)
                guard !(error is CancellationError), request.origin == .automatic,
                      case .preset(let preset) = request.target, preset.id == ModelPreset.qwen317B.id else { throw error }
                didAutoFallback = true
                candidate = try await provision(.preset(.qwen306B), source: request.source, attempts: 1, id: id, generation: generation)
            }
            try checkOwnership(id)
            let model = try await validationModel(for: candidate, id: id)
            let version = engineVersion(model.engine)
            guard candidate.engineVersion == version else { throw NativeASRActivationError.changedCandidate }
            let record: ASRNativeValidationRecord?
            if request.restoringValidatedRuntime {
                let current = try await LocalModelInspection.inspect(directory: model.directory, using: inspect)
                try checkOwnership(id)
                guard current.fileFingerprint == model.fileFingerprint, current.engine == model.engine,
                      current.tokenizerDirectory == model.tokenizerDirectory,
                      current.qwenCompatibilityModelID == model.qwenCompatibilityModelID else {
                    throw NativeASRActivationError.changedCandidate
                }
                try requireHistoricalValidation(model)
                record = configuration().installedASRModels.first(where: { $0.importedModelID == model.id })?.validation
            } else {
                let sample = try request.validationSample ?? sampleProvider()
                record = try await validate(candidate, model: model, sample: sample, version: version, id: id)
            }
            try checkOwnership(id)
            guard SelectionGeneration(configuration()) == capturedSelection else { throw NativeASRActivationError.changedCandidate }
            // Library removal/replacement during an await cannot resurrect the captured candidate.
            try checkGeneration(generation, modelID: model.id, directory: model.directory)
            if let record { try commitSelection(candidate, request: request, model: model, validation: record) }
            activeLease = candidate; commit(candidate); failure = nil; status = .ready
            return .success(candidate)
        } catch is CancellationError {
            didAutoFallback = false
            status = activeLease == nil ? .notLoaded : .ready
            return .failure(CancellationError())
        } catch {
            validationFailure = error as? NativeASRActivationError
            if userCancelled {
                didAutoFallback = false
                status = activeLease == nil ? .notLoaded : .ready
            }
            else {
                if let inspection = error as? ASRModelInspectionError { importFailureDetail = inspection.detail }
                if case .uninspectedDirectory = target { publish(.incompleteLocal()) }
                else { publish(error as? ModelProvisionError ?? .loadFailed()) }
            }
            return .failure(error)
        }
    }

    private func checkOwnership(_ id: UUID) throws {
        try Task.checkCancellation()
        if userCancelled || operationID != id { throw CancellationError() }
    }

    private func provision(_ target: ModelProvisionTarget, source: DownloadSource, attempts: Int, id: UUID,
                           generation: ActivationGeneration) async throws -> LocalASRLease {
        self.target = target
        let importDirectory: URL?
        switch target {
        case .imported(let staged): importDirectory = staged.directory
        case .uninspectedDirectory(let directory): importDirectory = directory
        default: importDirectory = nil
        }
        if let importDirectory {
            // The reservation and global gate are already held, including legacy initial
            // inspection. Cancellation cannot publish a late assessment or enter a runtime.
            var current = try await LocalModelInspection.inspect(directory: importDirectory, using: inspect)
            try checkOwnership(id)
            if case .imported(let staged) = target {
                current.id = staged.id
                current.name = staged.name
            }
            current = LocalModelLibrary.canonicalizing(current, in: configuration())
            let refreshed = ModelProvisionTarget.imported(current)
            self.target = refreshed
            let assessment = assessHardware(current, activeLease?.minimumResidentBytes)
            hardwareAssessment = assessment
            guard assessment.compatibility != .incompatible else {
                importFailureDetail = assessment.explanation
                throw ModelProvisionError.loadFailed()
            }
            try checkOwnership(id)
            if selectionRequest?.restoringValidatedRuntime == true { try requireHistoricalValidation(current) }
            return try await attempt(refreshed, offline: true, id: id, generation: generation)
        }
        if case .offline(let resolved) = target {
            if selectionRequest?.restoringValidatedRuntime == true {
                let current = try await LocalModelInspection.inspect(directory: resolved.directory, using: inspect)
                try checkOwnership(id)
                let canonical = LocalModelLibrary.canonicalizing(current, in: configuration())
                try requireHistoricalValidation(canonical)
                let assessment = assessHardware(canonical, activeLease?.minimumResidentBytes)
                hardwareAssessment = assessment
                guard assessment.compatibility != .incompatible else { throw ModelProvisionError.loadFailed() }
            }
            return try await attempt(target, offline: true, id: id, generation: generation)
        }
        guard case .preset(let preset) = target else { throw ModelProvisionError.incompleteLocal() }
        var config = Configuration()
        config.selectedLocalModelID = preset.id
        if let resolved = localModel(config) {
            return try await attempt(.offline(resolved), offline: true, id: id, generation: generation)
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
                return try await attempt(target, offline: false, id: id, generation: generation)
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

    /// Synchronous main-actor transaction: read the latest config so unrelated edits made
    /// while loading survive; no path, library, or active reference changes before success.
    private func commitSelection(_ candidate: LocalASRLease, request: ModelProvisionRequest,
                                 model validatedModel: ImportedASRModel, validation: ASRNativeValidationRecord) throws {
        var config = configuration()
        if case .imported(var model) = target {
            if let metadata = candidate.whisperMetadata { model.variant = metadata.variant }
            config = LocalModelLibrary.upserting(model, in: config)
            config.activeImportedASRModelID = model.id
            config.selectedLocalModelID = nil
            config.customLocalModelPath = model.engine == .qwenMLX ? model.directory.path : nil
            config.localModelPath = nil
        } else if case .preset(let preset) = target {
            config.activeImportedASRModelID = nil
            config.customLocalModelPath = nil
            config.localModelPath = nil
            config.selectedLocalModelID = request.origin == .automatic ? nil : preset.id
        } else {
            // .offline is retained for installed built-in preset bootstrap/download completion.
            // Legacy custom paths always enter through inspected .imported instead.
            config.migrateASRBackendSelectionIfNeeded()
            if request.origin == .automatic { config.resolveLegacyNativeSelection(lease: candidate) }
            else { config.selectNativeASRBackend(lease: candidate) }
            config = recording(validation, model: validatedModel, in: config)
            try persistActivation(config)
            return
        }
        config.migrateASRBackendSelectionIfNeeded()
        if request.origin == .automatic { config.resolveLegacyNativeSelection(lease: candidate) }
        else { config.selectNativeASRBackend(lease: candidate) }
        config = recording(validation, model: validatedModel, in: config)
        try persistActivation(config)
    }

    private func recording(_ validation: ASRNativeValidationRecord, model: ImportedASRModel,
                           in config: Configuration) -> Configuration {
        var model = model
        if let existing = config.importedASRModels.first(where: { $0.id == model.id }),
           case .imported = target { model.variant = existing.variant }
        var result = LocalModelLibrary.upserting(model, in: config)
        if let index = result.installedASRModels.firstIndex(where: { $0.importedModelID == model.id }) {
            result.installedASRModels[index].validation = validation
        } else {
            // Legacy/adopted directories are external until B6 explicitly establishes ownership.
            result.installedASRModels.append(.init(id: UUID(), importedModelID: model.id, ownership: .external,
                installPlan: nil, directory: model.directory, validation: validation))
        }
        return result
    }

    private func requireHistoricalValidation(_ model: ImportedASRModel) throws {
        guard let record = configuration().installedASRModels.first(where: { $0.importedModelID == model.id }),
              record.directory.standardizedFileURL == model.directory.standardizedFileURL,
              let validation = record.validation, validation.fileFingerprint == model.fileFingerprint,
              validation.engineVersion == engineVersion(model.engine), validation.sampleSHA256.count == 64,
              validation.sampleSHA256.allSatisfy({ $0.isHexDigit }), validation.latencyMs >= 0 else {
            throw NativeASRActivationError.validationRequired
        }
    }

    private func validationModel(for candidate: LocalASRLease, id: UUID) async throws -> ImportedASRModel {
        if case .imported(let model) = target { return model }
        // Legacy preset downloader currently allocates during download. B6 moves that
        // download to B4, then performs static/memory admission before candidate allocation.
        let current = try await LocalModelInspection.inspect(directory: candidate.identity.directory, using: inspect)
        try checkOwnership(id)
        return LocalModelLibrary.canonicalizing(current, in: configuration())
    }

    private func validate(_ candidate: LocalASRLease, model: ImportedASRModel, sample: ASRValidationSample,
                          version: String, id: UUID) async throws -> ASRNativeValidationRecord {
        guard !candidate.provider.capabilities.requiresNetwork, candidate.provider.capabilities.location == .onDevice else {
            throw NativeASRActivationError.onlineProvider
        }
        let started = now()
        let work = Task {
            try await candidate.provider.transcribe(.init(samples: sample.samples, sampleRate: sample.sampleRate,
                language: nil, context: nil, timeout: 20))
        }
        var timedOut = false
        let watchdog = Task {
            do { try await validationSleep(.seconds(20)) } catch { return }
            guard !Task.isCancelled else { return }
            timedOut = true
            validationFailure = .deadlineExceeded
            work.cancel()
        }
        let outcome = await withTaskCancellationHandler(operation: { await work.result }, onCancel: { work.cancel() })
        watchdog.cancel()
        await watchdog.value
        await candidate.drain()
        let result: ASRResult
        do { result = try outcome.get() }
        catch {
            try checkOwnership(id)
            if timedOut || now().timeIntervalSince(started) >= 20 { throw NativeASRActivationError.deadlineExceeded }
            throw error
        }
        try checkOwnership(id)
        let elapsed = now().timeIntervalSince(started)
        guard !timedOut, elapsed >= 0, elapsed < 20 else { throw NativeASRActivationError.deadlineExceeded }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeASRActivationError.emptyResult }
        let current = try await LocalModelInspection.inspect(directory: model.directory, using: inspect)
        try checkOwnership(id)
        guard current.fileFingerprint == model.fileFingerprint, current.engine == model.engine,
              current.tokenizerDirectory == model.tokenizerDirectory,
              current.qwenCompatibilityModelID == model.qwenCompatibilityModelID,
              engineVersion(model.engine) == version, candidate.engineVersion == version else {
            throw NativeASRActivationError.changedCandidate
        }
        return .init(fileFingerprint: model.fileFingerprint, engineVersion: version, sampleSHA256: sample.sha256,
                     validatedAt: now(), latencyMs: Int(min(elapsed * 1000, Double(Int.max))))
    }

    private struct ActivationGeneration {
        let selection: SelectionGeneration
        let models: [ImportedASRModel]
        let records: [ASRInstalledModelRecord]
        init(_ config: Configuration) {
            selection = SelectionGeneration(config)
            models = config.importedASRModels; records = config.installedASRModels
        }
    }

    private struct SelectionGeneration: Equatable {
        let selection: ASRBackendSelection?
        let imported: UUID?
        let preset: String?
        let local: String?
        let custom: String?
        let unresolved: Bool
        init(_ config: Configuration) {
            selection = config.asrBackendSelection; imported = config.activeImportedASRModelID
            preset = config.selectedLocalModelID; local = config.localModelPath; custom = config.customLocalModelPath
            unresolved = config.pendingLegacyNativeResolution
        }
    }

    private func checkGeneration(_ generation: ActivationGeneration, modelID: UUID?, directory: URL) throws {
        guard SelectionGeneration(configuration()) == generation.selection else { throw NativeASRActivationError.changedCandidate }
        let relevantModel: (ImportedASRModel) -> Bool = {
            $0.id == modelID || $0.directory.standardizedFileURL == directory.standardizedFileURL
        }
        let relevantRecord: (ASRInstalledModelRecord) -> Bool = {
            $0.importedModelID == modelID || $0.directory.standardizedFileURL == directory.standardizedFileURL
        }
        guard configuration().importedASRModels.first(where: relevantModel) == generation.models.first(where: relevantModel),
              configuration().installedASRModels.first(where: relevantRecord) == generation.records.first(where: relevantRecord) else {
            throw NativeASRActivationError.changedCandidate
        }
    }

    private func attempt(_ target: ModelProvisionTarget, offline: Bool, id: UUID,
                         generation: ActivationGeneration) async throws -> LocalASRLease {
        try checkOwnership(id)
        let token = UUID(); attemptID = token
        let progress = ProvisionProgress(now: now())
        let totalBytes: Double
        if case .preset(let preset) = target { totalBytes = Double(preset.expectedSizeBytes) } else { totalBytes = 0 }
        status = offline ? .loading : .downloading(progress: 0, speedMBps: 0, etaSeconds: 0)
        let load = self.load, now = self.now
        let work = Task {
            try checkOwnership(id)
            let modelID: UUID?
            let directory: URL
            switch target {
            case .imported(let model): modelID = model.id; directory = model.directory
            case .offline(let resolved): modelID = nil; directory = resolved.directory
            case .preset(let preset): modelID = nil; directory = destination(preset)
            case .uninspectedDirectory: throw ModelProvisionError.incompleteLocal()
            }
            try checkGeneration(generation, modelID: modelID, directory: directory)
            return try await load(target, offline) { [weak self] fraction in
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
