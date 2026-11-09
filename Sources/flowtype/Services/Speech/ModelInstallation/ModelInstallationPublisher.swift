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
    func publish(plan: ASRInstallPlan, staging: URL, permit: ModelPublicationPermit) async throws -> ASRInstalledModelRecord {
        try Self.validate(plan)
        // Coordinator binds jobID to plan.id. Only that UUID's managed staging is movable.
        let ownedStaging = jobsRoot.appendingPathComponent(plan.id.uuidString, isDirectory: true).appendingPathComponent("model", isDirectory: true)
        guard staging.isFileURL, staging.standardizedFileURL.path == ownedStaging.standardizedFileURL.path else {
            throw HFDownloadError(code: .integrity)
        }
        try Self.ensureDirectory(installedRoot)
        let destination = directory(for: plan)
        try Self.ensureDirectory(destination.deletingLastPathComponent())
        let manifestURL = destination.appendingPathComponent("installation-manifest.json")
        let manifest: Manifest
        if FileManager.default.fileExists(atPath: destination.path) {
            // A prior rename is already committed. No replacement, even if its manifest is invalid.
            try Self.noSymlinks(destination)
            manifest = try Self.readManifest(manifestURL)
            guard manifest.version == 1, manifest.record.id == plan.id, manifest.record.installPlan == plan,
                  manifest.record.directory == destination, manifest.record.importedModelID != plan.id,
                  manifest.record.ownership == .managed else { throw HFDownloadError(code: .integrity) }
            try Self.verify(plan, directory: destination)
        } else {
            try Self.noSymlinks(staging)
            // Staging and final roots must share a filesystem. rename never falls back to copy.
            var from = stat(), to = stat()
            guard lstat(staging.path, &from) == 0, lstat(installedRoot.path, &to) == 0,
                  from.st_dev == to.st_dev else { throw HFDownloadError(code: .integrity) }
            try Self.verify(plan, directory: staging)
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
    private static func verify(_ plan: ASRInstallPlan, directory: URL) throws {
        for file in plan.files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.relativeDestination)
            try noSymlinks(url)
            try HFFileVerifier.verify(file: file, at: url)
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
