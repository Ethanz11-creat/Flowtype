import Combine
import Foundation

/// Application lifetime composition only; domain tasks remain with the installer, Qwen and A5.
@MainActor final class ASRModelCenterEnvironment: ObservableObject {
    @Published private(set) var isRecovering = false
    @Published private(set) var recoveryError: String?
    static let shared = ASRModelCenterEnvironment(store: .shared, native: .shared, installer: .shared,
        resources: .shared, checks: .shared, usage: .shared,
        sample: { try ASRApplicationModelDependencies.sample() }, now: { Date() },
        readinessRefresh: { ReadinessMonitor.shared.refresh() })
    let model: ASRModelCenterViewModel
    let native: QwenModelState
    let installer: ModelInstallationCoordinator
    let store: ConfigurationStore
    let resources: SessionResourceCoordinator
    let checks: SettingsConnectionChecks
    let importedActions: ImportedASRModelActions
    let hfSession: HFModelInstallSession
    let discovery: ASRModelDiscoveryClient
    let validation: ASRServiceValidationCoordinator
    private let usage: NativeModelUsageRegistry
    private var observations = Set<AnyCancellable>()
    private var clockTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private let readinessRefresh: () -> Void
    private final class HistoryReceiver { weak var model: ASRModelCenterViewModel? }

