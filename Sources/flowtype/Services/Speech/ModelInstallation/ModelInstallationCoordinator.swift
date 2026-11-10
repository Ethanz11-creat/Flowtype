import Foundation

/// One actor owns the persistent queue; a cancelled transport retains its slot until it drains.
actor ModelInstallationCoordinator {
    typealias Transfer = @Sendable (HFPlannedFile, URL, String?, @escaping @Sendable (Int64) -> Void) async throws -> Void
    typealias DiskSample = @Sendable (URL) throws -> Int64
    private let transport: Transfer
    private let publisher: ModelInstallationPublisher
    private let verification: HFFileVerifier.Verification
    private let clock: @Sendable () -> Date
    private let diskSample: DiskSample
    let journalRoot: URL
    private var jobs: [UUID: ModelInstallationJobJournal] = [:]
    private var order: [UUID] = []
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?
    private var generation = UUID()
    private var permit: ModelPublicationPermit?
    private var isRecovering = false
    private var removalCount = 0
    private var clearingIDs = Set<UUID>()
    private var currentTransferID: UUID?
    private let usageRegistry: NativeModelUsageRegistry
    private let configuration: @MainActor @Sendable () -> Configuration
    private let persistRemoval: @MainActor @Sendable (Configuration) throws -> Void

    @MainActor static let shared = ModelInstallationCoordinator(publisher: .production(),
        journalRoot: RuntimeEnvironment.current.paths.asrInstallationJobsDirectory,
        configuration: { ConfigurationStore.shared.current },
        persistRemoval: { try ConfigurationStore.shared.commitNativeASRActivation($0) })

    init(transport: @escaping Transfer, publisher: ModelInstallationPublisher,
         verification: @escaping HFFileVerifier.Verification = { try HFFileVerifier.verify(file: $0, at: $1) },
         clock: @escaping @Sendable () -> Date = { Date() },
         diskSample: @escaping DiskSample = { url in
             let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
             guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw HFDownloadError(code: .diskFull) }
             return bytes
         }, journalRoot: URL, usageRegistry: NativeModelUsageRegistry = .shared,
         configuration: @escaping @MainActor @Sendable () -> Configuration = { Configuration() },
         persistRemoval: @escaping @MainActor @Sendable (Configuration) throws -> Void = { _ in throw NativeModelUsageError.invalidOwnership }) {
        self.transport = transport; self.publisher = publisher; self.clock = clock; self.verification = verification
        self.diskSample = diskSample; self.journalRoot = journalRoot
        self.usageRegistry = usageRegistry; self.configuration = configuration; self.persistRemoval = persistRemoval
    }
    init(transport: HFDownloadTransport = HFDownloadTransport(), publisher: ModelInstallationPublisher,
         verification: @escaping HFFileVerifier.Verification = { try HFFileVerifier.verify(file: $0, at: $1) },
         clock: @escaping @Sendable () -> Date = { Date() },
         diskSample: @escaping DiskSample = { url in
             let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
             guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw HFDownloadError(code: .diskFull) }; return bytes
         }, journalRoot: URL, usageRegistry: NativeModelUsageRegistry = .shared,
         configuration: @escaping @MainActor @Sendable () -> Configuration = { Configuration() },
         persistRemoval: @escaping @MainActor @Sendable (Configuration) throws -> Void = { _ in throw NativeModelUsageError.invalidOwnership }) {
        self.init(transport: { file, url, credential, progress in
            try await transport.transfer(file: file, partialURL: url, credentialID: credential, progress: progress)
        }, publisher: publisher, verification: verification, clock: clock, diskSample: diskSample, journalRoot: journalRoot, usageRegistry: usageRegistry, configuration: configuration, persistRemoval: persistRemoval)
    }
    /// Explicit preset acquisition. The queue remains the only transfer owner and the
    /// immutable recipe/source are captured before enqueue. Acquisition never selects.
    func acquire(preset: ModelPreset, source: DownloadSource,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedASRModel {
        let config = await configuration()
        let existing = config.installedASRModels.filter { $0.ownership == .managed && $0.installPlan?.recipeID == preset.id }
        guard existing.count <= 1 else { throw NativeModelUsageError.invalidOwnership }
        if let record = existing.first,
           let model = config.importedASRModels.first(where: { $0.id == record.importedModelID }) {
            try publisher.validateRemoval(record, model: model, configuration: config)
            return model
        }
        guard ValidationEffects.live.allow(.modelDownload), let recipe = preset.installationRecipe,
              let sourceSelection = recipe.sources.first else { throw ModelProvisionError.loadFailed() }
        let endpoint = try source.validatedEndpoint(isChina: DownloadSource.systemIsLikelyChina())
        let client = HFRepositoryClient(downloadEndpoint: endpoint)
        let repository = try await client.resolve(sourceSelection)
        let tokenizer: HFResolvedRepository?
        if recipe.sources.count > 1 { tokenizer = try await client.resolve(recipe.sources[1]) } else { tokenizer = nil }
        let plan = try await ASRInstallPlanner(client: client).plan(repository: repository, variant: recipe.variant, tokenizer: tokenizer)
        try Task.checkCancellation()
        let jobID = try await enqueue(plan)
        do {
            while let snapshot = jobs[jobID]?.snapshot {
                try Task.checkCancellation()
                progress(Double(snapshot.receivedBytes) / Double(max(1, plan.totalBytes)))
                switch snapshot.state {
                case .installed:
                    let current = await configuration()
                    guard let record = current.installedASRModels.first(where: { $0.id == jobID }),
                          let model = current.importedASRModels.first(where: { $0.id == record.importedModelID }) else { throw HFDownloadError(code: .integrity) }
                    return model
                case .failed, .cancelled, .paused: throw HFDownloadError(code: .network)
                default: try await Task.sleep(for: .milliseconds(40))
                }
            }
            throw HFDownloadError(code: .integrity)
        } catch {
            // A cancellation cannot release the lifecycle while a native file writer lives.
            if Task.isCancelled { await cancel(jobID: jobID) }
            throw error
        }
    }

    func enqueue(_ plan: ASRInstallPlan) async throws -> UUID {
        guard !isRecovering, ownedJournalRoot else { throw HFDownloadError(code: .integrity) }
        try ModelInstallationPublisher.validate(plan)
        guard jobs[plan.id] == nil else { throw HFDownloadError(code: .integrity) }
        try ModelInstallationPublisher.ensureDirectory(journalRoot)
        guard !FileManager.default.fileExists(atPath: jobDirectory(plan.id).path) else { throw HFDownloadError(code: .integrity) }
        try admission(plan)
        try ModelInstallationPublisher.ensureDirectory(staging(plan.id))
        let snapshot = ModelInstallSnapshot(jobID: plan.id, plan: plan, state: .queued, receivedBytes: 0, errorCode: nil)
        let job = ModelInstallationJobJournal(version: 1, snapshot: snapshot, createdAt: clock(), libraryDetached: false)
        try persist(job)
        jobs[plan.id] = job; order.append(plan.id)
        schedule()
        return plan.id
    }
    func pause(jobID: UUID) async { await stop(jobID, state: .paused) }
    func cancel(jobID: UUID) async { await stop(jobID, state: .cancelled) }
    private func stop(_ id: UUID, state: ModelInstallState) async {
        guard !clearingIDs.contains(id), let job = jobs[id], job.snapshot.state != .installed, job.snapshot.errorCode != "invalidJournal" else { return }
        if activeID == id, let task = activeTask {
            let committed = permit?.revoke() == true
            if !committed {
                generation = UUID()
                update(id, state: state)
                task.cancel()
            }
            // Includes verification and publication drain; never release a live file writer.
            await task.value
        } else { update(id, state: state) }
    }
    func resume(jobID: UUID) async throws {
        guard !isRecovering, !clearingIDs.contains(jobID) else { throw HFDownloadError(code: .integrity) }
        if activeID == jobID, let task = activeTask { await task.value }
        guard !isRecovering, !clearingIDs.contains(jobID), var job = jobs[jobID], !job.libraryDetached, job.snapshot.errorCode != "invalidJournal" else { throw HFDownloadError(code: .integrity) }
        if job.snapshot.state == .installed { return }
        try ModelInstallationPublisher.validate(job.snapshot.plan)
        try admission(job.snapshot.plan)
        job.snapshot.receivedBytes = try publisher.hasCommittedPublication(for: job.snapshot.plan) ? job.snapshot.plan.totalBytes : received(job.snapshot.plan)
        job.snapshot.state = .queued; job.snapshot.errorCode = nil
        try persist(job); jobs[jobID] = job
        schedule()
    }
    /// Independent explicit cleanup. Never waits for or cancels a live writer: the caller
    /// must pause/cancel and await its real drain first. A reservation survives the final
    /// MainActor configuration/deletion transaction; no suspension follows its final check.
    func clearPartial(jobID: UUID) async throws {
        guard !isRecovering, ownedJournalRoot, activeID != jobID, !clearingIDs.contains(jobID),
              let initial = jobs[jobID] else { throw NativeModelUsageError.invalidOwnership }
        clearingIDs.insert(jobID); removalCount += 1
        defer { clearingIDs.remove(jobID); removalCount -= 1; schedule() }
        let config = await configuration()
        guard !isRecovering, activeID != jobID, let job = jobs[jobID],
              job.snapshot == initial.snapshot, !job.libraryDetached,
              [.paused, .cancelled, .failed].contains(job.snapshot.state),
              job.snapshot.errorCode != "invalidJournal" else { throw NativeModelUsageError.inUse }
        let directory = staging(jobID)
        try publisher.validatePartialRemoval(job: job, journalRoot: journalRoot, configuration: config)
        // The durable zero-byte paused state is written BEFORE removal. A crash before
        // deletion merely leaves resumable bytes; recover recomputes them from disk.
        var cleared = job
        cleared.snapshot.state = .paused; cleared.snapshot.receivedBytes = 0; cleared.snapshot.errorCode = nil
        try persist(cleared); jobs[jobID] = cleared
        let publisher = self.publisher, journalRoot = self.journalRoot, configuration = self.configuration
        let finalJournal = cleared
        do {
            try await MainActor.run {
                // Configuration edits/imports serialize with this final authority check
                // and deletion. The installer reservation prevents resume/stop/recovery
                // from changing the same job while this actor hop is pending.
                try publisher.validatePartialRemoval(job: finalJournal, journalRoot: journalRoot, configuration: configuration())
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }
        } catch {
            try? setProgress(jobID, bytes: received(job.snapshot.plan))
            update(jobID, state: .failed, error: "partialClearFailed")
            throw error
        }
    }

    func snapshots() async -> [ModelInstallSnapshot] { order.compactMap { jobs[$0]?.snapshot } }

    /// All unfinished network work becomes paused. Only already-renamed installations can register offline.
    func recover() async throws -> [ModelInstallSnapshot] {
        guard activeTask == nil, removalCount == 0, !isRecovering, ownedJournalRoot else { throw HFDownloadError(code: .integrity) }
        isRecovering = true
        defer { isRecovering = false }
        try ModelInstallationPublisher.ensureDirectory(journalRoot)
        jobs = [:]; order = []
        for directory in try FileManager.default.contentsOfDirectory(at: journalRoot, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                try ModelInstallationPublisher.noSymlinks(directory)
                let url = directory.appendingPathComponent("job.json")
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max <= 32 * 1024 * 1024 else { throw HFDownloadError(code: .integrity) }
                var job = try JSONDecoder().decode(ModelInstallationJobJournal.self, from: Data(contentsOf: url))
                guard job.version == 1, job.snapshot.jobID == id, job.snapshot.plan.id == id else { throw HFDownloadError(code: .integrity) }
                try ModelInstallationPublisher.validate(job.snapshot.plan)
                job.snapshot.errorCode = nil
                if job.libraryDetached {
                    // Detached publication must never resurrect a deliberately removed library entry.
                    job.snapshot.state = .cancelled
                } else if FileManager.default.fileExists(atPath: publisher.directory(for: job.snapshot.plan).path) {
                    do {
                        _ = try await publisher.publish(plan: job.snapshot.plan, staging: staging(id))
                        job.snapshot.state = .installed; job.snapshot.receivedBytes = job.snapshot.plan.totalBytes
                    } catch {
                        job.snapshot.state = .failed; job.snapshot.errorCode = Self.code(error)
                    }
                } else {
                    job.snapshot.receivedBytes = try received(job.snapshot.plan)
                    if job.snapshot.state != .cancelled { job.snapshot.state = .paused }
                }
                try persist(job); jobs[id] = job
            } catch {
                // Keep malformed input in place, with no traversal/deletion of any decoded paths.
                let plan = ASRInstallPlan(id: id, displayName: "无法恢复的安装任务", engine: .qwenMLX, files: [], totalBytes: 0,
                                          recipeID: nil, recipeVersion: 0, credentialID: nil)
                jobs[id] = .init(version: 1, snapshot: .init(jobID: id, plan: plan, state: .failed, receivedBytes: 0,
                    errorCode: "invalidJournal"), createdAt: .distantPast, libraryDetached: false)
            }
            order.append(id)
        }
        order.sort { (jobs[$0]!.createdAt, $0.uuidString) < (jobs[$1]!.createdAt, $1.uuidString) }
        return await snapshots()
    }

    /// Persist this before removing library records; B6 owns the actual remove/delete transaction.
    func markLibraryDetached(jobID: UUID) async throws {
        guard !isRecovering, !clearingIDs.contains(jobID), var job = jobs[jobID], activeID != jobID,
              job.snapshot.errorCode != "invalidJournal" else { throw HFDownloadError(code: .integrity) }
        try ModelInstallationPublisher.validate(job.snapshot.plan)
        job.libraryDetached = true
        try persist(job); jobs[jobID] = job
    }
    /// modelID is the imported library UUID, never the installation/job UUID.
    func remove(modelID: UUID, deleteManagedFiles: Bool) async throws {
        guard !isRecovering, ownedJournalRoot else { throw NativeModelUsageError.invalidOwnership }
        let reservation = try usageRegistry.reserveDeletion(modelID: modelID)
        removalCount += 1
        defer { removalCount -= 1; withExtendedLifetime(reservation) {} }
        let before = await configuration()
        guard let model = before.importedASRModels.first(where: { $0.id == modelID }) else { throw NativeModelUsageError.invalidOwnership }
        let records = before.installedASRModels.filter { $0.importedModelID == modelID }
        guard records.count <= 1 else { throw NativeModelUsageError.invalidOwnership }
        let record = records.first
        try Self.requireDeselected(model, in: before)
        if deleteManagedFiles {
            guard let record, record.ownership == .managed else { throw NativeModelUsageError.external }
            try publisher.validateRemoval(record, model: model, configuration: before)
        }
        if let record, record.ownership == .managed {
            // Recovery is deliberately not invoked here: it could republish removed state.
            // Read the durable journal afresh: an in-memory entry cannot authorize
            // replacing a corrupted or foreign on-disk owner record.
            do {
                let url = jobDirectory(record.id).appendingPathComponent("job.json")
                try ModelInstallationPublisher.noSymlinks(url)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.int64Value ?? .max <= 32 * 1024 * 1024 else { throw NativeModelUsageError.invalidOwnership }
                let data = try Data(contentsOf: url)
                guard data.count <= 32 * 1024 * 1024 else { throw NativeModelUsageError.invalidOwnership }
                let journal = try JSONDecoder().decode(ModelInstallationJobJournal.self, from: data)
                guard journal.version == 1, journal.snapshot.jobID == record.id,
                      journal.snapshot.plan == record.installPlan else { throw NativeModelUsageError.invalidOwnership }
                jobs[record.id] = journal
            }
            guard jobs[record.id]?.snapshot.plan == record.installPlan else { throw NativeModelUsageError.invalidOwnership }
            try await markLibraryDetached(jobID: record.id)
        }
        let publisher = self.publisher, configuration = self.configuration, persist = self.persistRemoval
        try await MainActor.run {
            let current = configuration()
            guard current.importedASRModels.first(where: { $0.id == modelID }) == model,
                  current.installedASRModels.filter({ $0.importedModelID == modelID }) == records else {
                throw NativeModelUsageError.invalidOwnership
            }
            try Self.requireDeselected(model, in: current)
            if deleteManagedFiles, let record { try publisher.validateRemoval(record, model: model, configuration: current) }
            var next = LocalModelLibrary.removing(id: modelID, from: current)
            next.installedASRModels.removeAll { $0.importedModelID == modelID }
            try persist(next)
            if deleteManagedFiles, let record { try FileManager.default.removeItem(at: record.directory) }
        }
    }
    static func requireDeselected(_ model: ImportedASRModel, in config: Configuration) throws {
        let selected = config.asrBackendSelection
        let selectedImports = [selected?.primary, selected?.fallback].compactMap { id -> UUID? in
            guard let raw = id?.rawValue, raw.hasPrefix("native:import:") else { return nil }
            return UUID(uuidString: String(raw.dropFirst("native:import:".count)))
        }
        guard config.activeImportedASRModelID != model.id, !selectedImports.contains(model.id) else {
            throw NativeModelUsageError.selected
        }
        for path in [config.localModelPath, config.customLocalModelPath].compactMap({ $0 }) {
            guard URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath() != model.directory.standardizedFileURL.resolvingSymlinksInPath() else {
                throw NativeModelUsageError.selected
            }
        }
        let presetIDs = [config.selectedLocalModelID] + [selected?.primary, selected?.fallback].map {
            $0?.rawValue.hasPrefix("native:preset:") == true ? String($0!.rawValue.dropFirst("native:preset:".count)) : nil
        }
        if let associated = config.installedASRModels.first(where: { $0.importedModelID == model.id })?.legacyPresetID,
           presetIDs.contains(associated) { throw NativeModelUsageError.selected }
    }

    private func schedule() {
        guard activeTask == nil, let id = order.first(where: { jobs[$0]?.snapshot.state == .queued && jobs[$0]?.libraryDetached == false && !clearingIDs.contains($0) }) else { return }
        let token = UUID(), publicationPermit = ModelPublicationPermit()
        generation = token; activeID = id; permit = publicationPermit
        activeTask = Task { await self.run(id, generation: token, permit: publicationPermit) }
    }
    private func run(_ id: UUID, generation token: UUID, permit: ModelPublicationPermit) async {
        defer {
            activeTask = nil; activeID = nil; self.permit = nil; currentTransferID = nil
            schedule()
        }
        guard let plan = jobs[id]?.snapshot.plan else { return }
        do {
            // A prior rename already owns the final directory. Retry registration offline,
            // retaining the commit boundary even if pause/cancel arrives during reinspection.
            if try publisher.hasCommittedPublication(for: plan) {
                try permit.commit { }
                try setState(id, .verifying)
                _ = try await publisher.publish(plan: plan, staging: staging(id), permit: permit)
                try setProgress(id, bytes: plan.totalBytes)
                try setState(id, .installed)
                return
            }
            try admission(plan)
            try setState(id, .downloading)
            for file in plan.files {
                try Task.checkCancellation()
                guard generation == token else { return }
                let url = staging(id).appendingPathComponent(file.relativeDestination)
                try ModelInstallationPublisher.ensureDirectory(url.deletingLastPathComponent())
                try ModelInstallationPublisher.noSymlinks(url)
                // Verified completed files skip HTTP on explicit resume. Sidecars remain transport-owned.
                let verified: Bool
                do { try await HFFileVerifier.verifyAsync(file: file, at: url, verification: verification); verified = true }
                catch is CancellationError { throw CancellationError() }
                catch { verified = false }
                try Task.checkCancellation()
                guard generation == token else { return }
                if verified, !FileManager.default.fileExists(atPath: HFDownloadJournal.sidecarURL(for: url).path) { continue }
                let base = try received(plan, excluding: file.relativeDestination)
                let transferID = UUID()
                currentTransferID = transferID
                try await transport(file, url, plan.credentialID) { bytes in
                    Task { await self.progress(id, generation: token, transferID: transferID, bytes: base + min(max(0, bytes), file.sizeBytes)) }
                }
                currentTransferID = nil
                try Task.checkCancellation()
                guard generation == token else { return }
                try await HFFileVerifier.verifyAsync(file: file, at: url, verification: verification)
                try Task.checkCancellation()
                guard generation == token else { return }
                try setProgress(id, bytes: received(plan))
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            try setState(id, .verifying)
            _ = try await publisher.publish(plan: plan, staging: staging(id), permit: permit)
            // A committed rename wins a racing cancel; the cancellation path does not invalidate it.
            guard generation == token else { return }
            try setProgress(id, bytes: plan.totalBytes)
            try setState(id, .installed)
        } catch {
            guard generation == token else { return }
            let failure = error as? HFDownloadError
            update(id, state: failure?.requiresPause == true ? .paused : .failed, error: Self.code(error))
        }
    }
    private func progress(_ id: UUID, generation token: UUID, transferID: UUID, bytes: Int64) {
        guard generation == token, activeID == id, currentTransferID == transferID, jobs[id]?.snapshot.state == .downloading else { return }
        do { try setProgress(id, bytes: bytes) }
        catch {
            _ = permit?.revoke(); generation = UUID(); activeTask?.cancel()
            update(id, state: .failed, error: "journalPersistence")
        }
    }
    private func admission(_ plan: ASRInstallPlan) throws {
        let remaining = try publisher.hasCommittedPublication(for: plan) ? 0 : plan.totalBytes - received(plan)
        let reserve = max(Int64(256 * 1024 * 1024), plan.totalBytes / 10)
        let required = remaining.addingReportingOverflow(reserve)
        guard !required.overflow, try diskSample(journalRoot) >= required.partialValue else { throw HFDownloadError(code: .diskFull) }
    }
    private func received(_ plan: ASRInstallPlan, excluding: String? = nil) throws -> Int64 {
        var total: Int64 = 0
        for file in plan.files where file.relativeDestination != excluding {
            let url = staging(plan.id).appendingPathComponent(file.relativeDestination)
            try ModelInstallationPublisher.noSymlinks(url)
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular else { throw HFDownloadError(code: .integrity) }
                total += min(file.sizeBytes, max(0, (attrs[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        return total
    }
    private func setState(_ id: UUID, _ state: ModelInstallState) throws {
        guard var job = jobs[id] else { return }
        job.snapshot.state = state; job.snapshot.errorCode = nil
        try persist(job); jobs[id] = job
    }
    private func setProgress(_ id: UUID, bytes: Int64) throws {
        guard var job = jobs[id] else { return }
        job.snapshot.receivedBytes = min(max(0, bytes), job.snapshot.plan.totalBytes)
        try persist(job); jobs[id] = job
    }
    private func update(_ id: UUID, state: ModelInstallState, error: String? = nil) {
        guard var job = jobs[id] else { return }
        job.snapshot.state = state; job.snapshot.errorCode = error
        do { try persist(job) }
        catch { job.snapshot.state = .failed; job.snapshot.errorCode = "journalPersistence" }
        jobs[id] = job
    }
    private func persist(_ job: ModelInstallationJobJournal) throws {
        try ModelInstallationPublisher.ensureDirectory(jobDirectory(job.snapshot.jobID))
        let url = jobDirectory(job.snapshot.jobID).appendingPathComponent("job.json")
        try ModelInstallationPublisher.noSymlinks(url)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
    }
    private var ownedJournalRoot: Bool {
        journalRoot.isFileURL && journalRoot.standardizedFileURL.path == publisher.jobsRoot.standardizedFileURL.path
    }
    private func jobDirectory(_ id: UUID) -> URL { journalRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func staging(_ id: UUID) -> URL { jobDirectory(id).appendingPathComponent("model", isDirectory: true) }
    private static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        return (error as? HFDownloadError)?.code.rawValue ?? (error is ASRModelInspectionError ? "integrity" : HFDownloadError.disk(error).code.rawValue)
    }
}
