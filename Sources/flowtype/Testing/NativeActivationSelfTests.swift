import Foundation
import Combine

private actor ActivationTrial: ASRProvider {
    nonisolated let id = "activation-fixture"
    nonisolated let displayName = "Fixture"
    nonisolated let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false,
        requiresNetwork: false, location: .onDevice)
    var isAvailable: Bool { true }
    var text = "recognized"
    var fails = false
    var blocked = false
    var calls = 0
    var request: ASRRequest?
    var continuation: CheckedContinuation<Void, Never>?
    func configure(text: String = "recognized", fails: Bool = false, blocked: Bool = false) {
        self.text = text; self.fails = fails; self.blocked = blocked
    }
    func release() { continuation?.resume(); continuation = nil }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        calls += 1; self.request = request
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if fails { throw SpeechProviderError.notAvailable }
        return .init(text: text, providerID: id, latencyMs: 1)
    }
}

private final class ActivationInspection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ImportedASRModel
    private var version = "fixture-engine/adapter-1"
    let gate = ActivationInspectionGate()
    init(_ model: ImportedASRModel) { value = model }
    func inspect() -> ImportedASRModel { gate.wait(); return lock.withLock { value } }
    func change() { lock.withLock { value.fileFingerprint = "changed" } }
    func engineVersion() -> String { lock.withLock { version } }
    func changeVersion() { lock.withLock { version = "fixture-engine/adapter-2" } }
}

@MainActor
private final class ActivationFixture {
    var config = Configuration()
    var loads = 0
    var internetCalls = 0
    var rejectBudget = false
    var persistFails = false
    var canUnload = true
    var samplesRequested = 0
    let clock = ActivationClock()
    let loadGate = ActivationLoadGate()
    var commits = 0
    let trial = ActivationTrial()
    let model: ImportedASRModel
    let inspection: ActivationInspection
    lazy var state = QwenModelState(preflight: { _, _ in }, load: { [self] target, offline, _ in
        let count = await MainActor.run {
            loads += 1
            if !offline { internetCalls += 1 }
            return loads
        }
        await loadGate.wait(count: count)
        let selected: ImportedASRModel
        if case .imported(let value) = target { selected = value } else { selected = model }
        return LocalASRLease(id: UUID(), identity: .init(id: selected.id.uuidString, displayName: selected.name,
            engine: selected.engine.rawValue, repoID: nil, directory: selected.directory), provider: trial,
            minimumResidentBytes: 10, engineVersion: inspection.engineVersion())
    }, now: { [clock] in clock.now() }, configuration: { [self] in config }, localModel: { _ in nil },
        environment: .init(read: { nil }, write: { _ in }), inspect: { [inspection] _ in inspection.inspect() },
        assessHardware: { [self] model, active in
            // The closure executes on the owner's actor, as existing admission does.
            MainActor.assumeIsolated {
                .init(compatibility: rejectBudget && active != nil ? .incompatible : .compatible,
                      explanation: "fixture budget", recommendedMinimumMemory: nil, minimumResidentBytes: 10)
            }
        }, saveConfiguration: { [self] in config = $0 },
        persistActivation: { [self] value in
            if persistFails { throw ASRCredentialError.persistence }
            config = value; commits += 1
        }, sampleProvider: { [self] in samplesRequested += 1; return try NativeActivationFixtures.sample() },
        engineVersion: { [inspection] _ in inspection.engineVersion() },
        validationSleep: { [clock] duration in try await clock.sleep(duration) }, canUnload: { [self] in canUnload })
    lazy var coordinator = NativeASRActivationCoordinator(state: state)
    init(engine: LocalASREngine = .qwenMLX) {
        model = .init(name: "candidate", directory: URL(fileURLWithPath: "/injected/candidate"), engine: engine,
            variant: "0.6B", bits: 4, sizeBytes: 10, tokenizerDirectory: nil, fileFingerprint: "original",
            minimumResidentBytes: 10)
        inspection = ActivationInspection(model)
        config.importedASRModels = [model]
        config.installedASRModels = [.init(id: UUID(), importedModelID: model.id, ownership: .external,
            installPlan: nil, directory: model.directory, validation: nil)]
    }
    func activate() async throws -> LocalASRLease {
        try await coordinator.activate(modelID: model.id, sample: ASRValidationSample(samples: [0, 0.2, -0.2], sampleRate: 16_000, label: "fixture"))
    }
}

