import Foundation
import CoreML
import WhisperKit

/// Actual runtime path resolution and coordinator lifecycle; replace only expensive native work.
enum M2ReviewFixSelfTests {
    static let names = ["MelSpectrogram", "AudioEncoder", "TextDecoder", "TextDecoderContextPrefill"]

    static func packages(_ r: SelfTest.Reporter) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-preparation-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // A conventional root, a legal alternate Manifest root, a compiled component,
            // and source prefill exercise the exact directories the pinned runtime resolves.
            for (index, name) in names.enumerated() {
                if index == 2 {
                    let compiled = root.appendingPathComponent(name + ".mlmodelc")
                    try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
                    try Data("compiled".utf8).write(to: compiled.appendingPathComponent("coremldata.bin"))
                } else {
                    let path = index == 0 ? "com.apple.CoreML/model.mlmodel" : "custom/root.mlmodel"
                    try makePackage(root.appendingPathComponent(name + ".mlpackage"), modelPath: path)
                }
            }
            var prepared: PreparedWhisperModels? = try await WhisperModelPreparation.prepare(directory: root, compile: fixtureCompile)
            let generated = prepared!.directory
            for name in names {
                let actual = ModelUtilities.detectModelURL(inFolder: generated, named: name)
                r.eq(actual.pathExtension, "mlmodelc", "package preparation supplies compiled \(name)")
                r.check(FileManager.default.fileExists(atPath: actual.appendingPathComponent("coremldata.bin").path),
                        "pinned runtime resolves existing compiled \(name)")
            }
            r.check(generated != root, "mixed source package runtime owns a separate directory")
            var retained = prepared
            prepared = nil
            r.check(FileManager.default.fileExists(atPath: generated.path), "retained preparation owner keeps generated resources alive")
            withExtendedLifetime(retained) {}
            retained = nil
            r.check(!FileManager.default.fileExists(atPath: generated.path), "last preparation owner releases generated runtime files")
            r.check(FileManager.default.fileExists(atPath: root.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin").path), "cleanup preserves caller compiled component")
            r.check(FileManager.default.fileExists(atPath: root.appendingPathComponent("AudioEncoder.mlpackage/Data/custom/root.mlmodel").path), "cleanup preserves alternate source root")
        } catch { r.check(false, "Whisper package preparation: \(error)") }
        await packageFailures(r)
    }

    static func makePackage(_ package: URL, modelPath: String) throws {
        let model = package.appendingPathComponent("Data/" + modelPath)
        let weights = package.appendingPathComponent("Data/resources/weights.bin")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: model)
        try Data([4, 5, 6]).write(to: weights)
        let entries: [String: Any] = ["root": ["path": modelPath, "name": "model.mlmodel", "author": "com.apple.CoreML", "description": "CoreML fixture resource"],
                                      "weights": ["path": "resources/weights.bin", "name": "weights", "author": "com.apple.CoreML", "description": "CoreML fixture resource"]]
        let manifest: [String: Any] = ["fileFormatVersion": "1.0.0", "rootModelIdentifier": "root", "itemInfoEntries": entries]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("Manifest.json"))
    }

    static func fixtureCompile(_ source: URL, _ destination: URL) throws {
        guard source.pathExtension == "mlpackage", !Thread.isMainThread,
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("Manifest.json"))) as? [String: Any],
              let id = manifest["rootModelIdentifier"] as? String,
              let entries = manifest["itemInfoEntries"] as? [String: [String: Any]],
              let path = entries[id]?["path"] as? String,
              try Data(contentsOf: source.appendingPathComponent("Data/" + path)) == Data([1, 2, 3]),
              try Data(contentsOf: source.appendingPathComponent("Data/resources/weights.bin")) == Data([4, 5, 6]) else {
            throw OfflineWhisperError.invalidLocalDirectory
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: destination.appendingPathComponent("coremldata.bin"))
    }
}

