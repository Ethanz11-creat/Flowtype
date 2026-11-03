import Foundation
import Darwin
import CryptoKit

enum PackagingFailure: String, Error { case usage, sourceInvalid, shaderInvalid, buildFailed, signFailed, inUse, journalInvalid, restoreFailed, manifestInvalid, artifactFailed, interrupted, toolFailed }
struct PackagingMetadata: Codable, Equatable {
    let schemaVersion: Int; let version: String; let buildNumber: String; let gitSHA: String
    let sourceTree: String; let builtAt: String; let dirty: Bool
}
struct ResourceDigest: Codable, Equatable { let path: String; let sha256: String }
struct PackagingManifest: Codable, Equatable {
    let schemaVersion: Int; let buildInfo: PackagingMetadata; let architecture: String
    let binarySHA256: String; let buildInfoSHA256: String; let shaderSHA256: String
    let resources: [ResourceDigest]
}
func packagingHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func packagingFingerprint(_ input: URL) throws -> String {
    let url = try canonicalExisting(input)
    var rows: [String] = []
    let fm = FileManager.default
    let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    if !isDirectory { return try packagingHash(url) }
    let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
    while let file = e.nextObject() as? URL {
        let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard v.isSymbolicLink != true else { throw PackagingFailure.manifestInvalid }
        if v.isRegularFile == true { rows.append(String(file.path.dropFirst(url.path.count)) + ":" + (try packagingHash(file))) }
    }
    return SHA256.hash(data: Data(rows.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
}
struct PackagingAdapters {
    let releaseBuild: (URL, URL) throws -> URL
    let releaseDirectory: (URL, URL) throws -> URL
    let generateIdentity: (URL, URL, String, URL) throws -> Void
    let writeManifest: (URL, URL, URL) throws -> Void
    let sign: (URL, URL) throws -> Void
    let verify: (URL, URL) throws -> Void
    let inUse: (URL, URL) throws -> Bool
    let artifact: (URL, URL, URL, (Int32) throws -> Void) throws -> BoundedResult
}
// Written once before handlers are installed, then read only by the handler.
// Cancellation state travels through the pipe; no Swift lock/allocation occurs in the handler.
nonisolated(unsafe) private var packagingSignalWriteFD: Int32 = -1
private func packagingSignalHandler(_ number: Int32) {
    let saved = errno
    var byte: UInt8 = 1
    _ = Darwin.write(packagingSignalWriteFD, &byte, 1)
    errno = saved
}
final class PackagingCancellation {
    private let lock = NSLock()
    private var readFD: Int32 = -1
    private var observed = false
    func install() throws {
        guard readFD == -1 else { return }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw PackagingFailure.toolFailed }
        for fd in descriptors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        readFD = descriptors[0]; packagingSignalWriteFD = descriptors[1]
        signal(SIGTERM, packagingSignalHandler); signal(SIGINT, packagingSignalHandler)
    }
    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if readFD >= 0 {
            var byte: UInt8 = 0
            if Darwin.read(readFD, &byte, 1) > 0 { observed = true }
        }
        return observed
    }
}
let packagingCancellation = PackagingCancellation()
func packagingCommand(_ executable: String, _ args: [String], cwd: URL, logs: URL, timeout: Double = 60,
                      onLaunch: (Int32) throws -> Void = { _ in }) throws -> (BoundedResult, Data) {
    let id = UUID().uuidString
    let out = logs.appendingPathComponent(id + ".stdout"), err = logs.appendingPathComponent(id + ".stderr")
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
    let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: executable), arguments: args,
        workingDirectory: cwd, environment: env, stdoutURL: out, stderrURL: err, timeoutSeconds: timeout),
        shouldCancel: { packagingCancellation.isCancelled() }, onLaunch: onLaunch)
    guard !packagingCancellation.isCancelled() else { throw PackagingFailure.interrupted }
    return (result, try Data(contentsOf: out))
}
func packagingGit(_ args: [String], repo: URL, logs: URL) throws -> String {
    let (result, bytes) = try packagingCommand("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args, cwd: repo, logs: logs)
    guard result.cliExitCode == 0 else { throw PackagingFailure.sourceInvalid }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
}
func packagingSnapshot(repo: URL, logs: URL) throws -> String {
    guard try packagingGit(["rev-parse", "--is-shallow-repository"], repo: repo, logs: logs) == "false",
          try packagingGit(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], repo: repo, logs: logs).isEmpty else { throw PackagingFailure.sourceInvalid }
    return try packagingGit(["rev-parse", "HEAD"], repo: repo, logs: logs)
}
func packagingCandidateInUse(_ app: URL, _ logs: URL) throws -> Bool {
    let binary = app.appendingPathComponent("Contents/MacOS/FlowType")
    guard FileManager.default.fileExists(atPath: binary.path) else { return false }
    let (result, _) = try packagingCommand("/usr/sbin/lsof", ["-t", binary.path], cwd: app.deletingLastPathComponent(), logs: logs)
    guard result.termination == .normal, result.exitCode == 0 || result.exitCode == 1 else { throw PackagingFailure.inUse }
    return result.exitCode == 0
}
func canonicalExisting(_ url: URL) throws -> URL {
    guard let value = realpath(url.path, nil) else { throw PackagingFailure.restoreFailed }
    defer { free(value) }
    return URL(fileURLWithPath: String(cString: value))
}
func resourceDigests(_ input: URL) throws -> [ResourceDigest] {
    let app = try canonicalExisting(input)
    let root = app.appendingPathComponent("Contents/Resources")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw PackagingFailure.manifestInvalid }
    var rows: [ResourceDigest] = []
    while let file = e.nextObject() as? URL {
        let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard v.isSymbolicLink != true else { throw PackagingFailure.manifestInvalid }
        if v.isRegularFile == true { rows.append(ResourceDigest(path: String(file.path.dropFirst(app.path.count + 1)), sha256: try packagingHash(file))) }
    }
    return rows.sorted { $0.path < $1.path }
}
func validateManifest(app: URL, file: URL) throws -> PackagingManifest {
    let m = try JSONDecoder().decode(PackagingManifest.self, from: Data(contentsOf: file))
    let infoURL = app.appendingPathComponent("Contents/Resources/FlowTypeBuild.json")
    let metadata = try JSONDecoder().decode(PackagingMetadata.self, from: Data(contentsOf: infoURL))
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
    guard m.schemaVersion == 1, m.architecture == "arm64", metadata == m.buildInfo, !metadata.dirty, metadata.schemaVersion == 1,
          plist?["CFBundleShortVersionString"] as? String == metadata.version,
          plist?["CFBundleVersion"] as? String == metadata.buildNumber,
          try m.binarySHA256 == packagingHash(app.appendingPathComponent("Contents/MacOS/FlowType")),
          try m.buildInfoSHA256 == packagingHash(infoURL),
          try m.shaderSHA256 == packagingHash(app.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")),
          m.resources.allSatisfy({ $0.path.hasPrefix("Contents/Resources/") && !$0.path.split(separator: "/").contains("..") }),
          try m.resources == resourceDigests(app) else { throw PackagingFailure.manifestInvalid }
    return m
}
struct PublicationJournal: Codable {
    let token: String; var committed: Bool
    let oldApp: String?; let oldManifest: String?; let newApp: String; let newManifest: String
}
struct HiddenResource: Codable { let name: String; let fingerprint: String }
struct HidingJournal: Codable {
    let token: String; let releaseDirectory: String; let ownerPID: Int32
    var innerPID: Int32?; let resources: [HiddenResource]
}
struct PackagingArtifactIdentity: Decodable {
    let origin: String; let metadata: PackagingMetadata?; let failureCode: String?
}
struct PackagingArtifactReport: Decodable {
    let schemaVersion: Int; let mode: String; let ok: Bool; let role: String; let runID: String
    let buildInfo: PackagingArtifactIdentity; let durationMs: Int; let failureCode: String?
    let appResources: Bool; let metalLibrary: Bool; let mlxOperation: Bool; let resolvedInsideApp: Bool
}
final class PackagingLock {
    private let fd: Int32
    init(_ build: URL) throws {
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        guard try build.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw PackagingFailure.journalInvalid }
        fd = open(build.appendingPathComponent(".m5-artifact.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PackagingFailure.journalInvalid }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PackagingFailure.inUse }
    }
    deinit { _ = flock(fd, LOCK_UN); close(fd) }
}
struct ArtifactPackager {
    let repo: URL
    let adapters: PackagingAdapters
    var build: URL { repo.appendingPathComponent("build") }
    var publicationURL: URL { build.appendingPathComponent(".m5-publication.json") }
    var hidingURL: URL { build.appendingPathComponent(".m5-resources.json") }
    private let fm = FileManager.default
    /// Recovery reuses this exact journal/lock implementation. No build/sign/artifact adapter can run.
    static func recoverOwned(repository: URL) throws {
        let adapters = PackagingAdapters(releaseBuild: { _, _ in throw PackagingFailure.toolFailed }, releaseDirectory: { _, _ in throw PackagingFailure.toolFailed },
            generateIdentity: { _, _, _, _ in throw PackagingFailure.toolFailed }, writeManifest: { _, _, _ in throw PackagingFailure.toolFailed },
            sign: { _, _ in throw PackagingFailure.toolFailed }, verify: { _, _ in throw PackagingFailure.toolFailed },
            inUse: packagingCandidateInUse, artifact: { _, _, _, _ in throw PackagingFailure.toolFailed })
        try ArtifactPackager(repo: repository, adapters: adapters).recover()
    }
    func write<T: Encodable>(_ value: T, to url: URL) throws { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
    func stage(_ token: String) -> URL { build.appendingPathComponent(".m5-stage-" + token) }
    func requireReleaseDirectory(_ directory: URL) throws {
        let repository = try canonicalExisting(repo).path
        guard try canonicalExisting(repo.appendingPathComponent(".build")).path == repository + "/.build",
              try canonicalExisting(directory).path.hasPrefix(repository + "/.build/"), directory.lastPathComponent == "release" else {
            throw PackagingFailure.journalInvalid
        }
    }
    func cleanupStage(_ token: String) throws {
        let directory = stage(token)
        if exists(directory) {
            guard try String(contentsOf: directory.appendingPathComponent(".owner"), encoding: .utf8) == token else { throw PackagingFailure.journalInvalid }
            try fm.removeItem(at: directory)
        }
    }
    func recoverPublication() throws {
        guard exists(publicationURL) else { return }
        let j = try JSONDecoder().decode(PublicationJournal.self, from: Data(contentsOf: publicationURL))
        guard UUID(uuidString: j.token) != nil else { throw PackagingFailure.journalInvalid }
        let app = build.appendingPathComponent("FlowType.app"), manifest = build.appendingPathComponent("FlowType.manifest.json")
        let backupApp = build.appendingPathComponent(".m5-backup-\(j.token).app")
        let backupManifest = build.appendingPathComponent(".m5-backup-\(j.token).manifest.json")
        // Recovery can run before buildApp's ordinary in-use guard. Preserve any active candidate/backup.
        let recoveryLogs = build.appendingPathComponent("recovery-\(UUID())")
        try fm.createDirectory(at: recoveryLogs, withIntermediateDirectories: false)
        for candidate in [app, backupApp] where exists(candidate) {
            guard try !adapters.inUse(candidate, recoveryLogs) else { throw PackagingFailure.inUse }
        }
        func hash(_ url: URL) throws -> String { try packagingFingerprint(url) }
        func restore(_ current: URL, _ backup: URL, old: String?, new: String) throws {
            func retainNew() throws {
                let owned = stage(j.token)
                if !exists(owned) {
                    try fm.createDirectory(at: owned, withIntermediateDirectories: false)
                    try Data(j.token.utf8).write(to: owned.appendingPathComponent(".owner"))
                }
                guard try String(contentsOf: owned.appendingPathComponent(".owner"), encoding: .utf8) == j.token else { throw PackagingFailure.journalInvalid }
                let target = owned.appendingPathComponent(current.lastPathComponent)
                guard !exists(target) else { throw PackagingFailure.restoreFailed }
                try fm.moveItem(at: current, to: target)
            }
            if exists(backup) {
                guard let old, try hash(backup) == old else { throw PackagingFailure.journalInvalid }
                if exists(current) { guard try hash(current) == new else { throw PackagingFailure.restoreFailed }; try retainNew() }
                try fm.moveItem(at: backup, to: current)
            } else if let old {
                guard exists(current), try hash(current) == old else { throw PackagingFailure.restoreFailed }
            } else if exists(current) {
                guard try hash(current) == new else { throw PackagingFailure.restoreFailed }; try retainNew()
            }
        }
        if j.committed {
            guard try hash(app) == j.newApp, try hash(manifest) == j.newManifest else { throw PackagingFailure.manifestInvalid }
            for (backup, expected) in [(backupApp, j.oldApp), (backupManifest, j.oldManifest)] where exists(backup) {
                guard let expected, try hash(backup) == expected else { throw PackagingFailure.journalInvalid }; try fm.removeItem(at: backup)
            }
        } else {
            try restore(app, backupApp, old: j.oldApp, new: j.newApp)
            try restore(manifest, backupManifest, old: j.oldManifest, new: j.newManifest)
        }
        if j.committed { try cleanupStage(j.token) }
        try fm.removeItem(at: publicationURL)
    }
    func recoverResources() throws {
        guard exists(hidingURL) else { return }
        let j = try JSONDecoder().decode(HidingJournal.self, from: Data(contentsOf: hidingURL))
        guard UUID(uuidString: j.token) != nil, j.ownerPID > 1,
              j.ownerPID == getpid() || kill(j.ownerPID, 0) != 0 else { throw PackagingFailure.restoreFailed }
        if let pid = j.innerPID { guard pid > 1, kill(pid, 0) != 0, kill(-pid, 0) != 0 else { throw PackagingFailure.restoreFailed } }
        let directory = URL(fileURLWithPath: j.releaseDirectory)
        try requireReleaseDirectory(directory)
        for row in j.resources {
            guard row.name.hasSuffix(".bundle"), !row.name.contains("/"), !row.name.hasPrefix(".") else { throw PackagingFailure.journalInvalid }
            let original = directory.appendingPathComponent(row.name)
            let hidden = directory.appendingPathComponent(".m5-hidden-\(j.token)-\(row.name)")
            if exists(hidden) {
                guard !exists(original), try packagingFingerprint(hidden) == row.fingerprint else { throw PackagingFailure.restoreFailed }
                try fm.moveItem(at: hidden, to: original)
            } else { guard exists(original), try packagingFingerprint(original) == row.fingerprint else { throw PackagingFailure.restoreFailed } }
        }
        try fm.removeItem(at: hidingURL)
    }
    func recoverUnlocked() throws { try recoverResources(); try recoverPublication() }
    func recover() throws { let lock = try PackagingLock(build); defer { withExtendedLifetime(lock) {} }; try recoverUnlocked() }
    func buildApp(shader: URL?, version: String) throws {
        let lock = try PackagingLock(build); defer { withExtendedLifetime(lock) {} }
        try recoverUnlocked()
        let logs = build.appendingPathComponent("packaging-\(UUID())"); try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        guard version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil else { throw PackagingFailure.sourceInvalid }
        let before = try packagingSnapshot(repo: repo, logs: logs)
        guard let shader, let size = try? shader.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true,
              (size.fileSize ?? 0) >= 1_048_576 else { throw PackagingFailure.shaderInvalid }
        let input = try FileHandle(forReadingFrom: shader); let magic = try input.read(upToCount: 4); try input.close()
        guard magic == Data("MTLB".utf8) else { throw PackagingFailure.shaderInvalid }
        let final = build.appendingPathComponent("FlowType.app"), finalManifest = build.appendingPathComponent("FlowType.manifest.json")
        guard try !adapters.inUse(final, logs) else { throw PackagingFailure.inUse }
        let token = UUID().uuidString
        let directory = stage(token)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(token.utf8).write(to: directory.appendingPathComponent(".owner"))
        do {
            let app = directory.appendingPathComponent("FlowType.app"), resources = app.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let mlx = resources.appendingPathComponent("mlx-swift_Cmlx.bundle")
            try fm.createDirectory(at: mlx, withIntermediateDirectories: false)
            // Copy the explicit existing shader before any candidate rename (it may come from that candidate).
            try fm.copyItem(at: shader, to: mlx.appendingPathComponent("default.metallib"))
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.mlx-swift.Cmlx", "CFBundleName": "mlx-swift_Cmlx", "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: mlx.appendingPathComponent("Info.plist"))
            let bin = try adapters.releaseBuild(repo, logs)
            try requireReleaseDirectory(bin)
            guard try packagingSnapshot(repo: repo, logs: logs) == before else { throw PackagingFailure.sourceInvalid }
            try fm.copyItem(at: bin.appendingPathComponent("FlowType"), to: app.appendingPathComponent("Contents/MacOS/FlowType"))
            for bundle in try fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: [.isDirectoryKey]).filter({ $0.pathExtension == "bundle" }) {
                // Cmlx's standard wrapper was just populated from the explicit shader input.
                if bundle.lastPathComponent == "mlx-swift_Cmlx.bundle" {
                    for file in try fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) where !["default.metallib", "Info.plist"].contains(file.lastPathComponent) {
                        try fm.copyItem(at: file, to: mlx.appendingPathComponent(file.lastPathComponent))
                    }
                } else { try fm.copyItem(at: bundle, to: resources.appendingPathComponent(bundle.lastPathComponent)) }
            }
            let generated = directory.appendingPathComponent("identity"); try fm.createDirectory(at: generated, withIntermediateDirectories: false)
            try adapters.generateIdentity(repo, generated, version, logs)
            try fm.copyItem(at: generated.appendingPathComponent("Info.plist"), to: app.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: generated.appendingPathComponent("FlowTypeBuild.json"), to: resources.appendingPathComponent("FlowTypeBuild.json"))
            let icon = resources.appendingPathComponent("FlowType_FlowType.bundle/AppIcon.icns")
            if exists(icon) { try fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns")) }
            try adapters.sign(app, logs); try adapters.verify(app, logs)
            let manifest = directory.appendingPathComponent("FlowType.manifest.json")
            try adapters.writeManifest(app, manifest, logs)
            _ = try validateManifest(app: app, file: manifest)
            guard !packagingCancellation.isCancelled(), try packagingSnapshot(repo: repo, logs: logs) == before,
                  try !adapters.inUse(final, logs) else { throw PackagingFailure.sourceInvalid }
            var journal = try PublicationJournal(token: token, committed: false,
                oldApp: exists(final) ? packagingFingerprint(final) : nil, oldManifest: exists(finalManifest) ? packagingFingerprint(finalManifest) : nil,
                newApp: packagingFingerprint(app), newManifest: packagingFingerprint(manifest))
            try write(journal, to: publicationURL)
            if exists(final) { try fm.moveItem(at: final, to: build.appendingPathComponent(".m5-backup-\(token).app")) }
            if exists(finalManifest) { try fm.moveItem(at: finalManifest, to: build.appendingPathComponent(".m5-backup-\(token).manifest.json")) }
            try fm.moveItem(at: app, to: final); try fm.moveItem(at: manifest, to: finalManifest)
            _ = try validateManifest(app: final, file: finalManifest)
            journal.committed = true; try write(journal, to: publicationURL)
            try recoverPublication()
        } catch {
            // Preserve failed, owned staging contents for diagnosis. Rollback also retains new bytes there.
            if exists(publicationURL) { try recoverPublication() }
            throw error
        }
    }
    func checkApp(app: URL, output: URL) throws {
        let lock = try PackagingLock(build); defer { withExtendedLifetime(lock) {} }
        try recoverUnlocked()
        guard app.path.hasPrefix("/"), try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try fm.contentsOfDirectory(atPath: output.path).isEmpty else { throw PackagingFailure.usage }
        let temporary = fm.temporaryDirectory.appendingPathComponent("flowtype-moved-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        guard try !canonicalExisting(temporary).path.hasPrefix(canonicalExisting(repo).path + "/") else { throw PackagingFailure.manifestInvalid }
        var restored = true
        do {
            let manifestFile = app.deletingLastPathComponent().appendingPathComponent("FlowType.manifest.json")
            let manifest = try validateManifest(app: app, file: manifestFile)
            func actualHashes(_ target: URL) throws -> [String: String] {
                ["binary": try packagingHash(target.appendingPathComponent("Contents/MacOS/FlowType")),
                 "metadata": try packagingHash(target.appendingPathComponent("Contents/Resources/FlowTypeBuild.json")),
                 "shader": try packagingHash(target.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"))]
            }
            let hashesBefore = try actualHashes(app)
            try adapters.verify(app, output)
            let moved = temporary.appendingPathComponent("FlowType.app")
            try fm.copyItem(at: app, to: moved)
            _ = try validateManifest(app: moved, file: manifestFile); try adapters.verify(moved, output)
            let bin = try adapters.releaseDirectory(repo, output)
            try requireReleaseDirectory(bin)
            let bundles = try fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.pathExtension == "bundle" }
            guard !bundles.isEmpty else { throw PackagingFailure.manifestInvalid }
            let token = UUID().uuidString
            var marker = try HidingJournal(token: token, releaseDirectory: bin.path, ownerPID: getpid(), innerPID: nil,
                resources: bundles.map { HiddenResource(name: $0.lastPathComponent, fingerprint: try packagingFingerprint($0)) })
            try write(marker, to: hidingURL); restored = false
            for bundle in bundles { try fm.moveItem(at: bundle, to: bin.appendingPathComponent(".m5-hidden-\(token)-\(bundle.lastPathComponent)")) }
            let validation = output.appendingPathComponent("validation-root")
            let result = try adapters.artifact(moved, validation, output) { pid in marker.innerPID = pid; try write(marker, to: hidingURL) }
            try recoverResources(); restored = true
            guard result.cliExitCode == 0, !result.timedOut else { throw PackagingFailure.artifactFailed }
            let bytes = try Data(contentsOf: output.appendingPathComponent("artifact.stdout"))
            let line = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let report: PackagingArtifactReport
            do { report = try JSONDecoder().decode(PackagingArtifactReport.self, from: bytes) } catch { throw PackagingFailure.artifactFailed }
            guard line.count == 2, line.last == "", report.schemaVersion == 1, report.mode == "artifact", report.role == "smokeTest",
                  report.ok, report.failureCode == nil, UUID(uuidString: report.runID) != nil, report.durationMs >= 0,
                  report.appResources, report.metalLibrary, report.mlxOperation, report.resolvedInsideApp,
                  report.buildInfo.origin == "packaged", report.buildInfo.failureCode == nil,
                  report.buildInfo.metadata == manifest.buildInfo else { throw PackagingFailure.artifactFailed }
            let reportObject = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            guard reportObject["failureCode"] is NSNull, (reportObject["buildInfo"] as? [String: Any])?["failureCode"] is NSNull else { throw PackagingFailure.artifactFailed }
            _ = try validateManifest(app: moved, file: manifestFile); _ = try validateManifest(app: app, file: manifestFile)
            try adapters.verify(moved, output)
            let hashesAfter = try actualHashes(moved)
            guard hashesBefore == hashesAfter else { throw PackagingFailure.manifestInvalid }
            let evidence: [String: Any] = ["schemaVersion": 1, "ok": true, "failureCode": NSNull(), "signature": true,
                "resourcesHidden": true, "resourcesRestored": true, "hashesBefore": hashesBefore, "hashesAfter": hashesAfter,
                "sourceCommit": manifest.buildInfo.gitSHA, "artifact": reportObject]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("check-result.json"))
        } catch {
            var failure = (error as? PackagingFailure) ?? .toolFailed
            if !restored { do { try recoverResources(); restored = true } catch { failure = .restoreFailed } }
            let evidence: [String: Any] = ["schemaVersion": 1, "ok": false, "failureCode": failure.rawValue, "resourcesRestored": restored]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("check-result.json"))
            throw failure
        }
    }
}
