import Foundation

/// Observes real coordinator transitions with isolated selection and synthetic model I/O.
enum NativeModelPresentationSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        await selectedLoadedAndPreparingRemainDistinct(r)
        await failedImportKeepsUsableLease(r)
        await automaticFallbackPreservesSelectionIntent(r)
        await cancelledDownloadNeverReportsCompletion(r)
    }

    @MainActor
    private static func selectedLoadedAndPreparingRemainDistinct(_ r: SelfTest.Reporter) async {
        await withFixture(r) { store, state, actions, gate, a, b in
            try? await state.useImportedModel(a)
            // A previously saved choice can differ from a lease retained by an active session.
            store.current.importedASRModels.append(b)
            store.current.activeImportedASRModelID = b.id
            await actions.stageExisting(id: b.id)?.value
            let saved = store.current
            r.eq(state.activeLease?.identity.id, a.id.uuidString, "native model: preview retains loaded A")
            r.eq(store.current, saved, "native model: inspecting B preserves saved selection")
            await gate.suspendNext()
            let loading = Task { await actions.loadPreview() }
            await gate.waitUntilStarted()
            let list = ImportedASRModelList(store: store, coordinator: state, actions: actions)
            let rowA = list.presentation(for: a)
            let rowB = list.presentation(for: b)
            let status = QwenModelStatusCard(modelState: state, store: store, importedActions: actions).selectionPresentation
            r.check(status.selectedName.contains(b.name), "native model: status names saved B independently")
            r.eq(status.loaded?.id, a.id.uuidString, "native model: status names actual loaded A")
            r.check(status.targetName?.contains(b.name) == true && status.isBusy,
                "native model: status names current preparing B")
            r.check(status.selectionNeedsLoading, "native model: selected B never borrows A readiness")
            r.eq(rowA.status, "当前已加载", "native model: retained A remains loaded without selected marker")
            r.check(rowB.status.contains("已选") && rowB.status.contains("正在准备"),
                "native model: selected B and preparing B remain visible together")
            r.check(!rowB.status.contains("已加载"), "native model: preparing B cannot claim a usable lease")
            await gate.finish(fail: true)
            await loading.value
            let failed = list.presentation(for: b)
            r.check(failed.status.contains("已选") && !failed.status.contains("正在准备"),
                "native model: failed B retains selection without stale progress")
            r.eq(store.current, saved, "native model: failed replacement preserves saved B and library")
        }
    }

    @MainActor
    private static func failedImportKeepsUsableLease(_ r: SelfTest.Reporter) async {
        await withFixture(r) { store, state, actions, gate, a, b in
            try? await state.useImportedModel(a)
            let retained = state.activeLease
            let saved = store.current
            await actions.stage(directory: b.directory)?.value
            r.eq(store.current, saved, "native model: new import preview never commits selection")
            await gate.suspendNext()
            let loading = Task { await actions.loadPreview() }
            await gate.waitUntilStarted()
            await gate.finish(fail: true)
            await loading.value
            r.eq(state.activeLease, retained, "native model: failed import keeps usable lease")
            r.eq(store.current, saved, "native model: failed import retains saved selection")
            r.check(actions.preview != nil && actions.message?.contains("加载失败") == true,
                "native model: failed import retains preview and reason for explicit retry")
            await actions.loadPreview()
            r.eq(state.activeLease?.identity.id, b.id.uuidString, "native model: explicit retry loads B")
            let marker = b.directory.appendingPathComponent("user-weights")
            actions.remove(id: b.id)
            r.check(FileManager.default.fileExists(atPath: marker.path), "native model: removal preserves external model directory and weights")
            r.eq(state.activeLease?.identity.id, b.id.uuidString, "native model: removing record retains loaded B")
            r.check(!store.current.importedASRModels.contains { $0.id == b.id }, "native model: removal forgets only record")
        }
    }

    @MainActor
    private static func automaticFallbackPreservesSelectionIntent(_ r: SelfTest.Reporter) async {
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("native-fallback-\(UUID())")
        let suite = "native-fallback-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        let probe = NativePresetProbe(root: root)
        let state = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in try await probe.load(target) },
            configuration: { store.current }, localModel: { _ in nil }, destination: { root.appendingPathComponent($0.id) },
            availableDisk: { _ in Int64.max }, environment: .init(read: { nil }, write: { _ in }),
            saveConfiguration: { store.save($0) })
        await state.perform(.init(target: .preset(.qwen317B), source: .official, origin: .automatic))
        let automatic = LocalModelSelectionPresentation.make(config: store.current, coordinator: state)
        r.eq(automatic.recovery.fallbackLabel, "已退回 0.6B", "native model: successful automatic fallback is labelled")
        r.eq(automatic.loaded?.id, ModelPreset.qwen306B.id, "native model: fallback reports actual 0.6B lease")
        r.check(automatic.selectedName.contains("自动选择"), "native model: automatic selection remains automatic")
        r.eq(store.current.selectedLocalModelID, nil, "native model: fallback never pins manual 0.6B choice")
        r.eq(await probe.attempts, [ModelPreset.qwen317B.id, ModelPreset.qwen306B.id],
            "native model: automatic fallback uses existing serial coordinator once per target")
        store.current.selectedLocalModelID = ModelPreset.qwen317B.id
        await state.selectPreset(.qwen317B)
        let manual = LocalModelSelectionPresentation.make(config: store.current, coordinator: state)
        r.eq(store.current.selectedLocalModelID, ModelPreset.qwen317B.id, "native model: failed manual choice is never rewritten")
        r.eq(manual.loaded?.id, ModelPreset.qwen306B.id, "native model: manual failure retains smaller usable lease")
        r.eq(manual.recovery.fallbackLabel, nil, "native model: manual failure does not claim automatic recovery")
        r.check(manual.selectedName.contains("1.7B") && manual.targetName?.contains("1.7B") == true,
            "native model: manual failure keeps selected and failed target 1.7B visible")
        r.eq(await probe.attempts, [ModelPreset.qwen317B.id, ModelPreset.qwen306B.id, ModelPreset.qwen317B.id],
            "native model: manual selection never launches a hidden fallback")
        r.check(manual.recovery.actions.contains(.retry) && manual.recovery.actions.contains(.useSmallerModel),
            "native model: failure keeps existing explicit recovery actions")
    }

    @MainActor
    private static func cancelledDownloadNeverReportsCompletion(_ r: SelfTest.Reporter) async {
        let suite = "native-cancel-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer { store.flushPendingSave(); defaults.removePersistentDomain(forName: suite) }
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("native-cancel-model-\(UUID())")
        let probe = NativePresetProbe(root: root)
        let state = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in try await probe.load(target) },
            configuration: { store.current }, localModel: { _ in nil }, destination: { root.appendingPathComponent($0.id) },
            availableDisk: { _ in Int64.max }, environment: .init(read: { nil }, write: { _ in }),
            saveConfiguration: { store.save($0) })
        await state.selectPreset(.qwen306B)
        let retained = state.activeLease
        let downloader = ModelDownloader(coordinator: state, configuration: { store.current })
        let actions = ImportedASRModelActions(coordinator: state, configuration: { store.current })
        let picker = LocalModelPicker(store: store, modelState: state, downloader: downloader, importedActions: actions)
        var completed = 0
        let subscription = downloader.$currentDownload.sink { if $0?.status == .completed { completed += 1 } }
        await probe.suspendNext()
        downloader.startDownload(preset: .qwen306B)
        await probe.waitUntilStarted()
        picker.cancelPreparation()
        await probe.finish()
        for _ in 0..<1000 {
            if state.operationID == nil { break }
            await Task.yield()
        }
        for _ in 0..<20 { await Task.yield() }
        r.eq(state.operationID, nil, "native model: cancelled download drains existing operation")
        r.eq(state.activeLease, retained, "native model: cancel action retains prior lease")
        r.eq(completed, 0, "native model: cancel action never reports retained lease as completed download")
        r.eq(downloader.currentDownload?.status, nil, "native model: cancel clears facade progress after draining")
        subscription.cancel()
    }

    private static func assessment(_ model: ImportedASRModel) -> LocalModelHardwareAssessment {
        .assess(model: model, physicalMemory: 32 * 1_073_741_824, availableMemory: nil,
                activeModelBytes: nil, isAppleSilicon: true)
    }

    @MainActor
    private static func withFixture(_ r: SelfTest.Reporter,
        run: (ConfigurationStore, QwenModelState, ImportedASRModelActions, NativeModelLoadGate, ImportedASRModel, ImportedASRModel) async -> Void) async {
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("native-model-\(UUID())")
        let suite = "native-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer {
            store.flushPendingSave(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let a = ImportedASRModel(name: "Loaded Qwen A", directory: root.appendingPathComponent("A"),
            engine: .qwenMLX, variant: "0.6B", bits: 4, sizeBytes: 16, fileFingerprint: "A")
        let b = ImportedASRModel(name: "Selected Whisper B", directory: root.appendingPathComponent("B"),
            engine: .whisperCoreML, variant: "unverified", bits: nil, sizeBytes: 16, fileFingerprint: "B")
        do {
            for model in [a, b] {
                try FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: model.directory.appendingPathComponent("user-weights"))
            }
        } catch { r.check(false, "native model: temporary fixture creation: \(error)"); return }
        let gate = NativeModelLoadGate()
        let state = QwenModelState(load: { target, _, _ in try await gate.load(target) },
            configuration: { store.current }, localModel: { _ in nil }, destination: { root.appendingPathComponent($0.id) },
            availableDisk: { _ in Int64.max }, environment: .init(read: { nil }, write: { _ in }),
            inspect: { $0 == a.directory ? a : b }, assessHardware: { model, _ in assessment(model) },
            saveConfiguration: { store.save($0) })
        let actions = ImportedASRModelActions(coordinator: state, configuration: { store.current },
            inspect: { $0 == a.directory ? a : b }, assess: assessment)
        await run(store, state, actions, gate, a, b)
    }
}