/// A synchronous worker deliberately ignores task cancellation, like filesystem validation
/// or native compilation. A timeout makes a MainActor regression fail instead of deadlock.
private final class ReviewBlockingWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var timedOut = false
    private var ranOnMain = false
    func block() {
        condition.lock()
        entered = true; ranOnMain = Thread.isMainThread
        let deadline = Date().addingTimeInterval(2)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; break }
        }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    var started: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var missedHeartbeat: Bool { condition.lock(); defer { condition.unlock() }; return timedOut || ranOnMain }
}

private actor ReviewBackend: OfflineWhisperBackend {
    func transcribe(samples: [Float], language: String?, prompt: String?) async throws -> [String] { ["retained"] }
}

private actor ReviewLoads {
    var count = 0
    func load(_ target: ModelProvisionTarget) -> LocalASRLease {
        count += 1
        let identity: LocalModelIdentity
        if case .imported(let model) = target {
            identity = .init(id: model.id.uuidString, displayName: model.name, engine: model.engine.rawValue, repoID: nil, directory: model.directory)
        } else {
            identity = .init(id: "old", displayName: "old", engine: "whisperCoreML", repoID: nil, directory: URL(fileURLWithPath: "/old"))
        }
        return LocalASRLease(id: UUID(), identity: identity, provider: WhisperASRProvider(identity: identity, backend: ReviewBackend()))
    }
}

extension M2ReviewFixSelfTests {
    @MainActor
    static func inspection(_ r: SelfTest.Reporter) async {
        for mode in ["selection", "startup", "legacy", "retry"] {
            let blocked = ReviewBlockingWorker()
            let io = ReviewLoads()
            let model = ImportedASRModel(name: "new", directory: URL(fileURLWithPath: "/fixture/new"), engine: .whisperCoreML,
                variant: "unverified", bits: nil, sizeBytes: 123, tokenizerDirectory: URL(fileURLWithPath: "/fixture/new/tokenizer"), fileFingerprint: "fresh")
            var config = Configuration()
            var saves = 0
            let state = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in await io.load(target) },
                configuration: { config }, localModel: { _ in nil }, availableDisk: { _ in .max },
                environment: .init(read: { nil }, write: { _ in }), inspect: { _ in blocked.block(); return model },
                assessHardware: { model, _ in .assess(model: model, physicalMemory: 32 * 1_073_741_824,
                    availableMemory: 16 * 1_073_741_824, activeModelBytes: nil, isAppleSilicon: true) },
                saveConfiguration: { config = $0; saves += 1 })
            if mode != "startup" { await state.selectPreset(.qwen306B) }
            let previous = state.activeLease
            let captured = previous // A retained capture survives cancellation of a replacement.
            if mode == "startup" { config.importedASRModels = [model]; config.activeImportedASRModelID = model.id }
            if mode == "retry" { config.customLocalModelPath = model.directory.path }
            let before = config
            let initialSaves = saves
            let initialLoads = await io.count
            let operation = Task {
                switch mode {
                case "startup": await state.loadModel()
                case "legacy": try? await state.importOfflineModel(at: model.directory)
                case "retry": await state.retryConfiguredModel()
                default: try? await state.useImportedModel(model)
                }
            }
            let deadline = Date().addingTimeInterval(4)
            while !blocked.started && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            r.check(blocked.started && !blocked.missedHeartbeat, "\(mode): main actor heartbeat runs while synchronous inspection is blocked")
            let otherIO = ReviewLoads()
            let other = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in await otherIO.load(target) },
                configuration: { Configuration() }, localModel: { _ in nil }, availableDisk: { _ in .max },
                environment: .init(read: { nil }, write: { _ in }))
            let waiting = Task { await other.selectPreset(.qwen306B) }
            while other.operationID == nil { await Task.yield() }
            r.eq(await otherIO.count, 0, "\(mode): other coordinator waits behind global inspection gate")
            let reservation = state.operationID
            r.check(reservation != nil, "\(mode): inspection already owns operation reservation")
            state.cancel()
            await state.perform(.init(target: .preset(.qwen317B), source: .official, origin: .manual))
            r.eq(state.operationID, reservation, "\(mode): cancel retains reservation and rejects concurrent replacement until inspection drains")
            blocked.release()
            await operation.value
            await waiting.value
            r.eq(await otherIO.count, 1, "\(mode): drained inspection releases global gate to waiting coordinator")
            r.eq(await io.count, initialLoads, "\(mode): cancelled inspection never starts runtime or competing operation")
            r.eq(saves, initialSaves, "\(mode): cancelled inspection never saves")
            r.eq(config, before, "\(mode): cancelled inspection preserves configuration")
            r.eq(state.activeLease, previous, "\(mode): cancelled inspection preserves active lease")
            r.eq(state.operationID, nil, "\(mode): drained inspection releases reservation")
            if let captured {
                do {
                    let output = try await captured.provider.transcribe(ASRRequest(samples: [0], sampleRate: 16000, language: nil, context: nil, timeout: 1))
                    r.eq(output.text, "retained", "\(mode): captured previous provider remains usable")
                } catch { r.check(false, "\(mode): captured provider: \(error)") }
            }
        }
    }
}