    init(store: ConfigurationStore, native: QwenModelState, installer: ModelInstallationCoordinator,
         resources: SessionResourceCoordinator, checks: SettingsConnectionChecks,
         usage: NativeModelUsageRegistry, discovery: ASRModelDiscoveryClient = .init(),
         sample: @escaping () throws -> ASRValidationSample, now: @escaping () -> Date,
         readinessRefresh: @escaping () -> Void = {},
         makeValidation: (@escaping @MainActor (ASRServiceValidationRecord) -> Void) -> ASRServiceValidationCoordinator = { ASRServiceValidationCoordinator(onVerified: $0) }) {
        self.store = store; self.native = native; self.installer = installer
        self.resources = resources; self.checks = checks; self.usage = usage; self.discovery = discovery
        self.readinessRefresh = readinessRefresh
        importedActions = .init(coordinator: native, configuration: { store.current })
        hfSession = .init(credentialStore: store.asrCredentials, installer: installer)
        let receiver = HistoryReceiver()
        validation = makeValidation { [receiver] in _ = receiver.model?.recordValidation($0) }
        model = .init(configuration: { store.current }, persist: { try store.commitNativeASRActivation($0) },
            native: native, validation: validation,
            credential: { try Self.credential($0, store: store) }, sample: sample,
            installationSnapshots: { await installer.snapshots() }, now: now)
        receiver.model = model
    }
    static func credential(_ id: ASRBackendID, store: ConfigurationStore) throws -> ASRCredentialSnapshot {
        if let profile = store.current.cloudASRConfig.providers.first(where: { "cloud:" + $0.id.uuidString == id.rawValue }) {
            return try store.cloudASRCredential(profileID: profile.id)
        }
        if let profile = store.current.localASRServices.first(where: { "service:" + $0.id.uuidString == id.rawValue }) {
            return try profile.credentialSnapshot(store: store.asrCredentials)
        }
        throw ASRCredentialError.invalidData
    }
    /// Start only at the application boundary, never from a view's appearance.
    func start() {
        guard startupTask == nil else { return }
        store.$current.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &observations)
        // VM refresh already follows native/A5 changes. Readiness reads it but does not
        // feed back into the VM, avoiding an objectWillChange refresh loop.
        model.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.readinessRefresh() }
        }.store(in: &observations)
        isRecovering = true
        startupTask = Task { [weak self, installer] in
            do { _ = try await installer.recover() }
            catch { self?.recoveryError = "安装任务恢复失败：" + error.localizedDescription }
            guard let self else { return }
            self.isRecovering = false
            await self.model.refreshInstallations()
            self.refresh()
            self.startClock()
        }
    }
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await self.model.refreshInstallations()
                self.readinessRefresh()
            }
        }
    }
    deinit { clockTask?.cancel(); startupTask?.cancel() }
    func refresh() { model.refresh(); readinessRefresh() }

    func focus(_ target: SettingsTarget?) {
        guard let target else { return }
        model.refresh()
        model.selectedInstallationID = nil
        let id: ASRBackendID?
        switch target {
        case .asrBackend(let backend): id = backend
        case .provider(let uuid): id = .init(rawValue: "cloud:" + uuid.uuidString)
        case .localModels:
            let selection = ASRBackendMigration.selection(from: store.current)
            id = [selection.primary, selection.fallback].compactMap { $0 }.first { $0.rawValue.hasPrefix("native:") }
        case .modelInstallation(let uuid):
            model.selectedID = nil
            model.selectedInstallationID = model.installations.contains { $0.jobID == uuid } ? uuid : nil
            return
        default: return
        }
        // Recovery never selects another row when its original ID was deleted.
        let config = store.current
        let existing = Set(ModelPreset.allPresets.map { ASRBackendID(rawValue: "native:preset:" + $0.id) }
            + config.importedASRModels.map { ASRModelCenterPresentation.nativeID(for: $0, records: config.installedASRModels) }
            + config.localASRServices.map { ASRBackendID(rawValue: "service:" + $0.id.uuidString) }
            + config.cloudASRConfig.providers.map { ASRBackendID(rawValue: "cloud:" + $0.id.uuidString) })
        model.selectedID = id.flatMap { existing.contains($0) ? $0 : nil }
    }

    func actions(navigation: SettingsNavigation?) -> ASRModelCenterUIActions {
        .init(configuration: { [store] in store.current }, importedActions: importedActions,
            hfSession: hfSession, discovery: discovery, draftChecks: checks.draftChecks, navigation: navigation,
            chooseDirectory: ASRModelCenterUIActions.openDirectory,
            persistImported: { [weak self, store] in try store.commitNativeASRActivation($0); self?.refresh() },
            saveLocal: { [weak self, store] in try store.saveLocalASRServiceDraft($0); self?.refresh() },
            saveCloud: { [weak self, store] in try store.saveModelCenterASRDraft($0); self?.refresh() },
            hasCredential: { [store] in (try? Self.credential($0, store: store).value?.isEmpty == false) == true },
            credential: { [store] in try Self.credential($0, store: store).value },
            saveHFToken: { [store] in try store.asrCredentials.write($0, id: "asr.hf.official") },
            copy: { KeyboardInjector.copyText($0) },
            removalReason: { [weak self] in self?.removalReason($0, deleteManagedFiles: $1) ?? (self == nil ? "模型中心不可用。" : nil) },
            pause: { [installer] in await installer.pause(jobID: $0) },
            resume: { [installer] in try await installer.resume(jobID: $0) },
            cancel: { [installer] in await installer.cancel(jobID: $0) },
            clearPartial: { [installer] in try await installer.clearPartial(jobID: $0) },
            loading: isRecovering, loadError: recoveryError)
    }
    func removalReason(_ id: ASRBackendID, deleteManagedFiles: Bool) -> String? {
        let config = store.current
        if !id.rawValue.hasPrefix("native:") {
            return deleteManagedFiles ? NativeModelUsageError.external.localizedDescription : nil
        }
        let models = config.importedASRModels.filter { ASRModelCenterPresentation.nativeID(for: $0, records: config.installedASRModels) == id }
        guard models.count == 1, let item = models.first else { return "该模型没有可移除的唯一安装记录。" }
        if deleteManagedFiles {
            let records = config.installedASRModels.filter { $0.importedModelID == item.id }
            guard records.count == 1, records[0].ownership == .managed else { return NativeModelUsageError.external.localizedDescription }
        }
        if !usage.hasNoCapturedUsage(modelID: item.id) { return NativeModelUsageError.inUse.localizedDescription }
        if native.operationID != nil { return "原生模型操作仍在执行或排空，请等待完成。" }
        if native.activeLease.map({ ASRBackendID(nativeLease: $0) == id || $0.usageToken?.modelID == item.id }) == true,
           resources.isReserved { return "录音或处理会话仍占用当前模型，请结束会话后重试。" }
        return nil
    }
}

/// Qwen legacy explicit paths and the model center share this exact canonical loader.
@MainActor enum ASRApplicationModelDependencies {
    static func sample(store: ConfigurationStore = .shared) throws -> ASRValidationSample {
        try ASRValidationSampleStore.load(language: store.current.asrLanguage)
    }
    static func canUnload(resources: SessionResourceCoordinator = .shared) -> Bool { !resources.isReserved }
}
