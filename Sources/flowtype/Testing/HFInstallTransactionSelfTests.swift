import Foundation
import CryptoKit
import os
import Darwin

/// Real journals, hashes, static inspection and rename; injected byte source only.
enum HFInstallTransactionSelfTests {
    @MainActor static func testDeleteWhileOldSessionOwnsLease(_ r: SelfTest.Reporter) async {
        let registry = NativeModelUsageRegistry(), id = UUID()
        do {
            var token: ModelUsageToken? = try registry.acquire(modelID: id)
            r.check(token != nil, "B6 old session retains usage token")
            r.check((try? registry.reserveDeletion(modelID: id)) == nil, "B6 captured lease blocks deletion")
            token = nil
            var permit: ModelDeletionPermit? = try registry.reserveDeletion(modelID: id)
            r.check(permit != nil, "B6 released session permits deletion")
            r.check((try? registry.acquire(modelID: id)) == nil, "B6 deletion reservation blocks new acquire")
            permit = nil
            r.check((try? registry.acquire(modelID: id)) != nil, "B6 released permit permits acquire")
        } catch { r.check(false, "B6 usage registry: \(error)") }
    }

    @MainActor static func testExternalAndAliasProtection(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), usage = NativeModelUsageRegistry()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = Source(f.bytes); await source.release()
        let coordinator = ModelInstallationCoordinator(transport: { file, url, credential, progress in
            try await source.transfer(file, url, credential, progress)
        }, publisher: f.publisher(library), diskSample: { _ in Int64.max }, journalRoot: f.jobs,
           usageRegistry: usage, configuration: { library.config }, persistRemoval: { library.config = $0 })
        do {
            let job = try await coordinator.enqueue(f.plan)
            _ = await until { await coordinator.snapshots().first?.state == .installed }
            guard let record = library.config.installedASRModels.first else { r.check(false, "B6 fixture installed"); return }
            r.check(record.id == job && record.importedModelID != job, "B6 deletion identity is imported UUID")
            var token: ModelUsageToken? = try usage.acquire(modelID: record.importedModelID)
            do { try await coordinator.remove(modelID: record.importedModelID, deleteManagedFiles: true); r.check(false, "B6 used model removal rejected") }
            catch { r.check(true, "B6 used model removal rejected") }
            r.check(token != nil && FileManager.default.fileExists(atPath: record.directory.path), "B6 occupied bytes preserved")
            token = nil
            try await coordinator.remove(modelID: record.importedModelID, deleteManagedFiles: false)
            r.check(library.config.importedASRModels.isEmpty, "B6 detached library record removed")
            r.check(FileManager.default.fileExists(atPath: record.directory.path), "B6 retain files option")
            _ = try await coordinator.recover()
            r.check(library.config.importedASRModels.isEmpty, "B6 detached recovery never resurrects")
            var model = try ASRModelInspector.inspect(directory: record.directory); model.id = UUID()
            library.config.importedASRModels = [model]
            library.config.installedASRModels = [.init(id: UUID(), importedModelID: model.id, ownership: .external, installPlan: nil, directory: model.directory, validation: nil)]
            do { try await coordinator.remove(modelID: model.id, deleteManagedFiles: true); r.check(false, "B6 external deletion rejected") }
            catch { r.check(true, "B6 external deletion rejected") }
            r.check(FileManager.default.fileExists(atPath: record.directory.path), "B6 external files are never owned")
        } catch { r.check(false, "B6 removal: \(error)") }
    }

    @MainActor static func testRemovalBoundaries(_ r: SelfTest.Reporter) async {
        for mode in ["delete", "alias", "caseAlias", "extraFile", "symlink", "forged", "forgedJournal", "detachFailure", "selected", "selectedLowercase", "wrongID"] {
            let f = Fixture(), library = Library(), source = Source(f.bytes)
            defer { try? FileManager.default.removeItem(at: f.root) }
            await source.release()
            let coordinator = ModelInstallationCoordinator(transport: { file, url, credential, progress in
                try await source.transfer(file, url, credential, progress)
            }, publisher: f.publisher(library), diskSample: { _ in Int64.max }, journalRoot: f.jobs,
               usageRegistry: NativeModelUsageRegistry(), configuration: { library.config }, persistRemoval: { library.config = $0 })
            do {
                _ = try await coordinator.enqueue(f.plan)
                _ = await until { await coordinator.snapshots().first?.state == .installed }
                guard let record = library.config.installedASRModels.first, let model = library.config.importedASRModels.first else {
                    r.check(false, "B6 removal fixture installed"); continue
                }
                if mode == "delete" {
                    r.eq(model.directory.path, record.directory.standardizedFileURL.resolvingSymlinksInPath().path, "B6 publisher canonical inspection directory")
                    r.check(record.id == record.installPlan?.id, "B6 managed plan identity")
                }
                var preservedDirectory = record.directory
                if mode == "caseAlias" {
                    let oldParent = record.directory.deletingLastPathComponent()
                    let alias = oldParent.deletingLastPathComponent().appendingPathComponent(oldParent.lastPathComponent.lowercased())
                    guard Darwin.rename(oldParent.path, alias.path) == 0 else { throw NativeModelUsageError.invalidOwnership }
                    preservedDirectory = alias.appendingPathComponent("model")
                }
                if mode == "extraFile" { try Data("user-owned addition".utf8).write(to: record.directory.appendingPathComponent("user-added.txt")) }
                if mode == "alias" {
                    var alias = model; alias.id = UUID(); alias.directory = URL(fileURLWithPath: model.directory.path.lowercased())
                    library.config.importedASRModels.append(alias)
                }
                if mode == "symlink" {
                    try FileManager.default.createSymbolicLink(at: record.directory.appendingPathComponent("outside"), withDestinationURL: f.root)
                }
                if mode == "forged" {
                    let url = record.directory.appendingPathComponent("installation-manifest.json")
                    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                    var forged = object["record"] as! [String: Any]; forged["importedModelID"] = UUID().uuidString; object["record"] = forged
                    try JSONSerialization.data(withJSONObject: object).write(to: url)
                }
                if mode == "forgedJournal" {
                    let url = f.jobs.appendingPathComponent(record.id.uuidString).appendingPathComponent("job.json")
                    try Data("{}".utf8).write(to: url)
                }
                if mode == "detachFailure" {
                    let url = f.jobs.appendingPathComponent(record.id.uuidString).appendingPathComponent("job.json")
                    try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                }
                if mode == "selected" || mode == "selectedLowercase" {
                    let value = mode == "selectedLowercase" ? model.id.uuidString.lowercased() : model.id.uuidString
                    library.config.asrBackendSelection = .init(primary: ASRBackendID(rawValue: "native:import:" + value))
                }
                let before = library.config
                do {
                    try await coordinator.remove(modelID: mode == "wrongID" ? record.id : model.id, deleteManagedFiles: mode != "detachFailure")
                    r.check(mode == "delete", "B6 removal succeeds only with full authority \(mode)")
                } catch { r.check(mode != "delete", "B6 removal rejects unsafe authority \(mode): \(error)") }
                if mode == "delete" {
                    r.check(!FileManager.default.fileExists(atPath: record.directory.path), "B6 owned inactive model files deleted")
                    _ = try await coordinator.recover()
                    r.check(library.config.importedASRModels.isEmpty, "B6 deleted entry never resurrects")
                } else {
                    r.eq(library.config, before, "B6 refused deletion preserves library \(mode)")
                    r.check(FileManager.default.fileExists(atPath: preservedDirectory.path), "B6 refused deletion preserves files \(mode)")
                }
            } catch { r.check(false, "B6 removal boundaries \(mode): \(error)") }
        }
    }

    @MainActor static func testLegacyAssociationRemoval(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library()
        let old = NativeActivationFixtures.model(f.root.appendingPathComponent("old"))
        let unrelated = NativeActivationFixtures.model(f.root.appendingPathComponent("unrelated"))
        var record = ASRInstalledModelRecord(id: UUID(), importedModelID: old.id, ownership: .external,
            installPlan: nil, directory: old.directory, validation: nil)
        do {
            let decoded = try JSONDecoder().decode(ASRInstalledModelRecord.self, from: JSONEncoder().encode(record))
            r.eq(decoded.legacyPresetID, nil, "B6 old record without preset association decodes")
            record.legacyPresetID = ModelPreset.qwen306B.id
            let associated = try JSONDecoder().decode(ASRInstalledModelRecord.self, from: JSONEncoder().encode(record))
            r.eq(associated.legacyPresetID, ModelPreset.qwen306B.id, "B6 exact legacy association persists")
            library.config.importedASRModels = [old, unrelated]; library.config.installedASRModels = [record]
            library.config.asrBackendSelection = .init(primary: .init(rawValue: "native:preset:" + ModelPreset.qwen306B.id))
            let coordinator = ModelInstallationCoordinator(transport: { _, _, _, _ in }, publisher: f.publisher(library),
                journalRoot: f.jobs, usageRegistry: NativeModelUsageRegistry(), configuration: { library.config }, persistRemoval: { library.config = $0 })
            try await coordinator.remove(modelID: unrelated.id, deleteManagedFiles: false)
            r.eq(library.config.importedASRModels.map(\.id), [old.id], "B6 unrelated same-family Qwen record can be removed")
            do { try await coordinator.remove(modelID: old.id, deleteManagedFiles: false); r.check(false, "B6 selected exact legacy association rejects removal") }
            catch { r.check(true, "B6 selected exact legacy association rejects removal") }
            library.config.setASRBackendSelection(.init())
            try await coordinator.remove(modelID: old.id, deleteManagedFiles: false)
            r.check(library.config.importedASRModels.isEmpty, "B6 explicit preset deselection permits associated record removal")
        } catch { r.check(false, "B6 legacy association: \(error)") }
    }

    @MainActor static func testPresetDeleteFacade(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library()
        let model = NativeActivationFixtures.model(f.root.appendingPathComponent("model"))
        let plan = ASRInstallPlan(id: f.plan.id, displayName: f.plan.displayName, engine: f.plan.engine, files: f.plan.files,
            totalBytes: f.plan.totalBytes, recipeID: ModelPreset.qwen306B.id, recipeVersion: 1, credentialID: nil)
        library.config.importedASRModels = [model]
        library.config.installedASRModels = [.init(id: plan.id, importedModelID: model.id, ownership: .managed,
            installPlan: plan, directory: model.directory, validation: nil)]
        var ids: [UUID] = [], flags: [Bool] = []
        var reject = false
        let state = QwenModelState(configuration: { library.config }, removeManagedRecord: { id, files in
            if reject { throw NativeModelUsageError.inUse }
            ids.append(id); flags.append(files)
        })
        let facade = ModelDownloader(coordinator: state, configuration: { library.config })
        do {
            try await facade.deleteModel(.qwen306B)
            r.eq(ids, [model.id], "B6 preset delete facade targets imported UUID, never job UUID")
            r.eq(flags, [true], "B6 preset delete facade requests guarded managed file removal")
            reject = true
            do { try await facade.deleteModel(.qwen306B); r.check(false, "B6 facade propagates in-use refusal") }
            catch { r.check(error as? NativeModelUsageError == .inUse, "B6 facade propagates in-use refusal") }
            library.config.installedASRModels.append(.init(id: UUID(), importedModelID: UUID(), ownership: .managed,
                installPlan: plan, directory: model.directory, validation: nil))
            do { try await facade.deleteModel(.qwen306B); r.check(false, "B6 facade rejects ambiguous managed preset") }
            catch { r.check(true, "B6 facade rejects ambiguous managed preset") }
            library.config.installedASRModels = []
            do { try await facade.deleteModel(.qwen306B); r.check(false, "B6 facade refuses external legacy preset deletion") }
            catch { r.check(true, "B6 facade refuses external legacy preset deletion") }
            r.eq(ids, [model.id], "B6 refusals never dispatch another delete")
        } catch { r.check(false, "B6 preset facade: \(error)") }
    }

    struct Fixture: Sendable {
        let root: URL
        let bytes: [String: Data]
        let plan: ASRInstallPlan
        init() {
            root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("B4-\(UUID())")
            let payloads = HFInstallPlannerSelfTests.graphs("").merging(HFInstallPlannerSelfTests.tokenizerData) { a, _ in a }
            bytes = payloads
            plan = ASRInstallPlan(id: UUID(), displayName: "Synthetic", engine: .whisperCoreML,
                files: payloads.keys.sorted().map { path in
                    let data = payloads[path]!
                    return HFPlannedFile(source: .init(repoID: "org/model", requestedRevision: "main", subdirectory: nil),
                        downloadEndpoint: URL(string: "https://captured.invalid")!, resolvedCommit: String(repeating: "a", count: 40),
                        remotePath: path, relativeDestination: path, sizeBytes: Int64(data.count),
                        digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
                }, totalBytes: Int64(payloads.values.reduce(0) { $0 + $1.count }), recipeID: nil, recipeVersion: 1, credentialID: "asr.hf.official")
        }
        var jobs: URL { root.appendingPathComponent("installation-jobs") }
        var models: URL { root.appendingPathComponent("installed") }
        func stage(_ plan: ASRInstallPlan? = nil) throws -> URL {
            let target = jobs.appendingPathComponent((plan ?? self.plan).id.uuidString).appendingPathComponent("model")
            for (path, data) in bytes {
                let url = target.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            return target
        }
        func publisher(_ library: Library, boundary: @escaping ModelInstallationPublisher.BoundaryHook = { _ in }) -> ModelInstallationPublisher {
            ModelInstallationPublisher(installedRoot: models, register: { record, model in try library.register(record, model) }, boundary: boundary)
        }
    }
    @MainActor final class Library {
        var config = Configuration.default
        var shouldFail = false
        func register(_ record: ASRInstalledModelRecord, _ model: ImportedASRModel) throws {
            if shouldFail { throw HFDownloadError(code: .diskFull) }
            config = try LocalModelLibrary.registering(record, model: model, in: config)
        }
    }
    actor Source {
        let bytes: [String: Data]
        var active = 0, maximum = 0, requests = 0
        var hold = true
        var entered = false
        var lateProgress: (@Sendable (Int64) -> Void)?
        var seenEndpoints: [URL] = [], seenCredentials: [String?] = []
        init(_ bytes: [String: Data]) { self.bytes = bytes }
        func transfer(_ file: HFPlannedFile, _ url: URL, _ credential: String?, _ progress: @escaping @Sendable (Int64) -> Void) async throws {
            active += 1; maximum = max(maximum, active); requests += 1
            seenEndpoints.append(file.downloadEndpoint); seenCredentials.append(credential); lateProgress = progress
            defer { active -= 1 }
            try Data(bytes[file.remotePath]!.prefix(1)).write(to: url)
            progress(1); entered = true
            // Deliberately resist cancellation until drain is explicitly released.
            while hold { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
            try bytes[file.remotePath]!.write(to: url)
            progress(file.sizeBytes)
        }
        func release() { hold = false }
        func emitLate() { lateProgress?(999999) }
    }
    static func coordinator(_ f: Fixture, _ library: Library, source: Source, disk: @escaping ModelInstallationCoordinator.DiskSample = { _ in Int64.max }) -> ModelInstallationCoordinator {
        ModelInstallationCoordinator(transport: { file, url, credential, progress in
            try await source.transfer(file, url, credential, progress)
        }, publisher: f.publisher(library), diskSample: disk, journalRoot: f.jobs)
    }
    @MainActor static func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
    static func run(_ r: SelfTest.Reporter) async {
        await testPlannerDirectorySpellingPublication(r)
        await testDeleteWhileOldSessionOwnsLease(r)
        await testExternalAndAliasProtection(r)
        await testRemovalBoundaries(r)
        await testLegacyAssociationRemoval(r)
        await testPresetDeleteFacade(r)
        await testPersistentQueueRecovery(r)
        await testPublishCrashBoundaries(r)
        await testCancelGenerationAndDiskAdmission(r)
        await testInvalidJournalAndRegistration(r)
        await testPublicationCancellation(r)
        await testPublicationRecoveryAndDetach(r)
        await testStrictInspectionAndRuntimeDiskFull(r)
        await testRegistrationRetryWithoutDownload(r)
        await testDurableProductionRegistration(r)
        await testFreshDiskAndUnsafePaths(r)
        await testPublisherRejectsExternalStaging(r)
        await testVerificationCancellationDrain(r)
        await testChunkVerificationCancellation(r)
        await testCommittedDiskAdmission(r)
        await testDelayedFileProgress(r)
    }
    // The real planner must reject aliases before transfer; accepted siblings must survive
    // byte verification, static inspection, exact inventory, atomic publication and registration.
    @MainActor static func testPlannerDirectorySpellingPublication(_ r: SelfTest.Reporter) async {
        let layouts: [(String, String, Bool)] = [
            ("weights/one.bin", "Weights/two.bin", false),
            ("resources/deep/one.bin", "Resources/other/two.bin", false),
            ("resources/deep/one.bin", "resources/Deep/two.bin", false),
            ("straße/one.bin", "STRASSE/two.bin", false),
            ("Café/one.bin", "CAFE\u{301}/two.bin", false),
            ("weights/one.bin", "weights/two.bin", true),
            ("resources/deep/one.bin", "resources/deep/two.bin", true),
            ("Café/one.bin", "Cafe\u{301}/two.bin", true)
        ]
        for (first, second, accepted) in layouts {
            for reversed in [false, true] {
                let f = Fixture(), library = Library()
                defer { try? FileManager.default.removeItem(at: f.root) }
                let paths = [first, second].map { "AudioEncoder.mlmodelc/" + $0 }
                var payloads = f.bytes
                payloads[paths[0]] = Data([21]); payloads[paths[1]] = Data([22])
                // Keep graph resource references exact: no planner remapping is allowed.
                payloads["AudioEncoder.mlmodelc/model.mil"] = Data("func main() { \"@model_path/\(first)\" \"@model_path/\(second)\" }".utf8)
                let bytes = payloads
                let orderedPaths = bytes.keys.sorted()
                let repository = HFResolvedRepository(selection: f.plan.files[0].source,
                    commit: HFInstallPlannerSelfTests.commit, downloadEndpoint: f.plan.files[0].downloadEndpoint,
                    files: (reversed ? Array(orderedPaths.reversed()) : orderedPaths).map { path in
                        .init(remotePath: path, sizeBytes: Int64(bytes[path]!.count),
                              digest: .sha256(SHA256.hash(data: bytes[path]!).map { String(format: "%02x", $0) }.joined()))
                    }, licenseURL: nil)
                let planner = ASRInstallPlanner(readMetadata: { file, _ in bytes[file.remotePath]! },
                    metadataContext: { _ in .init(credentialID: nil, receivedBytes: 0) })
                let source = Source(bytes); await source.release()
                let installer = coordinator(f, library, source: source)
                let label = "B directory spelling \(first) / \(second), reversed=\(reversed)"
                do {
                    let plan = try await planner.plan(repository: repository, variant: nil, tokenizer: nil)
                    r.check(accepted, label + " accepted only consistent directory spelling")
                    let job = try await installer.enqueue(plan)
                    let finished = await until {
                        let state = await installer.snapshots().first?.state
                        return state == .installed || state == .failed
                    }
                    r.check(finished, label + " installer completed")
                    // Drain any final task cleanup before the temporary root is removed.
                    if !accepted || !finished { await installer.cancel(jobID: job) }
                    if accepted {
                        r.eq(await installer.snapshots().first?.state, .installed, label + " published")
                        r.eq(await source.requests, plan.files.count, label + " transferred exact closure")
                        guard let record = library.config.installedASRModels.first else {
                            r.check(false, label + " registered installed record"); continue
                        }
                        r.eq(library.config.importedASRModels.count, 1, label + " registered imported model")
                        r.eq(record.installPlan, plan, label + " preserved exact plan")
                        for path in paths {
                            r.eq(try Data(contentsOf: record.directory.appendingPathComponent(path)), bytes[path], label + " retained sibling bytes")
                        }
                        try f.publisher(library).validateRemoval(record,
                            model: library.config.importedASRModels[0], configuration: library.config)
                        r.check(true, label + " preserved strict removal inventory")
                    }
                } catch {
                    r.check(!accepted && error as? ASRInstallPlanningError == .destinationCollision,
                            label + " preflight collision result: \(error)")
                }
                if !accepted {
                    r.eq(await source.requests, 0, label + " rejected before any transfer")
                    r.check(await installer.snapshots().isEmpty, label + " created no installation job")
                    r.check(library.config.installedASRModels.isEmpty, label + " registered no model")
                    r.check(!FileManager.default.fileExists(atPath: f.models.path), label + " published no files")
                }
            }
        }
    }
    // Break caught: two network owners, cancellation releasing a live writer, or recovery auto-networking.
    @MainActor static func testPersistentQueueRecovery(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), source = Source(f.bytes)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let c = coordinator(f, library, source: source)
            let first = try await c.enqueue(f.plan)
            var secondPlan = f.plan
            secondPlan = .init(id: UUID(), displayName: secondPlan.displayName, engine: secondPlan.engine, files: secondPlan.files,
                totalBytes: secondPlan.totalBytes, recipeID: nil, recipeVersion: 1, credentialID: secondPlan.credentialID)
            let second = try await c.enqueue(secondPlan)
            r.check(await until { await source.entered }, "B4 first transfer entered")
            r.eq(await source.maximum, 1, "B4 one active download owner")
            r.check(await until { await c.snapshots().first?.receivedBytes == 1 }, "B4 intermediate progress counts actual bytes")
            let stopping = Task { await c.pause(jobID: first) }
            _ = await until { await c.snapshots().first(where: { $0.jobID == first })?.state == .paused }
            r.eq(await source.requests, 1, "B4 queued job waits while cancelled transport drains")
            await source.release(); await stopping.value
            r.check(await until { await c.snapshots().first(where: { $0.jobID == second })?.state == .installed }, "B4 next queued job runs after drain")
            // Simulate process termination with a journal that still says downloading.
            let journalURL = f.jobs.appendingPathComponent(first.uuidString).appendingPathComponent("job.json")
            var interrupted = try JSONDecoder().decode(ModelInstallationJobJournal.self, from: Data(contentsOf: journalURL))
            interrupted.snapshot.state = .downloading
            try JSONEncoder().encode(interrupted).write(to: journalURL, options: .atomic)
            // Recover with a completely new coordinator/source.
            let newSource = Source(f.bytes)
            let recovered = coordinator(f, library, source: newSource)
            let snapshots = try await recovered.recover()
            r.eq(snapshots.first(where: { $0.jobID == first })?.state, .paused, "B4 restart requires explicit resume")
            r.eq(await newSource.requests, 0, "B4 recovery sends zero requests")
            await newSource.release(); try await recovered.resume(jobID: first)
            r.check(await until { await recovered.snapshots().first(where: { $0.jobID == first })?.state == .installed }, "B4 explicit resume installs")
            r.check(await newSource.seenEndpoints.allSatisfy { $0.absoluteString == "https://captured.invalid" }, "B4 resume uses captured source")
            r.check(await newSource.seenCredentials.allSatisfy { $0 == "asr.hf.official" }, "B4 resume uses captured credential ID")
            r.eq(library.config.activeImportedASRModelID, nil, "B4 install does not activate")
            r.eq(library.config.installedASRModels.count, 2, "B4 separate installs registered")
            r.eq(await recovered.snapshots().first(where: { $0.jobID == first })?.receivedBytes, f.plan.totalBytes, "B4 byte weighted progress")
        } catch { r.check(false, "B4 queue: \(error)") }
    }
    // Break caught: publishing before complete validation, registration-before-rename, or unstable imported identity.
    @MainActor static func testPublishCrashBoundaries(_ r: SelfTest.Reporter) async {
        for point in ModelInstallationPublisher.Boundary.allCases {
            let f = Fixture(), library = Library()
            defer { try? FileManager.default.removeItem(at: f.root) }
            do {
                let staging = try f.stage()
                let p = f.publisher(library, boundary: { if $0 == point { throw HFDownloadError(code: .network) } })
                do { _ = try await p.publish(plan: f.plan, staging: staging); r.check(false, "B4 crash injected") }
                catch { }
                let fresh = f.publisher(library)
                let one = try await fresh.publish(plan: f.plan, staging: staging)
                let two = try await fresh.publish(plan: f.plan, staging: staging)
                r.eq(one, two, "B4 crash \(point) publication idempotent")
                r.eq(library.config.installedASRModels.count, 1, "B4 crash \(point) one installation")
                r.eq(library.config.importedASRModels.count, 1, "B4 crash \(point) one imported model")
                r.check(one.id != one.importedModelID, "B4 install and imported IDs are distinct")
                r.check(!FileManager.default.fileExists(atPath: staging.path), "B4 atomic rename consumes staging")
                r.check(FileManager.default.fileExists(atPath: one.directory.appendingPathComponent("installation-manifest.json").path), "B4 published manifest retained")
            } catch { r.check(false, "B4 crash boundary \(point): \(error)") }
        }
        let f = Fixture(), library = Library()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let staging = try f.stage()
            try Data([0]).write(to: staging.appendingPathComponent("tokenizer.json"))
            do { _ = try await f.publisher(library).publish(plan: f.plan, staging: staging); r.check(false, "B4 corrupted hash rejected") }
            catch { r.eq(library.config.installedASRModels.count, 0, "B4 corrupt file cannot register") }
        } catch { r.check(false, "B4 corruption fixture: \(error)") }
    }
    // Break caught: stale callbacks publishing after cancel and admission failing to sample fresh remaining bytes.
    @MainActor static func testCancelGenerationAndDiskAdmission(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), source = Source(f.bytes)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let c = coordinator(f, library, source: source)
            let id = try await c.enqueue(f.plan)
            _ = await until { await source.entered }
            let cancelling = Task { await c.cancel(jobID: id) }
            _ = await until { await c.snapshots().first?.state == .cancelled }
            await source.release(); await cancelling.value; await source.emitLate()
            r.eq(await c.snapshots().first?.state, .cancelled, "B4 cancellation survives completion")
            r.eq(library.config.installedASRModels.count, 0, "B4 cancelled completion cannot publish")
            try await c.resume(jobID: id)
            r.check(await until { await c.snapshots().first?.state == .installed }, "B4 cancelled partial explicitly resumable")
        } catch { r.check(false, "B4 cancel: \(error)") }
        for available: Int64 in [0, 256 * 1024 * 1024] {
            let f = Fixture(), source = Source(f.bytes), library = Library()
            defer { try? FileManager.default.removeItem(at: f.root) }
            do { _ = try await coordinator(f, library, source: source, disk: { _ in available }).enqueue(f.plan); r.check(false, "B4 insufficient disk throws") }
            catch { r.eq((error as? HFDownloadError)?.code, .diskFull, "B4 insufficient disk admission") }
            r.eq(await source.requests, 0, "B4 disk admission before network")
        }
    }
    @MainActor static func testInvalidJournalAndRegistration(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), source = Source(f.bytes)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let c = coordinator(f, library, source: source)
            _ = try await c.enqueue(f.plan); _ = await until { await source.entered }
            let stopping = Task { await c.pause(jobID: f.plan.id) }; await Task.yield(); await source.release(); await stopping.value
            let broken = f.jobs.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("{bad".utf8).write(to: broken.appendingPathComponent("job.json"))
            let recovered = coordinator(f, library, source: Source(f.bytes))
            let snapshots = try await recovered.recover()
            r.eq(snapshots.count, 2, "B4 corrupt job isolated from valid job")
            r.check(snapshots.contains { $0.state == .failed && $0.errorCode == "invalidJournal" }, "B4 corrupt job visibly failed")
            do {
                try await recovered.markLibraryDetached(jobID: UUID(uuidString: broken.lastPathComponent)!)
                r.check(false, "B4 corrupt journal cannot authorize library removal")
            } catch { r.check(true, "B4 corrupt journal detachment fails") }
            r.eq(try Data(contentsOf: broken.appendingPathComponent("job.json")), Data("{bad".utf8), "B4 corrupt journal retained unchanged")
            let legacy = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
            r.eq(legacy.installedASRModels.count, 0, "B4 legacy configuration defaults empty")
        } catch { r.check(false, "B4 invalid journal: \(error)") }
    }

    actor Gate {
        var entered = false, open = false
        func wait() async {
            entered = true
            while !open { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        }
        func release() { open = true }
    }
    // Break caught: verification made uncancellable, or cancellation rolling back a completed rename.
    @MainActor static func testPublicationCancellation(_ r: SelfTest.Reporter) async {
        for point: ModelInstallationPublisher.Boundary in [.beforeManifest, .beforeRename, .afterRename] {
            let f = Fixture(), library = Library(), source = Source(f.bytes), gate = Gate()
            defer { try? FileManager.default.removeItem(at: f.root) }
            do {
                await source.release()
                let publisher = f.publisher(library, boundary: { if $0 == point { await gate.wait() } })
                let c = ModelInstallationCoordinator(transport: { file, url, credential, progress in
                    try await source.transfer(file, url, credential, progress)
                }, publisher: publisher, diskSample: { _ in Int64.max }, journalRoot: f.jobs)
                let id = try await c.enqueue(f.plan)
                r.check(await until { await gate.entered }, "B4 reached publication boundary \(point)")
                let stopping = Task { await c.cancel(jobID: id) }
                if point != .afterRename {
                    r.check(await until { await c.snapshots().first?.state == .cancelled }, "B4 precommit cancellation accepted")
                } else { await Task.yield() }
                await gate.release(); await stopping.value
                r.eq(await c.snapshots().first?.state, point == .afterRename ? .installed : .cancelled, "B4 cancellation commit boundary \(point)")
                r.eq(library.config.installedASRModels.count, point == .afterRename ? 1 : 0, "B4 registration follows commit \(point)")
                r.eq(FileManager.default.fileExists(atPath: publisher.directory(for: f.plan).path), point == .afterRename, "B4 precommit cancellation prevents rename")
            } catch { r.check(false, "B4 publication cancellation: \(error)") }
        }
    }
    // Break caught: recovery redownloads a committed install or detached records are resurrected.
    @MainActor static func testPublicationRecoveryAndDetach(_ r: SelfTest.Reporter) async {
        for point in ModelInstallationPublisher.Boundary.allCases {
            let f = Fixture(), library = Library(), source = Source(f.bytes)
            defer { try? FileManager.default.removeItem(at: f.root) }
            do {
                let staging = try f.stage()
                let journal = ModelInstallationJobJournal(version: 1, snapshot: .init(jobID: f.plan.id, plan: f.plan,
                    state: .verifying, receivedBytes: f.plan.totalBytes, errorCode: nil), createdAt: Date(), libraryDetached: false)
                let journalURL = staging.deletingLastPathComponent().appendingPathComponent("job.json")
                try JSONEncoder().encode(journal).write(to: journalURL)
                do { _ = try await f.publisher(library, boundary: { if $0 == point { throw HFDownloadError(code: .network) } }).publish(plan: f.plan, staging: staging) }
                catch { }
                let c = coordinator(f, library, source: source)
                let committed = ![ModelInstallationPublisher.Boundary.beforeManifest, .beforeRename].contains(point)
                for _ in 0..<2 {
                    let recovered = try await c.recover()
                    r.eq(recovered.first?.state, committed ? .installed : .paused, "B4 crash recovery state \(point)")
                }
                r.eq(await source.requests, 0, "B4 publication recovery never networks")
                r.eq(library.config.installedASRModels.count, committed ? 1 : 0, "B4 recovery registers once \(point)")
                if committed {
                    guard let model = library.config.importedASRModels.first else { continue }
                    let inspected = try ASRModelInspector.inspect(directory: model.directory)
                    r.eq(model.fileFingerprint, inspected.fileFingerprint, "B4 final path fingerprint is current")
                    try await c.markLibraryDetached(jobID: f.plan.id)
                    library.config.installedASRModels = []; library.config.importedASRModels = []
                    _ = try await c.recover()
                    r.eq(library.config.installedASRModels.count, 0, "B4 detached library stays removed")
                    r.check(FileManager.default.fileExists(atPath: model.directory.path), "B4 detach retains files")
                }
            } catch { r.check(false, "B4 publication recovery: \(error)") }
        }
    }
    // Break caught: hashes substitute for static compatibility, or diskFull alters selected model.
    @MainActor static func testStrictInspectionAndRuntimeDiskFull(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let staging = try f.stage()
            let invalid = Data("{}".utf8)
            try invalid.write(to: staging.appendingPathComponent("tokenizer.json"))
            let files = f.plan.files.map { file -> HFPlannedFile in
                guard file.relativeDestination == "tokenizer.json" else { return file }
                return .init(source: file.source, downloadEndpoint: file.downloadEndpoint, resolvedCommit: file.resolvedCommit,
                    remotePath: file.remotePath, relativeDestination: file.relativeDestination, sizeBytes: Int64(invalid.count),
                    digest: .sha256(SHA256.hash(data: invalid).map { String(format: "%02x", $0) }.joined()))
            }
            let plan = ASRInstallPlan(id: f.plan.id, displayName: "Invalid", engine: .whisperCoreML, files: files,
                totalBytes: files.reduce(0) { $0 + $1.sizeBytes }, recipeID: nil, recipeVersion: 1, credentialID: nil)
            do { _ = try await f.publisher(library).publish(plan: plan, staging: staging); r.check(false, "B4 invalid static layout rejected") }
            catch { r.check(error is ASRModelInspectionError, "B4 full static inspector required after valid hashes") }
            r.eq(library.config.installedASRModels.count, 0, "B4 unsupported static content cannot register")
        } catch { r.check(false, "B4 strict inspection fixture: \(error)") }
        for failure in [HFDownloadError(code: .diskFull), HFDownloadError(code: .rateLimit, retryAfter: 90, requiresPause: true)] {
            let full = Fixture(), selected = UUID()
            let calls = OSAllocatedUnfairLock(initialState: 0)
            defer { try? FileManager.default.removeItem(at: full.root) }
            library.config.activeImportedASRModelID = selected
            do {
                let c = ModelInstallationCoordinator(transport: { _, _, _, _ in
                    calls.withLock { $0 += 1 }; throw failure
                }, publisher: full.publisher(library), diskSample: { _ in Int64.max }, journalRoot: full.jobs)
                _ = try await c.enqueue(full.plan)
                let expected: ModelInstallState = failure.requiresPause ? .paused : .failed
                r.check(await until { await c.snapshots().first?.state == expected }, "B4 transport failure state \(failure.code)")
                r.eq(await c.snapshots().first?.errorCode, failure.code.rawValue, "B4 stable transport failure code")
                r.eq(library.config.activeImportedASRModelID, selected, "B4 transport failure preserves selection")
                r.eq(calls.withLock { $0 }, 1, "B4 paused rate limit does not retry automatically")
            } catch { r.check(false, "B4 runtime failure: \(error)") }
        }
    }

    // Break caught: a failed postrename registration causes a second payload download on resume.
    @MainActor static func testRegistrationRetryWithoutDownload(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), source = Source(f.bytes)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            library.shouldFail = true; await source.release()
            let c = coordinator(f, library, source: source)
            let id = try await c.enqueue(f.plan)
            r.check(await until { await c.snapshots().first?.state == .failed }, "B4 registration error fails honestly")
            let before = await source.requests
            library.shouldFail = false
            try await c.resume(jobID: id)
            r.check(await until { await c.snapshots().first?.state == .installed }, "B4 registration retry completes")
            r.eq(await source.requests, before, "B4 committed registration retry performs zero downloads")
            r.eq(library.config.installedASRModels.count, 1, "B4 registration retry one record")
        } catch { r.check(false, "B4 registration retry: \(error)") }
    }
    @MainActor static func testDurableProductionRegistration(_ r: SelfTest.Reporter) async {
        let f = Fixture(), suite = "B4-store-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let fail = OSAllocatedUnfairLock(initialState: true)
        let credentials = KeychainASRCredentialStore(access: CredentialFixture().access)
        let keychain = KeychainAccess(save: { _, _ in true }, load: { _ in nil }, delete: { _ in })
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: f.root) }
        let store = ConfigurationStore(defaults: defaults, backupDirectory: f.root, keychain: keychain, asrCredentials: credentials,
            persistence: { data in
                if fail.withLock({ $0 }) { throw ASRCredentialError.persistence }
                defaults.set(data, forKey: "flowtype.config")
            })
        let active = UUID(); store.current.activeImportedASRModelID = active
        do {
            let originalStaging = try f.stage()
            let paths = RuntimePaths.validation(root: f.root)
            let staging = paths.asrInstallationJobsDirectory.appendingPathComponent(f.plan.id.uuidString).appendingPathComponent("model")
            try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: originalStaging, to: staging)
            let publisher = ModelInstallationPublisher.production(store: store, paths: paths)
            do { _ = try await publisher.publish(plan: f.plan, staging: staging); r.check(false, "B4 durable persistence failure throws") }
            catch { r.eq(store.current.installedASRModels.count, 0, "B4 failed persistence does not claim registration") }
            r.eq(store.current.activeImportedASRModelID, active, "B4 failed registration preserves active selection")
            fail.withLock { $0 = false }
            _ = try await publisher.publish(plan: f.plan, staging: staging)
            let saved = try JSONDecoder().decode(Configuration.self, from: defaults.data(forKey: "flowtype.config")!)
            r.eq(saved.installedASRModels.count, 1, "B4 production pair synchronously durable")
            r.eq(saved.importedASRModels.count, 1, "B4 imported and installed persisted together")
            r.eq(saved.activeImportedASRModelID, active, "B4 successful registration preserves active selection")
        } catch { r.check(false, "B4 durable production registration: \(error)") }
    }
    @MainActor static func testFreshDiskAndUnsafePaths(_ r: SelfTest.Reporter) async {
        let large = Fixture(), largeLibrary = Library(), largeSource = Source(large.bytes)
        defer { try? FileManager.default.removeItem(at: large.root) }
        let original = large.plan.files[0]
        let huge = HFPlannedFile(source: original.source, downloadEndpoint: original.downloadEndpoint,
            resolvedCommit: original.resolvedCommit, remotePath: original.remotePath,
            relativeDestination: original.relativeDestination, sizeBytes: 3 * 1024 * 1024 * 1024, digest: original.digest)
        let largePlan = ASRInstallPlan(id: large.plan.id, displayName: "Large admission only", engine: .whisperCoreML,
            files: [huge], totalBytes: huge.sizeBytes, recipeID: nil, recipeVersion: 1, credentialID: nil)
        let largeCoordinator = coordinator(large, largeLibrary, source: largeSource,
            disk: { _ in huge.sizeBytes + huge.sizeBytes / 10 - 1 })
        do { _ = try await largeCoordinator.enqueue(largePlan); r.check(false, "B4 ten percent reserve required") }
        catch { r.eq((error as? HFDownloadError)?.code, .diskFull, "B4 ten percent reserve admission") }
        r.eq(await largeSource.requests, 0, "B4 large admission uses metadata only")
        let f = Fixture(), library = Library(), source = Source(f.bytes)
        let free = OSAllocatedUnfairLock(initialState: Int64(0))
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let c = coordinator(f, library, source: source, disk: { _ in free.withLock { $0 } })
            do { _ = try await c.enqueue(f.plan); r.check(false, "B4 initial empty disk rejected") }
            catch { r.eq((error as? HFDownloadError)?.code, .diskFull, "B4 initial admission rejects empty disk") }
            free.withLock { $0 = Int64.max }
            let id = try await c.enqueue(f.plan); _ = await until { await source.entered }
            let stopping = Task { await c.pause(jobID: id) }
            _ = await until { await c.snapshots().first?.state == .paused }
            await source.release(); await stopping.value
            free.withLock { $0 = 0 }
            let before = await source.requests
            do { try await c.resume(jobID: id); r.check(false, "B4 resume resamples disk") }
            catch { r.eq((error as? HFDownloadError)?.code, .diskFull, "B4 fresh resume disk admission") }
            r.eq(await source.requests, before, "B4 insufficient resume disk prevents network")
            free.withLock { $0 = f.plan.totalBytes - f.plan.files[0].sizeBytes + 256 * 1024 * 1024 }
            try await c.resume(jobID: id)
            r.check(await until { await c.snapshots().first?.state == .installed }, "B4 exact remaining plus reserve admits resume")
            // A malformed job directory pointing outside owned storage stays visible but cannot be traversed.
            let external = f.root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let sentinel = external.appendingPathComponent("keep")
            try Data([42]).write(to: sentinel)
            let alias = f.jobs.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
            let recovered = coordinator(f, library, source: Source(f.bytes))
            let values = try await recovered.recover()
            r.check(values.contains { $0.errorCode == "invalidJournal" }, "B4 symlink job isolated")
            r.eq(try Data(contentsOf: sentinel), Data([42]), "B4 invalid journal cannot delete external data")
        } catch { r.check(false, "B4 disk/path fixture: \(error)") }
    }

    // Break caught: treating an arbitrary user model directory as movable managed staging.
    @MainActor static func testPublisherRejectsExternalStaging(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let staging = try f.stage()
            let external = f.root.appendingPathComponent("user-owned-model")
            try FileManager.default.moveItem(at: staging, to: external)
            do { _ = try await f.publisher(library).publish(plan: f.plan, staging: external); r.check(false, "B4 external directory cannot become managed staging") }
            catch { r.eq((error as? HFDownloadError)?.code, .integrity, "B4 external staging fails ownership check") }
            r.check(FileManager.default.fileExists(atPath: external.appendingPathComponent("tokenizer.json").path), "B4 external model directory remains untouched")
            r.eq(library.config.installedASRModels.count, 0, "B4 external staging never registers")
        } catch { r.check(false, "B4 external staging fixture: \(error)") }
    }

    final class VerificationGate: Sendable {
        struct State { var entered = false, exited = false, cancellationSeen = false, claimed = false, reads = 0 }
        let state = OSAllocatedUnfairLock(initialState: State())
        let release = DispatchSemaphore(value: 0)
        func blockOnce() {
            let claimed = state.withLock { value in
                guard !value.claimed else { return false }; value.claimed = true; value.entered = true; return true
            }
            if claimed {
                _ = release.wait(timeout: .now() + 2)
                state.withLock { $0.exited = true; $0.cancellationSeen = Task.isCancelled }
            }
        }
    }
    // Break caught: hashing owns the coordinator actor or releases the job slot before its worker drains.
    @MainActor static func testVerificationCancellationDrain(_ r: SelfTest.Reporter) async {
        for cancel in [false, true] {
            let f = Fixture(), library = Library(), source = Source(f.bytes), gate = VerificationGate()
            defer { gate.release.signal(); try? FileManager.default.removeItem(at: f.root) }
            do {
                await source.release()
                let c = ModelInstallationCoordinator(transport: { file, url, credential, progress in
                    try await source.transfer(file, url, credential, progress)
                }, publisher: f.publisher(library), verification: { file, url in
                    if FileManager.default.fileExists(atPath: url.path) { gate.blockOnce() }
                    try HFFileVerifier.verify(file: file, at: url)
                }, diskSample: { _ in Int64.max }, journalRoot: f.jobs)
                let id = try await c.enqueue(f.plan)
                let next = ASRInstallPlan(id: UUID(), displayName: "Queued", engine: f.plan.engine, files: f.plan.files,
                    totalBytes: f.plan.totalBytes, recipeID: nil, recipeVersion: 1, credentialID: f.plan.credentialID)
                let nextID = try await c.enqueue(next)
                r.check(await until { gate.state.withLock { $0.entered } }, "B4 fix hashing gate entered")
                let stopping = Task { if cancel { await c.cancel(jobID: id) } else { await c.pause(jobID: id) } }
                let expected: ModelInstallState = cancel ? .cancelled : .paused
                r.check(await until { await c.snapshots().first(where: { $0.jobID == id })?.state == expected }, "B4 fix pause observable during hash")
                r.check(!gate.state.withLock { $0.exited }, "B4 fix actor responds before hash completes")
                r.eq(await source.requests, 1, "B4 fix next owner waits hashing drain")
                gate.release.signal(); await stopping.value
                r.check(gate.state.withLock { $0.cancellationSeen }, "B4 fix hash inherits parent cancellation")
                r.check(await until { await c.snapshots().first(where: { $0.jobID == nextID })?.state == .installed }, "B4 fix next owner runs after hash drain")
                r.check(!library.config.installedASRModels.contains { $0.id == id }, "B4 fix cancelled verification never publishes")
            } catch { r.check(false, "B4 fix hash cancellation: \(error)") }
        }
    }
    // Break caught: cancellation is checked only around a whole-file hash, or becomes a network error.
    @MainActor static func testChunkVerificationCancellation(_ r: SelfTest.Reporter) async {
        let f = Fixture(), gate = VerificationGate()
        defer { gate.release.signal(); try? FileManager.default.removeItem(at: f.root) }
        do {
            let staging = try f.stage(), url = staging.appendingPathComponent("chunk-fixture.bin")
            let data = Data(repeating: 97, count: 3 * 64 * 1024)
            try data.write(to: url)
            let original = f.plan.files[0]
            let file = HFPlannedFile(source: original.source, downloadEndpoint: original.downloadEndpoint,
                resolvedCommit: original.resolvedCommit, remotePath: original.remotePath, relativeDestination: original.relativeDestination,
                sizeBytes: Int64(data.count), digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            let task = Task.detached {
                try HFFileVerifier.verify(file: file, at: url, readChunk: { handle, limit in
                    gate.state.withLock { $0.reads += 1 }
                    let chunk = try handle.read(upToCount: limit)
                    gate.blockOnce()
                    return chunk
                })
            }
            r.check(await until { gate.state.withLock { $0.entered } }, "B4 fix chunk reader entered")
            task.cancel(); gate.release.signal()
            do { try await task.value; r.check(false, "B4 fix chunk cancellation throws") }
            catch { r.check(error is CancellationError, "B4 fix cancellation remains cancellation") }
            r.eq(gate.state.withLock { $0.reads }, 1, "B4 fix cancelled verifier does not read remaining chunks")
        } catch { r.check(false, "B4 fix chunk fixture: \(error)") }
    }
    // Break caught: committed retry requires another payload allocation despite its valid manifest.
    @MainActor static func testCommittedDiskAdmission(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), source = Source(f.bytes)
        let available = OSAllocatedUnfairLock(initialState: Int64(256 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let staging = try f.stage(), target = "AudioEncoder.mlmodelc/weights/weight.bin"
            let size: Int64 = 300 * 1024 * 1024
            let handle = try FileHandle(forWritingTo: staging.appendingPathComponent(target))
            try handle.truncate(atOffset: UInt64(size)); try handle.close()
            // Sparse synthetic zeros: no model weights and no large Data allocation.
            var sha = SHA256(); let chunk = Data(repeating: 0, count: 64 * 1024)
            // Preserve the fixture's original leading byte, then hash the sparse zero remainder.
            sha.update(data: Data([1])); var remaining = size - 1
            while remaining > 0 { let count = Int(min(remaining, Int64(chunk.count))); sha.update(data: chunk.prefix(count)); remaining -= Int64(count) }
            let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
            let files = f.plan.files.map { file -> HFPlannedFile in
                guard file.relativeDestination == target else { return file }
                return .init(source: file.source, downloadEndpoint: file.downloadEndpoint, resolvedCommit: file.resolvedCommit,
                    remotePath: file.remotePath, relativeDestination: file.relativeDestination, sizeBytes: size, digest: .sha256(digest))
            }
            let plan = ASRInstallPlan(id: f.plan.id, displayName: "Sparse synthetic", engine: f.plan.engine, files: files,
                totalBytes: files.reduce(0) { $0 + $1.sizeBytes }, recipeID: nil, recipeVersion: 1, credentialID: nil)
            let journal = ModelInstallationJobJournal(version: 1, snapshot: .init(jobID: plan.id, plan: plan, state: .verifying,
                receivedBytes: plan.totalBytes, errorCode: nil), createdAt: Date(), libraryDetached: false)
            try JSONEncoder().encode(journal).write(to: staging.deletingLastPathComponent().appendingPathComponent("job.json"))
            library.shouldFail = true
            do { _ = try await f.publisher(library).publish(plan: plan, staging: staging) } catch { }
            let c = coordinator(f, library, source: source, disk: { _ in available.withLock { $0 } })
            _ = try await c.recover()
            library.shouldFail = false
            available.withLock { $0 = 256 * 1024 * 1024 - 1 }
            do { try await c.resume(jobID: plan.id); r.check(false, "B4 fix registration reserve still required") }
            catch { r.eq((error as? HFDownloadError)?.code, .diskFull, "B4 fix fresh registration reserve rejects insufficient disk") }
            available.withLock { $0 = 256 * 1024 * 1024 }
            try await c.resume(jobID: plan.id)
            r.check(await until { await c.snapshots().first?.state == .installed }, "B4 fix committed retry needs reserve only")
            r.eq(await source.requests, 0, "B4 fix committed disk retry sends zero requests")
            r.eq(library.config.installedASRModels.count, 1, "B4 fix committed disk retry registers once")
        } catch { r.check(false, "B4 fix committed disk admission: \(error)") }
    }
    actor DelayedProgressSource {
        let bytes: [String: Data]
        var calls = 0, enteredSecond = false, open = false
        var firstProgress: (@Sendable (Int64) -> Void)?
        init(_ bytes: [String: Data]) { self.bytes = bytes }
        func transfer(_ file: HFPlannedFile, _ url: URL, _ progress: @escaping @Sendable (Int64) -> Void) async throws {
            calls += 1; try bytes[file.remotePath]!.write(to: url); progress(file.sizeBytes)
            if calls == 1 { firstProgress = progress }
            if calls == 2 {
                enteredSecond = true
                while !open { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
            }
        }
        func emitOld() { firstProgress?(0) }
        func release() { open = true }
    }
    // Break caught: a delayed prior-file callback rewrites progress while the next file owns the slot.
    @MainActor static func testDelayedFileProgress(_ r: SelfTest.Reporter) async {
        let f = Fixture(), library = Library(), source = DelayedProgressSource(f.bytes)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let c = ModelInstallationCoordinator(transport: { file, url, _, progress in
                try await source.transfer(file, url, progress)
            }, publisher: f.publisher(library), diskSample: { _ in Int64.max }, journalRoot: f.jobs)
            _ = try await c.enqueue(f.plan)
            let expected = f.plan.files[0].sizeBytes + f.plan.files[1].sizeBytes
            r.check(await until { await c.snapshots().first?.receivedBytes == expected }, "B4 fix second file byte progress recorded")
            await source.emitOld()
            let regressed = await until { await c.snapshots().first?.receivedBytes == 0 }
            r.check(!regressed, "B4 fix completed-file callback cannot regress progress")
            await source.release()
            r.check(await until { await c.snapshots().first?.state == .installed }, "B4 fix delayed progress fixture drains")
        } catch { r.check(false, "B4 fix delayed progress: \(error)") }
    }
}