enum NativeActivationSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testCandidateValidationIsTransactional(r)
        await testOfflineValidationAndFingerprint(r)
        await testActivationCancelDrain(r)
        await testDeadlineAndGeneration(r)
        await testStartupAndLegacyEntry(r)
        await testNativeProviderDrain(r)
        await testSelectionWhileWaitingForGate(r)
        await testCompletionBelongsToItsOperation(r)
        await testAuthoritativePresetRestore(r)
        await testGenerationBeforeAllocation(r)
    }
    @MainActor static func testCandidateValidationIsTransactional(_ r: SelfTest.Reporter) async {
        let f = ActivationFixture()
        do {
            let old = try await f.activate()
            let selected = f.config
            for mode in ["empty", "throws", "persistence", "budget"] {
                await f.trial.configure(text: mode == "empty" ? " \n " : "recognized", fails: mode == "throws")
                f.persistFails = mode == "persistence"; f.rejectBudget = mode == "budget"
                let loads = f.loads
                do { _ = try await f.activate(); r.check(false, "B5 \(mode) candidate rejected") }
                catch { r.check(true, "B5 \(mode) candidate rejected") }
                r.eq(f.state.activeLease, old, "B5 \(mode) preserves previous runtime")
                r.eq(f.config, selected, "B5 \(mode) preserves selection and validation")
                if mode == "budget" { r.eq(f.loads, loads, "B5 dual budget fails before allocation") }
            }
            f.canUnload = false
            do { try await f.coordinator.unloadCurrentAfterDrain(); r.check(false, "B5 captured resource blocks unload") } catch { }
            r.eq(f.state.activeLease, old, "B5 denied unload preserves runtime")
            f.canUnload = true
            try await f.coordinator.unloadCurrentAfterDrain()
            r.eq(f.state.activeLease, nil, "B5 explicit unload truthfully clears owner")
            f.rejectBudget = false
            await f.trial.configure(fails: true)
            _ = try? await f.activate()
            r.eq(f.state.activeLease, nil, "B5 failed candidate after unload stays unready")
            await f.trial.configure()
            r.eq(try await old.provider.transcribe(.init(samples: [0], sampleRate: 16_000, language: nil, context: nil, timeout: 1)).text,
                 "recognized", "B5 retained lease still usable after owner unload")
        } catch { r.check(false, "B5 transaction fixture: \(error)") }
    }
    @MainActor static func testOfflineValidationAndFingerprint(_ r: SelfTest.Reporter) async {
        for change in ["none", "file", "version"] {
            let f = ActivationFixture(engine: .whisperCoreML)
            await f.trial.configure(blocked: change != "none")
            let task = Task { try await f.activate() }
            if change != "none" {
                while await f.trial.calls == 0 { await Task.yield() }
                if change == "file" { f.inspection.change() } else { f.inspection.changeVersion() }
                await f.trial.release()
            }
            do {
                _ = try await task.value
                r.check(change == "none", "B5 changed \(change) rejected after trial")
            } catch { r.check(change != "none", "B5 fresh trial succeeds") }
            r.eq(f.internetCalls, 0, "B5 native validation strictly offline")
            if change == "none" {
                let sample = try! ASRValidationSample(samples: [0, 0.2, -0.2], sampleRate: 16_000, label: "fixture")
                r.eq(f.config.installedASRModels.first?.validation?.sampleSHA256, sample.sha256, "B5 canonical PCM fingerprint persisted")
                r.eq(f.config.installedASRModels.first?.validation?.engineVersion, f.inspection.engineVersion(), "B5 engine adapter compatibility persisted")
                let request = await f.trial.request
                r.eq(request?.samples, sample.samples, "B5 trial uses injected PCM")
                r.eq(request?.timeout, 20, "B5 native trial bounded at 20 seconds")
                r.eq(request?.context, nil, "B5 no foreground or user context")
                r.eq(f.commits, 1, "B5 validation and selection commit once")
            } else { r.eq(f.commits, 0, "B5 changed \(change) never commits") }
        }
    }
    @MainActor static func testActivationCancelDrain(_ r: SelfTest.Reporter) async {
        let f = ActivationFixture()
        do {
            let old = try await f.activate()
            let original = f.config
            await f.trial.configure(blocked: true)
            let task = Task { try await f.activate() }
            while await f.trial.calls < 2 { await Task.yield() }
            task.cancel()
            await Task.yield()
            do { _ = try await f.activate(); r.check(false, "B5 draining trial rejects competing activation") } catch { }
            r.eq(f.loads, 2, "B5 one candidate lifecycle during cancellation drain")
            r.check(f.state.operationID != nil, "B5 gate remains held through uncancellable trial")
            await f.trial.release()
            _ = try? await task.value
            r.eq(f.state.operationID, nil, "B5 drained trial releases owner gate")
            r.eq(f.state.activeLease, old, "B5 cancelled candidate preserves old lease")
            r.eq(f.config, original, "B5 cancelled candidate preserves selection")
        } catch { r.check(false, "B5 cancellation fixture: \(error)") }
    }
    @MainActor static func testDeadlineAndGeneration(_ r: SelfTest.Reporter) async {
        for mutation in ["deadline", "selection", "library", "unrelated"] {
            let f = ActivationFixture()
            await f.trial.configure(blocked: true)
            let task = Task { try await f.activate() }
            while await f.trial.calls == 0 || f.clock.pending == 0 { await Task.yield() }
            switch mutation {
            case "deadline": f.clock.advance(seconds: 20)
            case "selection": f.config.selectedLocalModelID = ModelPreset.qwen317B.id
            case "library": f.config.importedASRModels.removeAll()
            default: f.config.asrLanguage = .en
            }
            let latest = f.config
            if mutation == "deadline" {
                while f.state.validationFailure != .deadlineExceeded { await Task.yield() }
                r.check(f.state.operationID != nil, "B5 deadline retains gate while native work drains")
                r.eq(f.clock.requestedDuration, .seconds(20), "B5 injected deadline clock uses exactly 20 seconds")
                do { _ = try await f.activate(); r.check(false, "B5 timeout draining blocks next load") } catch { }
                r.eq(f.loads, 1, "B5 timeout does not allocate second candidate")
            }
            await f.trial.release()
            do { _ = try await task.value; r.check(mutation == "unrelated", "B5 \(mutation) cannot commit") }
            catch { r.check(mutation != "unrelated", "B5 unrelated config edits allow trial") }
            if mutation == "unrelated" {
                r.eq(f.config.asrLanguage, .en, "B5 commit preserves latest unrelated config edits")
            } else {
                r.eq(f.config, latest, "B5 \(mutation) leaves latest selection unchanged")
                r.eq(f.state.activeLease, nil, "B5 \(mutation) never publishes candidate")
            }
        }
    }

    @MainActor static func testStartupAndLegacyEntry(_ r: SelfTest.Reporter) async {
        for mode in ["missing", "valid", "file", "version"] {
            let f = ActivationFixture()
            f.config.activeImportedASRModelID = f.model.id
            if mode != "missing" {
                f.config.installedASRModels[0].validation = .init(fileFingerprint: f.model.fileFingerprint,
                    engineVersion: f.inspection.engineVersion(), sampleSHA256: try! NativeActivationFixtures.sample().sha256,
                    validatedAt: Date(timeIntervalSince1970: 1), latencyMs: 1)
            }
            if mode == "file" { f.inspection.change() }
            if mode == "version" { f.inspection.changeVersion() }
            let original = f.config
            await f.state.loadModel()
            r.eq(f.samplesRequested, 0, "B5 startup \(mode) never requests sample")
            r.eq(await f.trial.calls, 0, "B5 startup \(mode) never runs trial")
            r.eq(f.internetCalls, 0, "B5 startup \(mode) never downloads")
            r.eq(f.loads, mode == "valid" ? 1 : 0, "B5 startup requires fresh historical evidence before allocation")
            if mode != "valid" {
                r.eq(f.config, original, "B5 missing/stale startup evidence preserves migration intent")
                r.eq(f.state.validationFailure, .validationRequired, "B5 missing/stale startup requires explicit validation")
            }
        }
        for entry in ["import", "select"] {
            let f = ActivationFixture()
            do {
                let old = try await f.activate()
                let original = f.config
                await f.trial.configure(text: "  ")
                do {
                    if entry == "import" { try await f.state.importOfflineModel(at: f.model.directory) }
                    else { try await f.state.useImportedModel(f.model) }
                    r.check(false, "B5 legacy \(entry) cannot select load-only candidate")
                } catch { }
                r.eq(f.state.activeLease, old, "B5 legacy \(entry) trial failure preserves runtime")
                r.eq(f.config, original, "B5 legacy \(entry) trial failure preserves selection")
                r.eq(f.samplesRequested, 1, "B5 legacy \(entry) obtains injected offline sample")
            } catch { r.check(false, "B5 legacy fixture: \(error)") }
        }
    }

    @MainActor static func testGenerationBeforeAllocation(_ r: SelfTest.Reporter) async {
        for mutation in ["selection", "library"] {
            let f = ActivationFixture()
            f.inspection.gate.block()
            let task = Task { try await f.activate() }
            while !f.inspection.gate.entered { await Task.yield() }
            if mutation == "selection" { f.config.selectedLocalModelID = ModelPreset.qwen317B.id }
            else { f.config.importedASRModels.removeAll() }
            let edited = f.config
            f.inspection.gate.release()
            _ = try? await task.value
            r.eq(f.loads, 0, "B5 \(mutation) changed during inspection rejects before allocation")
            r.eq(f.config, edited, "B5 \(mutation) changed during inspection preserves config")
        }
    }

    @MainActor static func testAuthoritativePresetRestore(_ r: SelfTest.Reporter) async {
        for mode in ["selected", "missing", "unknown"] {
            let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("B5-preset-restore-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                for preset in [ModelPreset.qwen306B, .qwen317B] {
                    let directory = root.appendingPathComponent(preset.id)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONSerialization.data(withJSONObject: ["_name_or_path": preset.repoId]).write(to: directory.appendingPathComponent("config.json"))
                    try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
                    let weights = directory.appendingPathComponent("fixture.safetensors")
                    FileManager.default.createFile(atPath: weights.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: weights)
                    try handle.truncate(atOffset: UInt64(ModelLocator.minValidBytes(for: preset)))
                    try handle.close()
                }
                let directory = root.appendingPathComponent(ModelPreset.qwen306B.id)
                let model = NativeActivationFixtures.model(directory)
                var config = Configuration()
                config.hasCompletedOnboarding = true
                config.asrRoutingPolicy = .localOnly
                config.setASRBackendSelection(.init(primary: .init(rawValue: "native:preset:" +
                    (mode == "unknown" ? "unknown-preset" : ModelPreset.qwen306B.id)), fallback: nil, allowsCloudFallback: false))
                config.importedASRModels = [model]
                config.installedASRModels = [.init(id: UUID(), importedModelID: model.id, ownership: .external,
                    installPlan: nil, directory: directory, validation: try NativeActivationFixtures.validation(model))]
                if mode == "missing" { try FileManager.default.removeItem(at: directory) }
                var attempts: [String] = []
                var locatorCalls = 0
                var networkCalls = 0
                let state = QwenModelState(preflight: { _, _ in await MainActor.run { networkCalls += 1 } },
                    load: { target, offline, _ in
                        guard case .offline(let resolved) = target else { throw ModelProvisionError.incompleteLocal() }
                        let preset = ModelPreset.allPresets.first { $0.repoId == resolved.modelId }!
                        await MainActor.run { attempts.append(preset.id); if !offline { networkCalls += 1 } }
                        return LocalASRLease(id: UUID(), identity: .init(id: preset.id, displayName: preset.name,
                            engine: "qwen", repoID: preset.repoId, directory: resolved.directory), provider: NativeActivationFixtures.Provider())
                    }, configuration: { config }, localModel: { source in
                        // Deterministically model a hardware preference for 1.7B; the real
                        // locator must receive an explicit captured selection to override it.
                        MainActor.assumeIsolated { locatorCalls += 1 }
                        var lookup = source
                        if lookup.selectedLocalModelID == nil { lookup.selectedLocalModelID = ModelPreset.qwen317B.id }
                        return ModelLocator.resolveActiveModel(config: lookup, knownCacheDirectories: [],
                            presetDirectory: { root.appendingPathComponent($0.id) })
                    }, environment: .init(read: { nil }, write: { _ in }), inspect: { NativeActivationFixtures.model($0) },
                    assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: nil) },
                    persistActivation: { config = $0 })
                await state.loadModel()
                r.eq(networkCalls, 0, "B5 authoritative startup never downloads")
                if mode == "selected" {
                    r.eq(attempts, [ModelPreset.qwen306B.id], "B5 startup restores actual validated automatic fallback with both presets installed")
                    r.eq(state.activeLease?.identity.id, ModelPreset.qwen306B.id, "B5 startup keeps native:preset identity")
                    r.eq(config.selectedLocalModelID, nil, "B5 restoring automatic fallback does not pin manual intent")
                } else {
                    r.eq(attempts, [], "B5 unavailable authoritative preset never guesses another installed model")
                    r.eq(state.failure, .incompleteLocal(), "B5 unavailable authoritative preset reports recovery")
                    if mode == "unknown" { r.eq(locatorCalls, 0, "B5 unknown authoritative preset never falls through to automatic locator") }
                }
            } catch { r.check(false, "B5 authoritative preset fixture: \(error)") }
        }
    }

    @MainActor static func testCompletionBelongsToItsOperation(_ r: SelfTest.Reporter) async {
        let f = ActivationFixture()
        await f.trial.configure(text: " ")
        f.loadGate.configure(blockFrom: 2)
        var armed = false
        var followup: Task<LocalASRLease, Error>?
        let observation = f.state.$operationID.sink { id in
            if id != nil { armed = true }
            else if armed, followup == nil { followup = Task { try await f.activate() } }
        }
        do { _ = try await f.activate(); r.check(false, "B5 empty operation throws its own error") }
        catch {
            r.eq(error as? NativeASRActivationError, .emptyResult,
                 "B5 later operation cannot overwrite previous caller's completion")
        }
        observation.cancel()
        while !f.loadGate.pending { await Task.yield() }
        f.loadGate.release()
        _ = try? await followup?.value
        r.eq(f.loads, 2, "B5 completion race exercised later operation before earlier caller resumed")
    }

    @MainActor static func testSelectionWhileWaitingForGate(_ r: SelfTest.Reporter) async {
        let first = ActivationFixture()
        let waiting = ActivationFixture()
        await first.trial.configure(blocked: true)
        let owner = Task { try await first.activate() }
        while await first.trial.calls == 0 { await Task.yield() }
        let queued = Task { try await waiting.activate() }
        while waiting.state.operationID == nil { await Task.yield() }
        r.eq(waiting.loads, 0, "B5 shared source gate serializes candidate lifecycles")
        waiting.config.selectedLocalModelID = ModelPreset.qwen317B.id
        let edited = waiting.config
        await first.trial.release()
        _ = try? await owner.value
        do { _ = try await queued.value; r.check(false, "B5 selection changed while queued rejects old activation") }
        catch { r.check(true, "B5 selection changed while queued rejects old activation") }
        r.eq(waiting.config, edited, "B5 reservation captures selection before waiting for source gate")
        r.eq(waiting.state.activeLease, nil, "B5 queued stale activation never becomes active")
    }

    @MainActor static func testNativeProviderDrain(_ r: SelfTest.Reporter) async {
        let f = ActivationFixture(engine: .whisperCoreML)
        let backend = ActivationWhisperBackend()
        let identity = LocalModelIdentity(id: f.model.id.uuidString, displayName: "Whisper fixture",
            engine: f.model.engine.rawValue, repoID: nil, directory: f.model.directory)
        let provider = WhisperASRProvider(identity: identity, backend: backend)
        var loads = 0
        let state = QwenModelState(load: { _, offline, _ in
            await MainActor.run { loads += 1 }
            return LocalASRLease(id: UUID(), identity: identity, provider: provider,
                engineVersion: f.inspection.engineVersion(), drain: { await provider.drainInference() })
        }, configuration: { f.config }, environment: .init(read: { nil }, write: { _ in }),
            inspect: { [inspection = f.inspection] _ in inspection.inspect() },
            assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: nil) },
            persistActivation: { f.config = $0 }, engineVersion: { [inspection = f.inspection] _ in inspection.engineVersion() })
        let coordinator = NativeASRActivationCoordinator(state: state)
        let task = Task { try await coordinator.activate(modelID: f.model.id, sample: NativeActivationFixtures.sample()) }
        while await backend.calls == 0 { await Task.yield() }
        task.cancel()
        // Wait until cancellation has propagated through the actual provider continuation.
        for _ in 0..<100 { await Task.yield() }
        r.check(state.operationID != nil, "B5 native Whisper compute outlives cancelled caller but retains lifecycle")
        let next = Task { try await coordinator.activate(modelID: f.model.id, sample: NativeActivationFixtures.sample()) }
        for _ in 0..<100 { await Task.yield() }
        r.eq(loads, 1, "B5 real Whisper queue drain prevents second allocation")
        next.cancel()
        await backend.release()
        _ = try? await task.value
        _ = try? await next.value
        r.eq(state.operationID, nil, "B5 native compute drain releases lifecycle")
        r.eq(state.activeLease, nil, "B5 cancelled native result never becomes active")
    }
}