private final class ReviewRuntimePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func record(_ path: URL) { lock.withLock { values.append(path) } }
    var paths: [URL] { lock.withLock { values } }
}

extension M2ReviewFixSelfTests {
    static func packageFailures(_ r: SelfTest.Reporter) async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flowtype-preparation-failures-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for name in names.prefix(3) { try makePackage(root.appendingPathComponent(name + ".mlpackage"), modelPath: "custom/model.mlmodel") }
            let failed = ReviewRuntimePaths()
            do {
                _ = try await WhisperModelPreparation.prepare(directory: root) { source, destination in
                    failed.record(destination.deletingLastPathComponent())
                    try fixtureCompile(source, destination)
                    if source.lastPathComponent == "AudioEncoder.mlpackage" { throw OfflineWhisperError.incompatibleGraph }
                }
                r.check(false, "compiler failure propagates")
            } catch { r.check(error is OfflineWhisperError, "compiler failure propagates") }
            r.eq(failed.paths.count, 2, "compiler failure stops before remaining components")
            r.check(failed.paths.allSatisfy { !fm.fileExists(atPath: $0.path) }, "compiler failure cleans partially compiled runtime")

            let cancelled = ReviewRuntimePaths()
            let blocked = ReviewBlockingWorker()
            let task = Task {
                try await WhisperModelPreparation.prepare(directory: root) { source, destination in
                    cancelled.record(destination.deletingLastPathComponent())
                    try fixtureCompile(source, destination)
                    blocked.block()
                }
            }
            let deadline = Date().addingTimeInterval(4)
            while !blocked.started && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            r.check(blocked.started && !blocked.missedHeartbeat, "compiler synchronous work runs off main")
            task.cancel()
            r.check(cancelled.paths.count == 1 && cancelled.paths.allSatisfy { fm.fileExists(atPath: $0.path) },
                    "cancellation retains runtime directory until native compiler drains")
            blocked.release()
            do { _ = try await task.value; r.check(false, "cancelled compilation cannot return runtime") }
            catch { r.check(error is CancellationError, "cancelled compilation cannot return runtime") }
            r.eq(cancelled.paths.count, 1, "cancellation skips later compilation components")
            r.check(cancelled.paths.allSatisfy { !fm.fileExists(atPath: $0.path) }, "drained cancelled compilation cleans generated resources")
            r.check(fm.fileExists(atPath: root.appendingPathComponent("MelSpectrogram.mlpackage/Data/custom/model.mlmodel").path),
                    "failure and cancellation preserve caller source package")

