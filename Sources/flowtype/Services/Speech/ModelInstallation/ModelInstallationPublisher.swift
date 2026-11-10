import Foundation
import Darwin
import os

/// Revocation and rename share a lock: there is no suspend point or cancellation race at commit.
final class ModelPublicationPermit: Sendable {
    private struct State: Sendable { var revoked = false; var committed = false }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    @discardableResult func revoke() -> Bool {
        lock.withLock { state in
            if !state.committed { state.revoked = true }
            return state.committed
        }
    }
    func commit(_ operation: @Sendable () throws -> Void) throws {
        try lock.withLock { state in
            guard !state.revoked else { throw HFDownloadError(code: .cancelled) }
            try Task.checkCancellation()
            try operation()
            state.committed = true
        }
    }
}

/// Complete verification precedes same-filesystem rename; durable registration follows it.
struct ModelInstallationPublisher: Sendable {
    typealias Registration = @MainActor @Sendable (ASRInstalledModelRecord, ImportedASRModel) throws -> Void
    enum Boundary: String, CaseIterable, Sendable { case beforeManifest, beforeRename, afterRename, beforeRegistration, afterRegistration }
    typealias BoundaryHook = @Sendable (Boundary) async throws -> Void
    private struct Manifest: Codable, Sendable {
        let version: Int
        let record: ASRInstalledModelRecord
    }
    let installedRoot: URL
    private let register: Registration
    private let boundary: BoundaryHook