private final class ActivationInspectionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var started = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func block() { condition.lock(); blocked = true; condition.unlock() }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        guard blocked else { return }
        started = true
        let deadline = Date().addingTimeInterval(5)
        while blocked { if !condition.wait(until: deadline) { break } }
    }
    func release() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
}

private final class ActivationLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blockFrom: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { lock.withLock { continuation != nil } }
    func configure(blockFrom: Int) { lock.withLock { self.blockFrom = blockFrom } }
    func wait(count: Int) async {
        await withCheckedContinuation { callback in
            lock.withLock {
                if let blockFrom, count >= blockFrom { continuation = callback }
                else { callback.resume() }
            }
        }
    }
    func release() {
        let callback = lock.withLock {
            let result = continuation; continuation = nil; blockFrom = nil; return result
        }
        callback?.resume()
    }
}

private actor ActivationWhisperBackend: OfflineWhisperBackend {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func transcribe(samples: [Float], language: String?, prompt: String?) async throws -> [String] {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return ["late native result"]
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ActivationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 100)
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var requested: Duration?
    var pending: Int { lock.withLock { sleepers.count } }
    var requestedDuration: Duration? { lock.withLock { requested } }
    func now() -> Date { lock.withLock { value } }
    func advance(seconds: TimeInterval) {
        let callbacks = lock.withLock {
            value.addTimeInterval(seconds)
            let result = Array(sleepers.values); sleepers.removeAll(); return result
        }
        for callback in callbacks { callback.resume() }
    }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { requested = duration; sleepers[id] = continuation }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

/// Shared only by synthetic native lifecycle fixtures, never production runtime selection.
enum NativeActivationFixtures {
    static func sample() throws -> ASRValidationSample {
        try .init(samples: [0, 0.25, -0.25], sampleRate: 16_000, label: "synthetic native fixture")
    }
    struct Provider: ASRProvider {
        let id = ASRProviderID.local
        let displayName = "Native fixture"
        let capabilities = ASRCapabilities(supportsLanguageHint: true, supportsContextHint: true,
            requiresNetwork: false, location: .onDevice)
        var isAvailable: Bool { get async { true } }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            .init(text: "fixture recognized", providerID: id, latencyMs: 1)
        }
    }
    static func model(_ directory: URL) -> ImportedASRModel {
        .init(name: directory.lastPathComponent, directory: directory, engine: .qwenMLX,
              variant: directory.path.contains("1.7") ? "1.7B" : "0.6B", bits: 4,
              sizeBytes: 1024, fileFingerprint: "fixture")
    }
    static func validation(_ model: ImportedASRModel) throws -> ASRNativeValidationRecord {
        .init(fileFingerprint: model.fileFingerprint, engineVersion: LocalASRRuntimeFactory.engineVersion(for: model.engine),
              sampleSHA256: try sample().sha256, validatedAt: Date(timeIntervalSince1970: 1), latencyMs: 1)
    }
    final class Inspections: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [URL: ImportedASRModel] = [:]
        func remember(_ lease: LocalASRLease) { lock.withLock { loaded[lease.identity.directory] = NativeActivationFixtures.model(lease.identity.directory) } }
        func model(at directory: URL) -> ImportedASRModel? { lock.withLock { loaded[directory] } }
    }
}