            // A separate fully compiled fixture must not call the compiler or stage copies.
            let compiled = root.appendingPathComponent("compiled-only")
            for name in names.prefix(3) {
                try fm.createDirectory(at: compiled.appendingPathComponent(name + ".mlmodelc"), withIntermediateDirectories: true)
            }
            var direct: PreparedWhisperModels? = try await WhisperModelPreparation.prepare(directory: compiled) { _, _ in
                throw OfflineWhisperError.incompatibleGraph
            }
            r.eq(direct?.directory, compiled, "fully compiled imports bypass compilation and staging")
            direct = nil
            r.check(fm.fileExists(atPath: compiled.appendingPathComponent("AudioEncoder.mlmodelc").path), "fully compiled release never deletes original data")
        } catch { r.check(false, "Whisper package failure/fastpath fixtures: \(error)") }
    }
}

extension M2ReviewFixSelfTests {
    @MainActor
    static func compilationLifecycle(_ r: SelfTest.Reporter) async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flowtype-compilation-lifecycle-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for name in names.prefix(3) { try makePackage(root.appendingPathComponent(name + ".mlpackage"), modelPath: "custom/model.mlmodel") }
            let model = ImportedASRModel(name: "source", directory: root, engine: .whisperCoreML,
                variant: "unverified", bits: nil, sizeBytes: 123, tokenizerDirectory: root, fileFingerprint: "fresh")
            let blocked = ReviewBlockingWorker()
            let paths = ReviewRuntimePaths()
            let io = ReviewLoads()
            var config = Configuration()
            var saves = 0
            let state = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in
                if case .imported = target {
                    let resources = try await WhisperModelPreparation.prepare(directory: root) { source, destination in
                        paths.record(destination.deletingLastPathComponent())
                        try fixtureCompile(source, destination)
                        blocked.block()
                    }
                    // Keep preparation alive across the same loader boundary as production.
                    let lease = await io.load(target)
                    withExtendedLifetime(resources) {}
                    return lease
                }
                return await io.load(target)
            }, configuration: { config }, localModel: { _ in nil }, availableDisk: { _ in .max },
                environment: .init(read: { nil }, write: { _ in }), inspect: { _ in model },
                assessHardware: { model, _ in .assess(model: model, physicalMemory: 32 * 1_073_741_824,
                    availableMemory: 16 * 1_073_741_824, activeModelBytes: nil, isAppleSilicon: true) },
                saveConfiguration: { config = $0; saves += 1 })
            await state.selectPreset(.qwen306B)
            let old = state.activeLease
            let before = config
            let operation = Task { try? await state.useImportedModel(model) }
            let deadline = Date().addingTimeInterval(4)
            while !blocked.started && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            r.check(blocked.started && !blocked.missedHeartbeat, "coordinator remains responsive during synchronous native compilation")
            state.cancel()
            let otherIO = ReviewLoads()
            let other = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in await otherIO.load(target) },
                configuration: { Configuration() }, localModel: { _ in nil }, availableDisk: { _ in .max },
                environment: .init(read: { nil }, write: { _ in }))
            let waiting = Task { await other.selectPreset(.qwen306B) }
            while other.operationID == nil { await Task.yield() }
            r.check(state.operationID != nil, "cancelled native compilation keeps coordinator reservation")
            r.eq(await otherIO.count, 0, "cancelled native compilation keeps global gate until native work drains")
            r.check(paths.paths.count == 1 && paths.paths.allSatisfy { fm.fileExists(atPath: $0.path) }, "in-flight native work retains its generated resources")
            blocked.release()
            await operation.value
            await waiting.value
            r.eq(await otherIO.count, 1, "drained compilation releases global gate")
            r.eq(await io.count, 1, "late cancelled compilation never publishes a loaded candidate")
            r.eq(saves, 1, "cancelled compilation never commits selection")
            r.eq(config, before, "cancelled compilation preserves prior configuration")
            r.eq(state.activeLease, old, "cancelled compilation preserves prior active lease")
            r.check(paths.paths.allSatisfy { !fm.fileExists(atPath: $0.path) }, "cancelled coordinator compilation cleans owned files after draining")
        } catch { r.check(false, "native compilation lifecycle fixture: \(error)") }
    }
}
