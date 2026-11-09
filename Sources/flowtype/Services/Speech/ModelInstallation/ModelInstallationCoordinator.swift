import Foundation

/// One actor owns the persistent queue; a cancelled transport retains its slot until it drains.
actor ModelInstallationCoordinator {
    typealias Transfer = @Sendable (HFPlannedFile, URL, String?, @escaping @Sendable (Int64) -> Void) async throws -> Void
    typealias DiskSample = @Sendable (URL) throws -> Int64
    private let transport: Transfer
    private let publisher: ModelInstallationPublisher
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

    init(transport: @escaping Transfer, publisher: ModelInstallationPublisher,
         clock: @escaping @Sendable () -> Date = { Date() },
         diskSample: @escaping DiskSample = { url in
             let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
             guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw HFDownloadError(code: .diskFull) }
             return bytes
         }, journalRoot: URL) {
        self.transport = transport; self.publisher = publisher; self.clock = clock
        self.diskSample = diskSample; self.journalRoot = journalRoot
    }
    init(transport: HFDownloadTransport = HFDownloadTransport(), publisher: ModelInstallationPublisher,
         clock: @escaping @Sendable () -> Date = { Date() },
         diskSample: @escaping DiskSample = { url in
             let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
             guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw HFDownloadError(code: .diskFull) }; return bytes
         }, journalRoot: URL) {
        self.init(transport: { file, url, credential, progress in
            try await transport.transfer(file: file, partialURL: url, credentialID: credential, progress: progress)
        }, publisher: publisher, clock: clock, diskSample: diskSample, journalRoot: journalRoot)
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
        guard let job = jobs[id], job.snapshot.state != .installed, job.snapshot.errorCode != "invalidJournal" else { return }
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
        guard !isRecovering else { throw HFDownloadError(code: .integrity) }
        if activeID == jobID, let task = activeTask { await task.value }
        guard var job = jobs[jobID], !job.libraryDetached, job.snapshot.errorCode != "invalidJournal" else { throw HFDownloadError(code: .integrity) }
        if job.snapshot.state == .installed { return }
        try ModelInstallationPublisher.validate(job.snapshot.plan)
        try admission(job.snapshot.plan)
        job.snapshot.receivedBytes = try received(job.snapshot.plan)
        job.snapshot.state = .queued; job.snapshot.errorCode = nil
        try persist(job); jobs[jobID] = job
        schedule()
    }
    func snapshots() async -> [ModelInstallSnapshot] { order.compactMap { jobs[$0]?.snapshot } }

    /// All unfinished network work becomes paused. Only already-renamed installations can register offline.
    func recover() async throws -> [ModelInstallSnapshot] {
        guard activeTask == nil, !isRecovering, ownedJournalRoot else { throw HFDownloadError(code: .integrity) }
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
        guard !isRecovering, var job = jobs[jobID], activeID != jobID,
              job.snapshot.errorCode != "invalidJournal" else { throw HFDownloadError(code: .integrity) }
        try ModelInstallationPublisher.validate(job.snapshot.plan)
        job.libraryDetached = true
        try persist(job); jobs[jobID] = job
    }
    private func schedule() {
        guard activeTask == nil, let id = order.first(where: { jobs[$0]?.snapshot.state == .queued && jobs[$0]?.libraryDetached == false }) else { return }
        let token = UUID(), publicationPermit = ModelPublicationPermit()
        generation = token; activeID = id; permit = publicationPermit
        activeTask = Task { await self.run(id, generation: token, permit: publicationPermit) }
    }
    private func run(_ id: UUID, generation token: UUID, permit: ModelPublicationPermit) async {
        defer {
            activeTask = nil; activeID = nil; self.permit = nil
            schedule()
        }
        guard let plan = jobs[id]?.snapshot.plan else { return }
        do {
            // A prior rename already owns the final directory. Retry registration offline,
            // retaining the commit boundary even if pause/cancel arrives during reinspection.
            if FileManager.default.fileExists(atPath: publisher.directory(for: plan).path) {
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
                if (try? HFFileVerifier.verify(file: file, at: url)) != nil,
                   !FileManager.default.fileExists(atPath: HFDownloadJournal.sidecarURL(for: url).path) { continue }
                let base = try received(plan, excluding: file.relativeDestination)
                try await transport(file, url, plan.credentialID) { bytes in
                    Task { await self.progress(id, generation: token, bytes: base + min(max(0, bytes), file.sizeBytes)) }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                try HFFileVerifier.verify(file: file, at: url)
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
    private func progress(_ id: UUID, generation token: UUID, bytes: Int64) {
        guard generation == token, activeID == id, jobs[id]?.snapshot.state == .downloading else { return }
        do { try setProgress(id, bytes: bytes) }
        catch {
            _ = permit?.revoke(); generation = UUID(); activeTask?.cancel()
            update(id, state: .failed, error: "journalPersistence")
        }
    }
    private func admission(_ plan: ASRInstallPlan) throws {
        let remaining = plan.totalBytes - (try received(plan))
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
