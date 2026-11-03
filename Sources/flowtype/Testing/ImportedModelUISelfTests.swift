import Foundation

/// UI boundaries use isolated configuration, temporary files and synthetic runtime providers.
enum ImportedModelUISelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("flowtype-import-ui-\(UUID())")
        let suite = "flowtype-import-ui-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        defer {
            store.flushPendingSave(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retainedFile = root.appendingPathComponent("user-weight-placeholder")
        try? Data([1, 2, 3]).write(to: retainedFile)
        let whisper = ImportedASRModel(name: "My Whisper", directory: root.appendingPathComponent("whisper"),
            engine: .whisperCoreML, variant: "unverified", bits: nil, sizeBytes: 1234, fileFingerprint: "fixture")
        let qwen = ImportedASRModel(name: "My Qwen", directory: root.appendingPathComponent("qwen"),
            engine: .qwenMLX, variant: "1.7B", bits: 8, sizeBytes: 4567, fileFingerprint: "fixture-qwen")
        let assessment: @Sendable (ImportedASRModel) -> LocalModelHardwareAssessment = { model in
            .assess(model: model, physicalMemory: 32 * 1_073_741_824, availableMemory: nil, activeModelBytes: nil, isAppleSilicon: true)
        }
        let probe = ImportUIProbe()
        let state = QwenModelState(load: { target, _, _ in try await probe.load(target) },
            configuration: { store.current }, inspect: { directory in
                var model = directory == qwen.directory ? qwen : whisper; model.directory = directory; return model
            }, assessHardware: { model, _ in assessment(model) }, saveConfiguration: { store.save($0) })
        let actions = ImportedASRModelActions(coordinator: state, configuration: { store.current },
            inspect: { directory in var model = whisper; model.directory = directory; return model }, assess: assessment)
        let before = store.current
        await actions.stage(directory: whisper.directory)?.value
        r.eq(await probe.calls, 0, "import UI: folder selection must inspect without constructing a runtime")
        r.eq(store.current, before, "import UI: static preview must not save or activate")
        r.eq(actions.preview?.model.engine, .whisperCoreML, "import UI: preview shows detected engine")
        await actions.loadPreview()
        r.eq(await probe.calls, 1, "import UI: explicit load uses shared coordinator once")
        r.eq(store.current, before, "import UI: failed load never selects or persists")
        r.check(actions.message?.contains("加载失败") == true && actions.preview != nil, "import UI: failure retains preview and actionable retry")
        r.check(!state.didAutoFallback, "import UI: failure does not silently choose a preset")

        let wp = ImportedASRModelPresentation.make(model: whisper, assessment: assessment(whisper), isActive: false)
        let qp = ImportedASRModelPresentation.make(model: qwen, assessment: assessment(qwen), isActive: true)
        r.eq(wp.id, whisper.id, "import UI: row action identity is UUID")
        r.check(wp.format.contains("Whisper Core ML") && wp.format.contains("待加载验证"), "import UI: static Whisper never invents graph variant")
        r.check(qp.format.contains("Qwen3-ASR MLX") && qp.format.contains("8-bit"), "import UI: custom Qwen has actual family and quantization")
        r.check(wp.source.contains(whisper.directory.path) && qp.source.contains(qwen.directory.path), "import UI: each row has its own true local source")
        r.eq(qp.status, "当前已加载", "import UI: active status follows usable lease")
        r.check(wp.status.contains("未在使用"), "import UI: saved row is not falsely ready")
        r.check(wp.hardwareAdvice.contains("未实测") && wp.hardwareAdvice.contains("未知"), "import UI: unknown memory cannot promise readiness")
        r.check(wp.actions.contains(.relocate) && wp.actions.contains(.removeRecord), "import UI: unavailable path offers relocation and record removal")
        let blocked = LocalModelHardwareAssessment(compatibility: .incompatible, explanation: "预算不足", recommendedMinimumMemory: nil, minimumResidentBytes: nil)
        r.check(!ImportedASRModelPresentation.make(model: qwen, assessment: blocked, isActive: false).actions.contains(.load), "import UI: incompatible assessment disables load")
        r.eq(ImportedASRModelPresentation.downloadablePresets.map(\.id), [ModelPreset.qwen306B.id, ModelPreset.qwen317B.id], "import UI: both downloadable presets remain offered")
        r.check(ImportedASRModelPresentation.sources.contains { $0.url.absoluteString.contains("whisperkit-coreml") }, "import UI: help includes compatible Whisper source")
        r.check(ImportedASRModelPresentation.importHelp.contains("原始 PyTorch 权重不受支持"), "import UI: unsupported raw weights explanation is explicit")
        r.check(ImportedASRModelPresentation.availability(nil).contains("尚未就绪"), "import UI: defer onboarding cannot imply local readiness")
        let identity = LocalModelIdentity(id: whisper.id.uuidString, displayName: whisper.name, engine: "whisperCoreML", repoID: nil, directory: whisper.directory)
        r.check(ImportedASRModelPresentation.availability(identity).contains("Whisper Core ML"), "import UI: status and onboarding show actual engine")

        let unsupported = ImportedASRModelActions(coordinator: state, configuration: { store.current }, inspect: { _ in
            throw ASRModelInspectionError(code: .unsupportedFormat, detail: "原始 PyTorch 权重不受支持，需要兼容 Core ML 格式。")
        })
        await unsupported.stage(directory: root)?.value
        r.check(unsupported.message?.contains("兼容 Core ML") == true && unsupported.preview == nil, "import UI: inspection failure retains concrete format reason")
        r.eq(await probe.calls, 1, "import UI: unsupported preview makes no runtime call")

        var library = Configuration(); library.importedASRModels = [qwen, whisper]; library.activeImportedASRModelID = qwen.id
        store.save(library)
        await actions.stage(directory: qwen.directory, replacing: whisper.id)?.value
        r.check(actions.preview == nil && actions.message?.contains("另一条") == true, "import UI: relocation refuses a different existing row directory")
        store.current.importedASRModels.reverse()
        await actions.stageExisting(id: whisper.id)?.value
        r.eq(actions.preview?.model.id, whisper.id, "import UI: sorting cannot redirect UUID action")
        let moved = root.appendingPathComponent("relocated")
        await actions.stage(directory: moved, replacing: whisper.id)?.value
        r.eq(store.current.importedASRModels.first { $0.id == whisper.id }?.directory, whisper.directory, "import UI: relocation preview does not save new path")
        await actions.loadPreview()
        r.eq(store.current.activeImportedASRModelID, qwen.id, "import UI: failed relocation retains previous active choice")
        r.eq(store.current.importedASRModels.first { $0.id == whisper.id }?.directory, whisper.directory, "import UI: failed relocation retains previous directory")
        await probe.setFailure(false)
        await actions.loadPreview()
        r.eq(store.current.activeImportedASRModelID, whisper.id, "import UI: successful relocation commits selected UUID")
        r.eq(store.current.importedASRModels.first { $0.id == whisper.id }?.directory, moved, "import UI: successful relocation commits path through coordinator")
        r.eq(store.current.importedASRModels.count, 2, "import UI: relocation does not append a duplicate row")
        await actions.stage(directory: root.appendingPathComponent("claimed-later"), replacing: whisper.id)?.value
        var claimed = qwen; claimed.id = UUID(); claimed.directory = root.appendingPathComponent("claimed-later")
        store.current.importedASRModels.append(claimed)
        let beforeClaimed = await probe.calls
        await actions.loadPreview()
        r.eq(await probe.calls, beforeClaimed, "import UI: relocation rechecks directory ownership after preview")
        state.removeImportedModel(id: claimed.id)
        let active = state.activeLease
        actions.remove(id: whisper.id)
        r.eq(state.activeLease, active, "import UI: record removal leaves usable lease alive")
        r.check(FileManager.default.fileExists(atPath: retainedFile.path), "import UI: record removal never deletes user files")
        r.check(!store.current.importedASRModels.contains { $0.id == whisper.id }, "import UI: record removal targets UUID after reorder")
        await actions.stageExisting(id: whisper.id)?.value
        r.check(actions.preview == nil && actions.message?.contains("已移除") == true, "import UI: stale row action cannot select another row")

        // A different open library view may delete the row after this view staged it.
        await actions.stageExisting(id: qwen.id)?.value
        state.removeImportedModel(id: qwen.id)
        let callsBeforeDeletedPreview = await probe.calls
        await actions.loadPreview()
        r.eq(await probe.calls, callsBeforeDeletedPreview, "import UI: deleted preview cannot resurrect the row")

        let gate = ImportUIInspectionGate(model: whisper)
        let slow = ImportedASRModelActions(coordinator: state, configuration: { store.current }, inspect: { directory in
            if directory.lastPathComponent == "slow" { return await gate.wait() }
            var value = whisper; value.directory = directory; return value
        }, assess: assessment)
        let obsolete = slow.stage(directory: root.appendingPathComponent("slow"))
        await gate.waitUntilStarted()
        slow.cancelInspection()
        await slow.stage(directory: root.appendingPathComponent("new"))?.value
        await gate.finish()
        await obsolete?.value
        r.eq(slow.preview?.model.directory.lastPathComponent, "new", "import UI: late cancelled inspection cannot replace newer preview")
        r.check(!slow.isInspecting, "import UI: late cancelled inspection cannot leave busy state")
        let configBeforeCancel = store.current
        slow.cancelInspection()
        r.eq(slow.preview?.model.id, nil, "import UI: cancelling preview clears staged candidate")
        r.eq(store.current, configBeforeCancel, "import UI: cancelling preview has no configuration effect")

        await actions.stage(directory: whisper.directory)?.value
        await probe.suspendNext()
        let closedPreviewLoad = Task { await actions.loadPreview() }
        await probe.waitUntilStarted()
        actions.cancelInspection() // Mirrors closing a sheet while the coordinator still owns loading.
        state.cancel()
        await probe.finish()
        await closedPreviewLoad.value
        r.check(actions.preview == nil && actions.message == nil, "import UI: closed preview ignores late load cancellation message")
        r.eq(store.current, configBeforeCancel, "import UI: closed and cancelled load does not resurrect record")
    }
}