    init(installedRoot: URL, register: @escaping Registration, boundary: @escaping BoundaryHook = { _ in }) {
        self.installedRoot = installedRoot; self.register = register; self.boundary = boundary
    }
    @MainActor static func production(store: ConfigurationStore = .shared,
                                     paths: RuntimePaths = RuntimeEnvironment.current.paths) -> Self {
        Self(installedRoot: paths.installedASRModelsDirectory, register: { record, model in
            try store.registerInstalledASRModel(record, model: model)
        })
    }
    var jobsRoot: URL { installedRoot.deletingLastPathComponent().appendingPathComponent("installation-jobs", isDirectory: true) }
    func directory(for plan: ASRInstallPlan) -> URL {
        installedRoot.appendingPathComponent(plan.id.uuidString, isDirectory: true).appendingPathComponent("model", isDirectory: true)
    }
    func publish(plan: ASRInstallPlan, staging: URL) async throws -> ASRInstalledModelRecord {
        try await publish(plan: plan, staging: staging, permit: ModelPublicationPermit())
    }
    @concurrent func publish(plan: ASRInstallPlan, staging: URL, permit: ModelPublicationPermit) async throws -> ASRInstalledModelRecord {
        try Self.validate(plan)
        // Coordinator binds jobID to plan.id. Only that UUID's managed staging is movable.
        let ownedStaging = jobsRoot.appendingPathComponent(plan.id.uuidString, isDirectory: true).appendingPathComponent("model", isDirectory: true)
        guard staging.isFileURL, staging.standardizedFileURL.path == ownedStaging.standardizedFileURL.path else {
            throw HFDownloadError(code: .integrity)
        }
        try Self.ensureDirectory(installedRoot)
        let destination = directory(for: plan)
        try Self.ensureDirectory(destination.deletingLastPathComponent())
        let manifest: Manifest
        if FileManager.default.fileExists(atPath: destination.path) {
            // A prior rename is already committed. No replacement, even if its manifest is invalid.
            manifest = try committedManifest(for: plan)
            try await Self.verify(plan, directory: destination)
        } else {
            try Self.noSymlinks(staging)
            // Staging and final roots must share a filesystem. rename never falls back to copy.
            var from = stat(), to = stat()
            guard lstat(staging.path, &from) == 0, lstat(installedRoot.path, &to) == 0,
                  from.st_dev == to.st_dev else { throw HFDownloadError(code: .integrity) }
            try await Self.verify(plan, directory: staging)
            try Task.checkCancellation()
            let model = try LocalASRRuntimeRegistry.standard.inspect(engine: plan.engine, directory: staging.standardizedFileURL.resolvingSymlinksInPath())
            try Task.checkCancellation()
            // Stable IDs are persisted in the manifest before the rename.
            let record = ASRInstalledModelRecord(id: plan.id, importedModelID: model.id, ownership: .managed,
                installPlan: plan, directory: destination, validation: nil)
            manifest = Manifest(version: 1, record: record)
            try await boundary(.beforeManifest)
            try Task.checkCancellation()
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("installation-manifest.json"), options: .atomic)
            try await boundary(.beforeRename)
            try permit.commit {
                guard Darwin.renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw HFDownloadError.disk(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                }
            }
            try await boundary(.afterRename)
        }
        // Inspection fingerprints include absolute paths. Recompute at the final path, retaining
        // the manifest's durable identity, so activation never receives a staging fingerprint.
        var finalModel = try LocalASRRuntimeRegistry.standard.inspect(engine: plan.engine, directory: destination.standardizedFileURL.resolvingSymlinksInPath())
        finalModel.id = manifest.record.importedModelID; finalModel.name = plan.displayName
        try await boundary(.beforeRegistration)
        try await register(manifest.record, finalModel)
        try await boundary(.afterRegistration)
        return manifest.record
    }
    static func validate(_ plan: ASRInstallPlan) throws {
        guard !plan.files.isEmpty, plan.files.count <= 10_000,
              plan.credentialID == nil || plan.credentialID == "asr.hf.official" else { throw HFDownloadError(code: .integrity) }
        try ASRInstallPlanner.validateFilePaths(plan.files.map(\.relativeDestination) + ["installation-manifest.json"])
        var total: Int64 = 0
        for file in plan.files {
            guard HFRepositoryInput.validPath(file.remotePath), file.sizeBytes > 0,
                  (file.downloadEndpoint.scheme == "https" && file.downloadEndpoint.host?.isEmpty == false && file.downloadEndpoint.user == nil && file.downloadEndpoint.password == nil && file.downloadEndpoint.fragment == nil), file.downloadEndpoint.query == nil,
                  ["", "/"].contains(file.downloadEndpoint.path),
                  (try? HFRepositoryInput.parse(file.source.repoID))?.repoID == file.source.repoID,
                  file.resolvedCommit.count == 40, file.resolvedCommit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  file.relativeDestination != "installation-manifest.json" else { throw HFDownloadError(code: .integrity) }
            let digest: String, count: Int
            switch file.digest { case .sha256(let value): digest = value; count = 64; case .gitBlobSHA1(let value): digest = value; count = 40 }
            guard digest.count == count, digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw HFDownloadError(code: .integrity) }
            let next = total.addingReportingOverflow(file.sizeBytes)
            guard !next.overflow else { throw HFDownloadError(code: .integrity) }; total = next.partialValue
        }
        guard total == plan.totalBytes else { throw HFDownloadError(code: .integrity) }
    }
    /// Manifest identity is enough for admission accounting; publish still rechecks every
    /// payload hash and strict static layout before registration can succeed.
    func hasCommittedPublication(for plan: ASRInstallPlan) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory(for: plan).path) else { return false }
        _ = try committedManifest(for: plan)
        return true
    }
    /// Only a registered B4 publication in the exact owned layout can authorize deletion.
    func validateRemoval(_ record: ASRInstalledModelRecord, model: ImportedASRModel, configuration: Configuration) throws {
        guard record.ownership == .managed, record.legacyPresetID == nil, let plan = record.installPlan,
              record.id == plan.id, record.importedModelID == model.id,
              record.directory.path == directory(for: plan).path,
              [record.directory.path, record.directory.standardizedFileURL.resolvingSymlinksInPath().path].contains(model.directory.path) else { throw NativeModelUsageError.invalidOwnership }
        try Self.validate(plan)
        let manifest = try committedManifest(for: plan)
        guard manifest.record.importedModelID == model.id else { throw NativeModelUsageError.invalidOwnership }
        let key = record.directory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        guard !configuration.importedASRModels.contains(where: {
            $0.id != model.id && $0.directory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() == key
        }), !configuration.installedASRModels.contains(where: {
            $0.id != record.id && $0.directory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() == key
        }) else { throw NativeModelUsageError.invalidOwnership }
        try Self.noSymlinks(record.directory)
        // Root aliases accepted by Foundation must not relax spelling below the trusted
        // root, including case-only renames on case-insensitive filesystems.
        guard try FileManager.default.contentsOfDirectory(atPath: installedRoot.path).contains(plan.id.uuidString),
              try FileManager.default.contentsOfDirectory(atPath: record.directory.deletingLastPathComponent().path).contains("model") else {
            throw NativeModelUsageError.invalidOwnership
        }
        let files = Set(plan.files.map(\.relativeDestination)).union(["installation-manifest.json"])
        var directories = Set<String>()
        for path in files {
            let components = path.split(separator: "/")
            for depth in 1..<components.count { directories.insert(components.prefix(depth).joined(separator: "/")) }
        }
        guard let entries = FileManager.default.enumerator(at: record.directory, includingPropertiesForKeys: nil) else { throw NativeModelUsageError.invalidOwnership }
        var count = 0
        while let file = entries.nextObject() as? URL {
            count += 1; guard count <= 100_000 else { throw NativeModelUsageError.invalidOwnership }
            try Self.noSymlinks(file)
            let relative = String(file.path.dropFirst(record.directory.path.count + 1))
            let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            guard (type == .typeDirectory && directories.contains(relative)) || (type == .typeRegular && files.contains(relative)) else {
                throw NativeModelUsageError.invalidOwnership
            }
        }
    }

    private func committedManifest(for plan: ASRInstallPlan) throws -> Manifest {
        let destination = directory(for: plan)
        try Self.noSymlinks(destination)
        let manifest = try Self.readManifest(destination.appendingPathComponent("installation-manifest.json"))
        guard manifest.version == 1, manifest.record.id == plan.id, manifest.record.installPlan == plan,
              manifest.record.directory == destination, manifest.record.importedModelID != plan.id,
              manifest.record.ownership == .managed else { throw HFDownloadError(code: .integrity) }
        return manifest
    }
    private static func verify(_ plan: ASRInstallPlan, directory: URL) async throws {
        for file in plan.files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.relativeDestination)
            try noSymlinks(url)
            try await HFFileVerifier.verifyAsync(file: file, at: url)
        }
        // Unexpected payloads and transport sidecars cannot become installed content.
        let expected = Set(plan.files.map(\.relativeDestination)).union(["installation-manifest.json"])
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw HFDownloadError(code: .integrity) }
        var count = 0
        while let url = entries.nextObject() as? URL {
            count += 1; guard count <= 100_000 else { throw HFDownloadError(code: .integrity) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw HFDownloadError(code: .integrity) }
            if values.isRegularFile == true {
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                guard expected.contains(relative) else { throw HFDownloadError(code: .integrity) }
            }
        }
    }
    private static func readManifest(_ url: URL) throws -> Manifest {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= 32 * 1024 * 1024 else { throw HFDownloadError(code: .integrity) }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    /// Reject every existing symlink component, including ancestors of injected roots.
    static func noSymlinks(_ url: URL) throws {
        guard url.isFileURL else { throw HFDownloadError(code: .integrity) }
        var cursor = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            cursor.appendPathComponent(part)
            var value = stat()
            if lstat(cursor.path, &value) == 0 {
                guard value.st_mode & S_IFMT != S_IFLNK else { throw HFDownloadError(code: .integrity) }
            } else if errno != ENOENT { throw HFDownloadError.disk(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
        }
    }
    static func ensureDirectory(_ url: URL) throws {
        try noSymlinks(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

extension ModelInstallationPublisher {
    /// Cleanup authority is the matching durable job plus an exact physical staging inventory.
    /// Never treats a decoded arbitrary directory, symlink, hardlink or unplanned file as owned.
    func validatePartialRemoval(job: ModelInstallationJobJournal, journalRoot: URL,
                                configuration: Configuration) throws {
        let plan = job.snapshot.plan, id = job.snapshot.jobID
        guard job.version == 1, id == plan.id, !job.libraryDetached,
              journalRoot.standardizedFileURL.path == jobsRoot.standardizedFileURL.path else {
            throw NativeModelUsageError.invalidOwnership
        }
        try Self.validate(plan)
        let parent = jobsRoot.appendingPathComponent(id.uuidString), stage = parent.appendingPathComponent("model")
        try Self.noSymlinks(stage)
        try Self.noSymlinks(directory(for: plan))
        guard !FileManager.default.fileExists(atPath: directory(for: plan).path),
              !configuration.installedASRModels.contains(where: { $0.id == id || $0.installPlan?.id == id }),
              try FileManager.default.contentsOfDirectory(atPath: jobsRoot.path).contains(id.uuidString) else {
            throw NativeModelUsageError.invalidOwnership
        }
        let journalURL = parent.appendingPathComponent("job.json")
        try Self.noSymlinks(journalURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              (attributes[.size] as? NSNumber)?.int64Value ?? .max <= 32 * 1024 * 1024 else {
            throw NativeModelUsageError.invalidOwnership
        }
        let saved = try JSONDecoder().decode(ModelInstallationJobJournal.self, from: Data(contentsOf: journalURL))
        guard saved.version == job.version, saved.snapshot == job.snapshot,
              saved.createdAt == job.createdAt, saved.libraryDetached == job.libraryDetached else {
            throw NativeModelUsageError.invalidOwnership
        }
        let key = stage.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        for url in configuration.importedASRModels.map(\.directory) + configuration.installedASRModels.map(\.directory) {
            let other = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            guard other != key, !other.hasPrefix(key + "/"), !key.hasPrefix(other + "/") else {
                throw NativeModelUsageError.invalidOwnership
            }
        }
        guard FileManager.default.fileExists(atPath: stage.path) else { return }
        guard try FileManager.default.contentsOfDirectory(atPath: parent.path).contains("model"),
              try FileManager.default.attributesOfItem(atPath: stage.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw NativeModelUsageError.invalidOwnership
        }
        let payloads = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.relativeDestination, $0) })
        let sidecars = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.relativeDestination + ".hf-journal.json", $0) })
        let files = Set(payloads.keys).union(sidecars.keys).union(["installation-manifest.json"])
        var directories = Set<String>()
        for path in files {
            let components = path.split(separator: "/")
            for depth in 1..<components.count { directories.insert(components.prefix(depth).joined(separator: "/")) }
        }
        guard let entries = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: nil) else {
            throw NativeModelUsageError.invalidOwnership
        }
        var count = 0
        while let file = entries.nextObject() as? URL {
            count += 1; guard count <= 100_000 else { throw NativeModelUsageError.invalidOwnership }
            try Self.noSymlinks(file)
            let relative = String(file.path.dropFirst(stage.path.count + 1))
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                guard directories.contains(relative) else { throw NativeModelUsageError.invalidOwnership }
                continue
            }
            guard attrs[.type] as? FileAttributeType == .typeRegular, files.contains(relative),
                  (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw NativeModelUsageError.invalidOwnership }
            if let planned = payloads[relative] {
                guard (attrs[.size] as? NSNumber)?.int64Value ?? .max <= planned.sizeBytes else { throw NativeModelUsageError.invalidOwnership }
            } else if let planned = sidecars[relative] {
                let saved = try HFDownloadJournal.read(for: stage.appendingPathComponent(planned.relativeDestination))
                guard saved.file == planned, saved.credentialID == plan.credentialID else { throw NativeModelUsageError.invalidOwnership }
            } else {
                let manifest = try Self.readManifest(file)
                guard manifest.version == 1, manifest.record.id == id, manifest.record.installPlan == plan,
                      manifest.record.ownership == .managed, manifest.record.directory == directory(for: plan) else {
                    throw NativeModelUsageError.invalidOwnership
                }
            }
        }
    }
}