private actor NativeModelLoadGate {
    private var suspend = false
    private var continuation: CheckedContinuation<Bool, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func suspendNext() { suspend = true }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(fail: Bool) { continuation?.resume(returning: fail); continuation = nil }
    func load(_ target: ModelProvisionTarget) async throws -> LocalASRLease {
        if suspend {
            suspend = false
            let fail = await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
            if fail { throw ModelProvisionError.loadFailed() }
        }
        guard case .imported(let model) = target else { throw ModelProvisionError.loadFailed() }
        return .init(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name,
            engine: model.engine.rawValue, repoID: nil, directory: model.directory), provider: NativeModelProvider())
    }
}

private actor NativeModelProvider: ASRProvider {
    nonisolated let id = ASRProviderID.local
    nonisolated let displayName = "Synthetic native model"
    nonisolated let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false,
        requiresNetwork: false, location: .onDevice)
    var isAvailable: Bool { true }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        .init(text: "fixture", providerID: id, latencyMs: 1)
    }
}

private actor NativePresetProbe {
    let root: URL
    private(set) var attempts: [String] = []
    private var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(root: URL) { self.root = root }
    func suspendNext() { suspend = true }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func load(_ target: ModelProvisionTarget) async throws -> LocalASRLease {
        guard case .preset(let preset) = target else { throw ModelProvisionError.loadFailed() }
        attempts.append(preset.id)
        if suspend {
            suspend = false
            await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
        }
        guard preset.id == ModelPreset.qwen306B.id else { throw ModelProvisionError.loadFailed() }
        return .init(id: UUID(), identity: .init(id: preset.id, displayName: preset.name,
            engine: "qwen", repoID: preset.repoId, directory: root.appendingPathComponent(preset.id)),
            provider: NativeModelProvider())
    }
}