private actor ImportUIProbe {
    var calls = 0
    private var fails = true
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func suspendNext() { shouldSuspend = true }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func setFailure(_ value: Bool) { fails = value }
    func load(_ target: ModelProvisionTarget) async throws -> LocalASRLease {
        calls += 1
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0; startWaiter?.resume(); startWaiter = nil }
        }
        if fails { throw ModelProvisionError.loadFailed() }
        guard case .imported(let model) = target else { throw ModelProvisionError.loadFailed() }
        return .init(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name,
            engine: model.engine.rawValue, repoID: nil, directory: model.directory), provider: ImportUIProvider())
    }
}

private actor ImportUIProvider: ASRProvider {
    nonisolated let id = ASRProviderID.local
    nonisolated let displayName = "Synthetic UI provider"
    nonisolated let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: false, location: .onDevice)
    var isAvailable: Bool { true }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult { .init(text: "fixture", providerID: id, latencyMs: 1) }
}

private actor ImportUIInspectionGate {
    let model: ImportedASRModel
    private var continuation: CheckedContinuation<ImportedASRModel, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    init(model: ImportedASRModel) { self.model = model }
    func wait() async -> ImportedASRModel {
        await withCheckedContinuation { continuation = $0; startWaiter?.resume(); startWaiter = nil }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { continuation?.resume(returning: model); continuation = nil }
}
