import Combine
import Foundation

/// Application-owned projections. Native and transport work stays with the A/B coordinators.
@MainActor final class ASRModelCenterViewModel: ObservableObject {
    @Published private(set) var rows: [ASRModelCenterRow] = []
    @Published var selectedID: ASRBackendID?
    @Published private(set) var installations: [ModelInstallSnapshot] = []
    @Published private(set) var notice: String?
    @Published private(set) var lastTrialResult: ASRModelTrialResult?
    /// Observable through objectWillChange; stored before publishing so reentrant actions see admission.
    private(set) var isBusy = false
    @Published private(set) var busyNotice: String?
    private let configuration: () -> Configuration
    private let persist: (Configuration) throws -> Void
    private let native: QwenModelState
    private let activation: NativeASRActivationCoordinator
    private let validation: ASRServiceValidationCoordinator
    private let credential: (ASRBackendID) throws -> ASRCredentialSnapshot
    private let sample: () throws -> ASRValidationSample
    private let installationSnapshots: () async -> [ModelInstallSnapshot]
    private let now: () -> Date
    private var observations = Set<AnyCancellable>()
    private var observedProfiles: [ASRBackendID: Profile] = [:]
    private var observedGenerations: [ASRBackendID: UUID] = [:]
    private var invalidatedHistory = Set<ASRBackendID>()
    private var currentEvidence: [ASRBackendID: Evidence] = [:]

    private enum Profile: Equatable {
        case service(LocalASRServiceProfile), cloud(CloudASRProviderConfig)
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.service(let a), .service(let b)): a == b
            case (.cloud(let a), .cloud(let b)): a.asrValidationIdentity == b.asrValidationIdentity
            default: false
            }
        }
        var revision: UUID {
            switch self { case .service(let p): p.revision; case .cloud(let p): p.revision }
        }
        var uuid: UUID {
            switch self { case .service(let p): p.id; case .cloud(let p): p.id }
        }
    }
    private struct Evidence {
        let profile: Profile
        let record: ASRServiceValidationRecord
        let coordinatorDate: Date
    }

    init(configuration: @escaping () -> Configuration,
         persist: @escaping (Configuration) throws -> Void,
         native: QwenModelState, validation: ASRServiceValidationCoordinator,
         credential: @escaping (ASRBackendID) throws -> ASRCredentialSnapshot,
         sample: @escaping () throws -> ASRValidationSample,
         installationSnapshots: @escaping () async -> [ModelInstallSnapshot],
         now: @escaping () -> Date) {
        self.configuration = configuration; self.persist = persist
        self.native = native; self.activation = .init(state: native); self.validation = validation
        self.credential = credential; self.sample = sample
        self.installationSnapshots = installationSnapshots; self.now = now
        native.objectWillChange.merge(with: validation.objectWillChange).sink { [weak self] in
            // Published emits before its value changes; observe the resulting domain snapshot.
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &observations)
        refresh()
    }

    func refreshInstallations() async { installations = await installationSnapshots(); refresh() }

    /// C4 calls refresh for configuration/credential changes and on its normal readiness clock.
    func refresh() {
        let config = configuration()
        let selection = ASRBackendMigration.selection(from: config)
        var projected: [ASRModelCenterRow] = []
        func append(_ id: ASRBackendID, _ title: String, _ subtitle: String,
                    _ location: ASRBackendLocation, _ status: ASRModelCenterStatus) {
            projected.append(.init(id: id, title: title, subtitle: subtitle, location: location,
                                   status: status, isPrimary: selection.primary == id, isFallback: selection.fallback == id))
        }
        for preset in ModelPreset.allPresets {
            let id = ASRBackendID(rawValue: "native:preset:" + preset.id)
            let associated = config.installedASRModels.filter { $0.legacyPresetID == preset.id }
            let job = installations.last { $0.plan.recipeID == preset.id && $0.state != .installed }
            append(id, preset.name, "原生离线识别 · 峰值内存未知", .native,
                   nativeStatus(id, installed: !associated.isEmpty, historical: associated.contains { $0.validation != nil }, job: job))
        }
        for model in config.importedASRModels {
            let id = ASRModelCenterPresentation.nativeID(for: model, records: config.installedASRModels)
            if id.rawValue.hasPrefix("native:preset:") { continue }
            let records = config.installedASRModels.filter { $0.importedModelID == model.id }
            append(id, model.name, "\(model.variant) · \(model.sizeBytes) 字节 · 峰值内存未知", .native,
                   nativeStatus(id, installed: true, historical: records.contains { $0.validation != nil }, job: nil))
        }
        for profile in config.localASRServices {
            let id = ASRBackendID(rawValue: "service:" + profile.id.uuidString)
            let model = profile.protocolKind == .whisperCpp ? "由服务端决定" : (profile.modelID ?? "未指定型号")
            append(id, profile.name, model + " · 本机服务；服务自身可能联网", .loopbackService,
                   serviceStatus(id, profile: .service(profile), config: config))
        }
        for profile in config.cloudASRConfig.providers {
            let id = ASRBackendID(rawValue: "cloud:" + profile.id.uuidString)
            append(id, profile.name, profile.model + " · 云端识别", .cloud,
                   serviceStatus(id, profile: .cloud(profile), config: config))
        }
        for id in [selection.primary, selection.fallback].compactMap({ $0 }) where !projected.contains(where: { $0.id == id }) {
            append(id, "所选后端不可用", id.rawValue, location(id), .unavailable(reason: "对应模型或服务已不存在，请明确调整选择。"))
        }
        rows = projected
        if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    private func nativeStatus(_ id: ASRBackendID, installed: Bool, historical: Bool,
                              job: ModelInstallSnapshot?) -> ASRModelCenterStatus {
        if let lease = native.activeLease, ASRBackendID(nativeLease: lease) == id { return .ready }
        if targetID == id {
            if let failure = native.validationFailure { return .failed(reason: failure.localizedDescription) }
            switch native.status {
            case .loading: return .testing
            case .downloading(let progress, _, _): return .downloading(progress: progress)
            case .stalled: return .paused
            case .error(let reason, _): return .failed(reason: reason)
            default: break
            }
        }
        if let job { return ASRModelCenterPresentation.installationStatus(job) }
        return historical ? .previouslyValidated : (installed ? .installedUntested : .notInstalled)
    }
    private var targetID: ASRBackendID? {
        switch native.target {
        case .imported(let model): ASRModelCenterPresentation.nativeID(for: model, records: configuration().installedASRModels)
        case .preset(let preset): .init(rawValue: "native:preset:" + preset.id)
        case .offline(let resolved): ModelPreset.allPresets.first { $0.repoId == resolved.modelId }.map { .init(rawValue: "native:preset:" + $0.id) }
        default: nil
        }
    }
    private func profile(_ id: ASRBackendID, in config: Configuration) -> Profile? {
        if let p = config.localASRServices.first(where: { "service:" + $0.id.uuidString == id.rawValue }) { return .service(p) }
        if let p = config.cloudASRConfig.providers.first(where: { "cloud:" + $0.id.uuidString == id.rawValue }) { return .cloud(p) }
        return nil
    }
    private func serviceStatus(_ id: ASRBackendID, profile: Profile, config: Configuration) -> ASRModelCenterStatus {
        let generation: UUID
        do { generation = try credential(id).generation }
        catch { currentEvidence.removeValue(forKey: id); return .unavailable(reason: error.localizedDescription) }
        if let old = observedProfiles[id], old != profile || observedGenerations[id] != generation {
            currentEvidence.removeValue(forKey: id); invalidatedHistory.insert(id)
            observedProfiles[id] = profile; observedGenerations[id] = generation
            validation.invalidate(profileID: profile.uuid)
        }
        observedProfiles[id] = profile; observedGenerations[id] = generation
        if validation.isTesting(profileID: profile.uuid) { return .testing }
        if case .failed(let code) = validation.state(profileID: profile.uuid) { return .failed(reason: code) }
        if let evidence = currentEvidence[id], matches(evidence, id: id) {
            let age = now().timeIntervalSince(evidence.record.validatedAt)
            return age >= 0 && age < 60 ? .ready : .previouslyValidated
        }
        currentEvidence.removeValue(forKey: id)
        // Process credential generations are intentionally not durable readiness evidence.
        if !invalidatedHistory.contains(id), config.asrServiceValidationRecords.contains(where: { $0.backendID == id && $0.revision == profile.revision }) {
            return .previouslyValidated
        }
        return .installedUntested
    }
    private func matches(_ evidence: Evidence, id: ASRBackendID) -> Bool {
        guard profile(id, in: configuration()) == evidence.profile,
              (try? credential(id).generation) == evidence.record.credentialGeneration,
              case .verified(let date, _) = validation.state(profileID: evidence.profile.uuid),
              date == evidence.coordinatorDate else { return false }
        return true
    }

    private func location(_ id: ASRBackendID) -> ASRBackendLocation {
        id.rawValue.hasPrefix("cloud:") ? .cloud : (id.rawValue.hasPrefix("service:") ? .loopbackService : .native)
    }

    /// One UI intent at a time. This slot owns no Task, provider, or domain operation.
    private func admitUserAction() -> Bool {
        guard !isBusy else {
            busyNotice = "模型中心正在执行另一项操作，请等待完成后重试。"
            return false
        }
        isBusy = true
        busyNotice = nil
        return true
    }

    private func finishUserAction() {
        // Publish after releasing the slot; no older action writes output after this boundary.
        isBusy = false
        objectWillChange.send()
    }

    func selectPrimary(_ id: ASRBackendID) async {
        guard admitUserAction() else { return }
        defer { finishUserAction() }
        notice = nil
        do {
            let before = configuration()
            guard rows.contains(where: { $0.id == id }) else { throw NativeASRActivationError.missingModel }
            var proposed = before
            try ASRSettingsAction.selectPrimary(id).apply(to: &proposed)
            if location(id) == .native {
                try await selectNative(id, intent: .primary)
            } else {
                guard await validate(id) else { refresh(); return }
                guard ASRBackendMigration.selection(from: configuration()) == ASRBackendMigration.selection(from: before),
                      configuration().asrRoutingPolicy == before.asrRoutingPolicy else { throw NativeASRActivationError.changedCandidate }
                guard let evidence = currentEvidence[id], matches(evidence, id: id) else { throw NativeASRActivationError.changedCandidate }
                var latest = configuration()
                try ASRSettingsAction.selectPrimary(id).apply(to: &latest)
                try persist(latest)
            }
        } catch { notice = error.localizedDescription }
        refresh()
    }
    func selectFallback(_ id: ASRBackendID?) async {
        guard admitUserAction() else { return }
        defer { finishUserAction() }
        notice = nil
        do {
            var proposed = configuration()
            try ASRSettingsAction.selectFallback(id).apply(to: &proposed)
            if let id, location(id) == .native { try await selectNative(id, intent: .fallback) }
            else {
                if let id {
                    guard let evidence = currentEvidence[id], matches(evidence, id: id),
                          now().timeIntervalSince(evidence.record.validatedAt) >= 0,
                          now().timeIntervalSince(evidence.record.validatedAt) < 60 else { throw ASRSettingsAction.Conflict.validationRequired }
                }
                try persist(proposed)
            }
        } catch { notice = error.localizedDescription }
        refresh()
    }
    func setAllowsCloudFallback(_ allowed: Bool) { apply(.allowCloudFallback(allowed)) }
    func changePolicy(_ policy: ASRRoutingPolicy) { apply(.changePolicy(policy)) }
    func deselect(_ id: ASRBackendID) { apply(.deselect(id)) }
    private func apply(_ action: ASRSettingsAction) {
        guard admitUserAction() else { return }
        defer { finishUserAction() }
        do { var config = configuration(); try action.apply(to: &config, activeNativeID: native.activeLease.map { .init(nativeLease: $0) }); try persist(config); notice = nil }
        catch { notice = error.localizedDescription }
        refresh()
    }

    func test(_ id: ASRBackendID) async {
        guard admitUserAction() else { return }
        defer { finishUserAction() }
        notice = nil; lastTrialResult = nil
        if location(id) == .native {
            do {
                let pcm = try sample()
                if let model = nativeModel(id) { lastTrialResult = try await activation.test(modelID: model.id, sample: pcm) }
                else if let preset = nativePreset(id) { lastTrialResult = try await activation.test(preset: preset, sample: pcm) }
                else { throw NativeASRActivationError.missingModel }
            } catch { notice = error.localizedDescription }
        } else { _ = await validate(id) }
        refresh()
    }
    private func nativeModel(_ id: ASRBackendID) -> ImportedASRModel? {
        let config = configuration()
        return config.importedASRModels.first { ASRModelCenterPresentation.nativeID(for: $0, records: config.installedASRModels) == id }
    }
    private func nativePreset(_ id: ASRBackendID) -> ModelPreset? {
        ModelPreset.allPresets.first { "native:preset:" + $0.id == id.rawValue }
    }
    private func selectNative(_ id: ASRBackendID, intent: NativeASRSelectionIntent) async throws {
        let pcm = try sample()
        if let model = nativeModel(id) {
            _ = try await activation.activate(modelID: model.id, sample: pcm, selectionIntent: intent)
        } else if let preset = nativePreset(id) {
            _ = try await activation.activate(preset: preset, sample: pcm, selectionIntent: intent)
        } else { throw NativeASRActivationError.missingModel }
    }

    /// Only current successful recognition can populate runtime evidence. No restored records enter this map.
    private func validate(_ id: ASRBackendID) async -> Bool {
        do {
            guard let captured = profile(id, in: configuration()) else { throw ASRSettingsAction.Conflict.missingProfile }
            guard !validation.isTesting(profileID: captured.uuid) else { throw NativeASRActivationError.busy }
            currentEvidence.removeValue(forKey: id); lastTrialResult = nil
            let started = now()
            let key = try credential(id)
            let pcm = try sample()
            switch captured {
            case .service(let p): await validation.test(profile: p, credential: key.value, sample: pcm, credentialGeneration: key.generation)
            case .cloud(let p): await validation.test(cloudProfile: p, apiKey: key.value ?? "", sample: pcm, credentialGeneration: key.generation)
            }
            guard !Task.isCancelled, profile(id, in: configuration()) == captured,
                  try credential(id).generation == key.generation else { throw NativeASRActivationError.changedCandidate }
            guard case .verified(let coordinatorDate, let text) = validation.state(profileID: captured.uuid) else {
                if case .failed(let code) = validation.state(profileID: captured.uuid) { notice = "试识别失败：" + code }
                else { notice = "配置有效，但尚未完成真实试识别。" }
                return false
            }
            let record = ASRServiceValidationRecord(backendID: id, revision: captured.revision,
                credentialGeneration: key.generation, validatedAt: coordinatorDate)
            guard try persistValidation(record) else { return false }
            currentEvidence[id] = .init(profile: captured, record: record, coordinatorDate: coordinatorDate)
            invalidatedHistory.remove(id)
            observedProfiles[id] = captured; observedGenerations[id] = key.generation
            lastTrialResult = .init(backendID: id, text: text, latencyMs: Int(min(Double(Int32.max), max(0, now().timeIntervalSince(started) * 1000))))
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    /// A5 may still own its transport slot during onVerified. This callback persists history only;
    /// the awaited model-center test separately checks its full captured input before publishing live evidence.
    @discardableResult func recordValidation(_ record: ASRServiceValidationRecord) -> Bool {
        // Historical callbacks are not UI actions and must not overwrite an admitted action's notice.
        (try? persistValidation(record)) ?? false
    }

    private func persistValidation(_ record: ASRServiceValidationRecord) throws -> Bool {
        let config = configuration()
        guard let current = profile(record.backendID, in: config), current.revision == record.revision,
              try credential(record.backendID).generation == record.credentialGeneration,
              case .verified(let date, _) = validation.state(profileID: current.uuid), date == record.validatedAt else { return false }
        if config.asrServiceValidationRecords.contains(record) { return true }
        var latest = config
        latest.asrServiceValidationRecords.removeAll { $0.backendID == record.backendID }
        latest.asrServiceValidationRecords.append(record)
        try persist(latest)
        return true
    }

    /// C4 supplies only these live, matching, unexpired records to readiness; never persisted history.
    var currentValidatedServices: [ASRServiceValidationRecord] {
        currentEvidence.compactMap { id, evidence in
            guard matches(evidence, id: id), now().timeIntervalSince(evidence.record.validatedAt) >= 0,
                  now().timeIntervalSince(evidence.record.validatedAt) < 60 else { return nil }
            return evidence.record
        }
    }

    func remove(_ id: ASRBackendID, deleteManagedFiles: Bool) async {
        guard admitUserAction() else { return }
        defer { finishUserAction() }
        notice = nil
        do {
            let config = configuration(); let selection = ASRBackendMigration.selection(from: config)
            guard selection.primary != id, selection.fallback != id else { throw NativeModelUsageError.selected }
            if location(id) == .native {
                guard let model = config.importedASRModels.first(where: { ASRModelCenterPresentation.nativeID(for: $0, records: config.installedASRModels) == id }) else { throw NativeASRActivationError.missingModel }
                if native.activeLease.map({ ASRBackendID(nativeLease: $0) == id || $0.usageToken?.modelID == model.id }) == true { try await activation.unloadCurrentAfterDrain() }
                try await native.removeModelRecord(id: model.id, deleteManagedFiles: deleteManagedFiles)
            } else {
                guard !deleteManagedFiles else { throw NativeModelUsageError.external }
                guard let profile = profile(id, in: config) else { throw ASRSettingsAction.Conflict.missingProfile }
                validation.invalidate(profileID: profile.uuid)
                currentEvidence.removeValue(forKey: id)
                var latest = config
                if case .cloud(let p) = profile { try ASRSettingsAction.deleteCloud(p.id, confirmSelected: false).apply(to: &latest) }
                else { latest.localASRServices.removeAll { "service:" + $0.id.uuidString == id.rawValue } }
                latest.asrServiceValidationRecords.removeAll { $0.backendID == id }
                try persist(latest)
            }
        } catch { notice = error.localizedDescription }
        await refreshInstallations()
    }
}
