import Foundation
import Darwin

// Standalone wire records: this tool never imports the product's @main module.
enum VerificationStatus: String, Codable { case pass = "Pass", fail = "Fail", pending = "Pending", skip = "Skip" }
enum VerificationLane: String, Codable { case code, artifact, release }
enum VerificationFailure: String, Error, Codable {
    case usage
    case platformUnsupported, sourceInvalid, sourceChanged, dirtySource, shallowHistory, buildFailed, fullTestFailed
    case signatureFailed, artifactFailed, smokeFailed, malformedReport, identityMismatch, duplicateRunID
    case timedOut, windowServerUnavailable, recoveryFailed, outputUnavailable, notExecuted, toolFailed
}
struct BuildMetadataRecord: Codable, Equatable {
    let schemaVersion: Int; let version: String; let buildNumber: String; let gitSHA: String
    let sourceTree: String; let builtAt: String; let dirty: Bool
}
struct ArtifactResourceRecord: Codable, Equatable { let path: String; let sha256: String }
struct ArtifactManifest: Codable, Equatable {
    let schemaVersion: Int; let buildInfo: BuildMetadataRecord; let architecture: String
    let binarySHA256: String; let buildInfoSHA256: String; let shaderSHA256: String
    let resources: [ArtifactResourceRecord]
}
struct SourceIdentity: Codable, Equatable { let gitSHA: String; let sourceTree: String; let dirty: Bool }
struct SourceSnapshot: Equatable { let identity: SourceIdentity; let fingerprint: String; let shallow: Bool }
struct VerificationPhase: Codable {
    let name: String; var status: VerificationStatus; var exitCode: Int32? = nil; var timedOut = false
    var failureCode: VerificationFailure? = nil; var evidence: [String] = []
    enum CodingKeys: String, CodingKey { case name, status, exitCode, timedOut, failureCode, evidence }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(status, forKey: .status); try c.encode(exitCode, forKey: .exitCode)
        try c.encode(timedOut, forKey: .timedOut); try c.encode(failureCode, forKey: .failureCode); try c.encode(evidence, forKey: .evidence)
    }
}
struct VerificationReport: Codable {
    let schemaVersion: Int; let runID: String; let lane: VerificationLane
    var status: VerificationStatus; var sourceIdentity: SourceIdentity?; var artifactIdentity: ArtifactManifest?
    var phases: [VerificationPhase]; var manualStatus: VerificationStatus; var ciStatus: VerificationStatus
    var manualCases: [ManualCaseResult]? = nil
    var manualIssues: [ManualValidationIssue]? = nil
    var exitCode: Int32 { status == .pass ? 0 : status == .fail ? 1 : 2 }
    enum CodingKeys: String, CodingKey { case schemaVersion, runID, lane, status, sourceIdentity, artifactIdentity, phases, manualStatus, ciStatus, manualCases, manualIssues }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(runID, forKey: .runID); try c.encode(lane, forKey: .lane)
        try c.encode(status, forKey: .status); try c.encode(sourceIdentity, forKey: .sourceIdentity); try c.encode(artifactIdentity, forKey: .artifactIdentity)
        try c.encode(phases, forKey: .phases); try c.encode(manualStatus, forKey: .manualStatus); try c.encode(ciStatus, forKey: .ciStatus)
        try c.encode(manualCases, forKey: .manualCases); try c.encode(manualIssues, forKey: .manualIssues)
    }
}
struct VerificationCommand {
    let phase: String; let command: BoundedCommand; let childRoot: URL; let validationRoot: URL; let checkOutput: URL
}
struct VerificationDependencies {
    let execute: (VerificationCommand) throws -> BoundedResult
    let snapshot: (URL, URL) throws -> SourceSnapshot
    let manifest: (URL) throws -> ArtifactManifest
    let recover: (URL) throws -> Void
    let ciCode: Bool
    var writeReport: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
}

enum VerificationCapability {
    static func operatingSystem(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"\A[0-9]+(?:\.[0-9]+){0,2}\z"#, options: .regularExpression) != nil,
              let major = Int(text.split(separator: ".")[0]) else { return false }
        return major >= 15
    }
    static func architecture(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" }
    static func swiftVersion(_ value: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: #"(?:Apple )?Swift version ([0-9]+)\.([0-9]+)(?:\.[0-9]+)?(?:\s|$)"#)
        guard let m = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              let a = Range(m.range(at: 1), in: value), let b = Range(m.range(at: 2), in: value),
              let major = Int(value[a]), let minor = Int(value[b]) else { return false }
        return major > 6 || major == 6 && minor >= 2
    }
}
enum VerificationEvidence {
    private struct BootstrapFailure: Decodable { let schemaVersion: Int; let status: VerificationStatus; let failureCode: String }
    private static let fm = FileManager.default
    private static func encoded(_ report: VerificationReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(report)
    }
    /// Walk literal components before reading any bytes. Missing partial-run files are permitted.
    private static func file(_ relative: String, under root: URL) throws -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !relative.hasPrefix("/") else { throw VerificationFailure.outputUnavailable }
        var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            guard (try? fm.destinationOfSymbolicLink(atPath: current.path)) == nil else { throw VerificationFailure.outputUnavailable }
            guard fm.fileExists(atPath: current.path) else { return nil }
            guard try canonicalExisting(current).path == current.path else { throw VerificationFailure.outputUnavailable }
            let info = try current.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard index == parts.count - 1 ? info.isRegularFile == true : info.isDirectory == true else { throw VerificationFailure.outputUnavailable }
        }
        return current
    }
    private static func ownedRoot(_ root: URL) throws -> URL {
        let literal = root // standardizedFileURL rewrites macOS /private/var; preserve literal ownership paths.
        guard UUID(uuidString: literal.lastPathComponent) != nil,
              literal.deletingLastPathComponent().lastPathComponent == "verification",
              literal.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "build",
              try canonicalExisting(literal).path == literal.path else { throw VerificationFailure.outputUnavailable }
        let repo = literal.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard try VerificationPaths.prepare(repository: repo).path == literal.deletingLastPathComponent().path else { throw VerificationFailure.outputUnavailable }
        return literal
    }
    private static func emptyDestination(_ destination: URL, runRoot: URL) throws -> URL {
        let literal = destination
        guard try canonicalExisting(literal).path == literal.path,
              try literal.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !literal.path.hasPrefix(runRoot.path + "/"), literal.path != runRoot.path,
              try fm.contentsOfDirectory(atPath: literal.path).isEmpty else { throw VerificationFailure.outputUnavailable }
        return literal
    }
    private static func selected(_ root: URL) throws -> (String, VerificationReport)? {
        let original = try file("verify-report.json", under: root), partial = try file("verify-report.partial.json", under: root)
        func decode(_ url: URL) throws -> VerificationReport {
            let report = try JSONDecoder().decode(VerificationReport.self, from: Data(contentsOf: url))
            guard report.schemaVersion == 1, UUID(uuidString: report.runID) == UUID(uuidString: root.lastPathComponent) else { throw VerificationFailure.identityMismatch }
            return report
        }
        let previous = try original.map(decode)
        if let partial {
            let newer = try decode(partial)
            guard newer.status == .fail, newer.phases.last?.name == "report-write", newer.phases.last?.status == .fail,
                  newer.phases.last?.failureCode == .outputUnavailable else { throw VerificationFailure.malformedReport }
            if let previous {
                guard previous.lane == newer.lane,
                      previous.sourceIdentity == nil || newer.sourceIdentity == previous.sourceIdentity,
                      previous.artifactIdentity == nil || newer.artifactIdentity == previous.artifactIdentity else { throw VerificationFailure.identityMismatch }
            }
            // A unique run never resumes with a successful overwrite. Fail evidence wins regardless of wall-clock metadata.
            return ("verify-report.partial.json", newer)
        }
        return previous.map { ("verify-report.json", $0) }
    }
    static func exportAllowlisted(report: VerificationReport, runRoot: URL, destination: URL) throws -> [String] {
        let root = try ownedRoot(runRoot), output = try emptyDestination(destination, runRoot: root)
        guard let (reportName, disk) = try selected(root), try encoded(disk) == encoded(report) else { throw VerificationFailure.identityMismatch }
        let internalNames: Set<String> = ["source-start", "source-end", "artifact-recovery-before", "artifact-source", "artifact-reuse", "artifact-manifest", "artifact-recovery-after", "report-write"]
        let commandNames = Set(["platform-os", "platform-arch", "platform-swift", "code-build", "code-full", "artifact-build", "artifact-signature", "artifact-check"] + (1...10).map { String(format: "smoke-%02d", $0) })
        let streamNames = commandNames.subtracting(["platform-os", "platform-arch", "platform-swift"])
        var payloads = [reportName: try encoded(report)], usedChildren: Set<String> = [], phases: Set<String> = []
        func include(_ relative: String, required: Bool = false) throws {
            if let source = try file(relative, under: root) { payloads[relative] = try Data(contentsOf: source) }
            else if required { throw VerificationFailure.outputUnavailable }
        }
        for phase in report.phases {
            guard phases.insert(phase.name).inserted, internalNames.contains(phase.name) || commandNames.contains(phase.name),
                  report.lane != .code || !phase.name.hasPrefix("artifact-") && !phase.name.hasPrefix("smoke-"),
                  report.lane != .artifact || !phase.name.hasPrefix("code-") else { throw VerificationFailure.malformedReport }
            if internalNames.contains(phase.name) {
                for path in phase.evidence {
                    let parts = path.split(separator: "/")
                    guard parts.count == 2, parts[0].hasPrefix("internal-"), UUID(uuidString: String(parts[0].dropFirst(9))) != nil,
                          ["stdout", "stderr"].contains(String(parts[1].split(separator: ".").last ?? "")),
                          UUID(uuidString: String(parts[1].dropLast(7))) != nil else { throw VerificationFailure.malformedReport }
                    _ = try file(path, under: root) // Validate references, but never upload git/source command logs.
                }
                continue
            }
            var childID: String?
            for path in phase.evidence {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "children", UUID(uuidString: String(parts[1])) != nil,
                      ["stdout", "stderr", "process-result.json"].contains(parts[2]), childID == nil || childID == String(parts[1]) else { throw VerificationFailure.malformedReport }
                childID = String(parts[1])
                _ = try file(path, under: root)
                if streamNames.contains(phase.name), parts[2] != "process-result.json" { try include(path, required: report.status == .pass) }
            }
            guard let childID else { continue }
            guard usedChildren.insert(childID).inserted else { throw VerificationFailure.malformedReport }
            let child = "children/" + childID, directory = root.appendingPathComponent(child)
            if !fm.fileExists(atPath: directory.path) { continue }
            // Only inspect immediate validation-root names; never recurse into config/defaults/DB/model directories.
            if phase.name == "code-full" || phase.name.hasPrefix("smoke-") {
                let names = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("validation-") && UUID(uuidString: String($0.dropFirst(11))) != nil }
                guard names.count <= 1 else { throw VerificationFailure.malformedReport }
                for name in names {
                    let log = phase.name == "code-full" ? "diagnostic-selftest.log" : "diagnostic-smoke.log"
                    for suffix in ["", ".1", ".2", ".3"] { try include(child + "/" + name + "/Logs/" + log + suffix) }
                }
            }
            if phase.name == "artifact-check" {
                for name in ["artifact.stdout", "artifact.stderr"] { try include(child + "/check-output/" + name) }
                for suffix in ["", ".1", ".2", ".3"] { try include(child + "/check-output/validation-root/Logs/diagnostic-smoke.log" + suffix) }
            }
        }
        if report.lane != .code {
            guard phases.contains("artifact-build") != phases.contains("artifact-reuse") else { throw VerificationFailure.malformedReport }
        }
        // Validate the complete selection before creating any output, then write data, never copied links.
        for path in payloads.keys.sorted() {
            let target = output.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payloads[path]!.write(to: target, options: .withoutOverwriting)
        }
        return payloads.keys.sorted()
    }
    static func exportRun(runRoot: URL, destination: URL) throws -> [String] {
        let root = try ownedRoot(runRoot)
        if let (_, report) = try selected(root) { return try exportAllowlisted(report: report, runRoot: root, destination: destination) }
        let output = try emptyDestination(destination, runRoot: root)
        guard let bootstrap = try file("bootstrap-failure.json", under: root) else { throw VerificationFailure.malformedReport }
        let data = try Data(contentsOf: bootstrap), record = try JSONDecoder().decode(BootstrapFailure.self, from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "status", "failureCode"]),
              record.schemaVersion == 1, record.status == .fail, record.failureCode == "bootstrapFailed" else { throw VerificationFailure.malformedReport }
        try Data("{\"schemaVersion\":1,\"status\":\"Fail\",\"failureCode\":\"bootstrapFailed\"}\n".utf8).write(to: output.appendingPathComponent("bootstrap-failure.json"), options: .withoutOverwriting)
        try Data("FlowType verification: bootstrapFailed\n".utf8).write(to: output.appendingPathComponent("bootstrap.stderr"), options: .withoutOverwriting)
        return ["bootstrap-failure.json", "bootstrap.stderr"]
    }
}

private enum WireFailure: String, Codable { case startupFailed, timerDeadline, windowServerUnavailable, invalidBuildInfo, resourceMissing, resourceMalformed, resourceOutsideBundle, metalUnavailable, metalLibraryInvalid, mlxOperationFailed, unexpectedFailure }
private enum WireOrigin: String, Codable { case packaged, development, invalid }
private enum WireReadiness: String, Codable { case ready, degraded, blocked }
private enum WirePermission: String, Codable { case granted, denied, notDetermined, unknown }
private struct WireIdentity: Codable, Equatable { let origin: WireOrigin; let metadata: BuildMetadataRecord?; let failureCode: String? }
private struct RuntimeWire: Codable, Equatable {
    let schemaVersion: Int; let mode: String; let ok: Bool; let role: String; let runID: String
    let buildInfo: WireIdentity; let durationMs: Int; let failureCode: WireFailure?
    let readiness: WireReadiness?; let ax: WirePermission?; let mic: WirePermission?; let speech: WirePermission?
    let probeTimerTicks: Int?; let windowHealthTicks: Int?; let tap: String?
    let appResources: Bool?; let metalLibrary: Bool?; let mlxOperation: Bool?; let resolvedInsideApp: Bool?
}
private struct HashTriple: Codable, Equatable { let binary: String; let metadata: String; let shader: String }
private struct CheckWire: Decodable {
    let schemaVersion: Int; let ok: Bool; let failureCode: String?; let signature: Bool
    let resourcesHidden: Bool; let resourcesRestored: Bool; let hashesBefore: HashTriple; let hashesAfter: HashTriple
    let sourceCommit: String; let artifact: RuntimeWire
}
enum VerificationValidation {
    static func smokeTiming(_ bytes: Data, externalMs: Int) throws {
        let wire = try JSONDecoder().decode(RuntimeWire.self, from: bytes)
        guard externalMs >= 6000, wire.durationMs <= externalMs + 250 else { throw VerificationFailure.smokeFailed }
    }
    static func fullSummary(_ bytes: Data) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n")
        let regex = try! NSRegularExpression(pattern: #"\A=== self-test: ([0-9]+) passed, ([0-9]+) failed ===\z"#)
        let matches = lines.compactMap { line -> (Int, Int)? in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range), let p = Range(match.range(at: 1), in: line),
                  let f = Range(match.range(at: 2), in: line), let passed = Int(line[p]), let failed = Int(line[f]) else { return nil }
            return (passed, failed)
        }
        return lines.filter { $0 == "=== FlowType --self-test ===" }.count == 1 && matches.count == 1 && matches[0].0 > 0 && matches[0].1 == 0
    }
    static func runtime(_ bytes: Data, mode: String, manifest: ArtifactManifest, exit: Int32, seen: inout Set<String>) throws -> VerificationStatus {
        guard let text = String(data: bytes, encoding: .utf8), text.components(separatedBy: "\n").count == 2, text.hasSuffix("\n") else { throw VerificationFailure.malformedReport }
        let record: RuntimeWire
        do { record = try JSONDecoder().decode(RuntimeWire.self, from: bytes) } catch { throw VerificationFailure.malformedReport }
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard object?["failureCode"] != nil, (object?["buildInfo"] as? [String: Any])?["failureCode"] is NSNull,
              record.schemaVersion == 1, record.mode == mode, record.role == "smokeTest", record.durationMs >= 0,
              UUID(uuidString: record.runID) != nil else { throw VerificationFailure.malformedReport }
        guard record.buildInfo.origin == .packaged, record.buildInfo.failureCode == nil, record.buildInfo.metadata == manifest.buildInfo else { throw VerificationFailure.identityMismatch }
        let canonicalID = UUID(uuidString: record.runID)!.uuidString
        guard seen.insert(canonicalID).inserted else { throw VerificationFailure.duplicateRunID }
        if mode == "smoke" {
            guard record.readiness != nil, record.ax != nil, record.mic != nil, record.speech != nil,
                  record.probeTimerTicks != nil, record.windowHealthTicks != nil, record.tap == "disabledForValidation" else { throw VerificationFailure.malformedReport }
            if exit == 69, !record.ok, record.failureCode == .windowServerUnavailable { return .skip }
            guard exit == 0, record.ok, record.failureCode == nil, object?["failureCode"] is NSNull,
                  record.durationMs >= 6000, record.probeTimerTicks! >= 1, record.windowHealthTicks! >= 1 else { throw VerificationFailure.smokeFailed }
        } else {
            guard mode == "artifact", exit == 0, record.ok, record.failureCode == nil, object?["failureCode"] is NSNull,
                  record.appResources == true, record.metalLibrary == true, record.mlxOperation == true, record.resolvedInsideApp == true else { throw VerificationFailure.artifactFailed }
        }
        return .pass
    }
    static func check(_ directory: URL, manifest: ArtifactManifest, seen: inout Set<String>) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("check-result.json"))
        let record: CheckWire
        do { record = try JSONDecoder().decode(CheckWire.self, from: data) } catch { throw VerificationFailure.malformedReport }
        let expected = HashTriple(binary: manifest.binarySHA256, metadata: manifest.buildInfoSHA256, shader: manifest.shaderSHA256)
        guard record.schemaVersion == 1, record.ok, record.failureCode == nil, record.signature, record.resourcesHidden, record.resourcesRestored,
              record.hashesBefore == expected, record.hashesAfter == expected, record.sourceCommit == manifest.buildInfo.gitSHA,
              (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["failureCode"] is NSNull else { throw VerificationFailure.identityMismatch }
        let stdout = try Data(contentsOf: directory.appendingPathComponent("artifact.stdout"))
        _ = try runtime(stdout, mode: "artifact", manifest: manifest, exit: 0, seen: &seen)
        guard try JSONDecoder().decode(RuntimeWire.self, from: stdout) == record.artifact else { throw VerificationFailure.identityMismatch }
    }
    static func loadManifest(repository: URL) throws -> ArtifactManifest {
        let app = repository.appendingPathComponent("build/FlowType.app")
        guard try canonicalExisting(app).path == canonicalExisting(repository).appendingPathComponent("build/FlowType.app").path else { throw VerificationFailure.identityMismatch }
        let file = repository.appendingPathComponent("build/FlowType.manifest.json")
        let record = try JSONDecoder().decode(ArtifactManifest.self, from: Data(contentsOf: file))
        // Reuse B3's actual-byte verification, but decode and report an independent wire type.
        _ = try validateManifest(app: app, file: file)
        guard record.schemaVersion == 1, record.architecture == "arm64", record.buildInfo.schemaVersion == 1, !record.buildInfo.dirty,
              record.buildInfo.gitSHA.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
              record.buildInfo.sourceTree.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil else { throw VerificationFailure.identityMismatch }
        return record
    }
}

/// Shared with later exporters: validate every owned directory before creating or writing evidence.
enum VerificationPaths {
    static func prepare(repository: URL) throws -> URL {
        let fm = FileManager.default
        var parent = try canonicalExisting(repository)
        for name in ["build", "verification"] {
            let child = parent.appendingPathComponent(name)
            guard (try? fm.destinationOfSymbolicLink(atPath: child.path)) == nil else { throw VerificationFailure.outputUnavailable }
            if fm.fileExists(atPath: child.path) {
                guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw VerificationFailure.outputUnavailable }
            } else { try fm.createDirectory(at: child, withIntermediateDirectories: false) }
            guard try canonicalExisting(child).path == child.path else { throw VerificationFailure.outputUnavailable }
            parent = child
        }
        return parent
    }
}
private final class VerificationLock {
    let fd: Int32
    init(repository: URL) throws {
        let directory = try VerificationPaths.prepare(repository: repository)
        fd = open(directory.appendingPathComponent(".writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VerificationFailure.outputUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw VerificationFailure.toolFailed }
    }
    deinit { _ = flock(fd, LOCK_UN); close(fd) }
}
extension VerificationDependencies {
    static func live() -> VerificationDependencies {
        VerificationDependencies(execute: { request in try BoundedProcess.run(request.command, shouldCancel: { packagingCancellation.isCancelled() }) },
            snapshot: { repository, logs in
                let sha = try packagingGit(["rev-parse", "HEAD"], repo: repository, logs: logs)
                let tree = try packagingGit(["rev-parse", "HEAD:Sources"], repo: repository, logs: logs)
                let status = try packagingGit(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], repo: repository, logs: logs)
                let dirty = !status.isEmpty
                let shallow = try packagingGit(["rev-parse", "--is-shallow-repository"], repo: repository, logs: logs) == "true"
                guard sha.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil, tree.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil else { throw VerificationFailure.sourceInvalid }
                let paths = try packagingGit(["ls-files", "-z", "--cached", "--", "Sources", "scripts", "Package.swift", "Package.resolved"], repo: repository, logs: logs)
                let canonicalRepo = try canonicalExisting(repository)
                var hashes: [String] = ["status:" + status]
                for path in Set(paths.split(separator: "\0").map(String.init)).sorted() {
                    let file = repository.appendingPathComponent(path)
                    guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                          try canonicalExisting(file).path == canonicalRepo.appendingPathComponent(path).path else { throw VerificationFailure.sourceInvalid }
                    hashes.append(path + ":" + (try packagingHash(file)))
                }
                return SourceSnapshot(identity: SourceIdentity(gitSHA: sha, sourceTree: tree, dirty: dirty), fingerprint: hashes.joined(separator: "\n"), shallow: shallow)
            }, manifest: VerificationValidation.loadManifest, recover: { try ArtifactPackager.recoverOwned(repository: $0) },
            ciCode: ProcessInfo.processInfo.environment["CI"].map { !$0.isEmpty && !["false", "0"].contains($0.lowercased()) } ?? false)
    }
}

enum VerificationRunner {
    static func run(lane: VerificationLane, repository: URL, output: URL, manualReport: URL?, ciReport: URL?) throws -> VerificationReport {
        try run(lane: lane, repository: repository, output: output, manualReport: manualReport, ciReport: ciReport, dependencies: .live())
    }
    static func run(lane: VerificationLane, repository: URL, output: URL, manualReport: URL?, ciReport: URL?, candidateManifest: URL? = nil, dependencies: VerificationDependencies) throws -> VerificationReport {
        guard candidateManifest == nil || lane != .code else { throw VerificationFailure.usage }
        let lock = try VerificationLock(repository: repository); defer { withExtendedLifetime(lock) {} }
        let fm = FileManager.default
        guard UUID(uuidString: output.lastPathComponent) != nil,
              try canonicalExisting(output.deletingLastPathComponent()).path == VerificationPaths.prepare(repository: repository).path,
              try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try fm.contentsOfDirectory(atPath: output.path).isEmpty else { throw VerificationFailure.outputUnavailable }
        let code = lane != .artifact, artifact = lane != .code
        var names = ["source-start", "platform-os", "platform-arch", "platform-swift"]
        if code { names += ["code-build", "code-full"] }
        if artifact { names += ["artifact-recovery-before", "artifact-source", candidateManifest == nil ? "artifact-build" : "artifact-reuse", "artifact-manifest", "artifact-signature", "artifact-check", "artifact-recovery-after"] + (1...10).map { String(format: "smoke-%02d", $0) } }
        names.append("source-end")
        var report = VerificationReport(schemaVersion: 1, runID: UUID(uuidString: output.lastPathComponent)?.uuidString ?? UUID().uuidString,
            lane: lane, status: .pending, sourceIdentity: nil, artifactIdentity: nil,
            phases: names.map { VerificationPhase(name: $0, status: .pending, failureCode: .notExecuted) }, manualStatus: .pending, ciStatus: .pending)
        func aggregate() {
            var values = report.phases.map(\.status)
            if lane == .release { values += [report.manualStatus, report.ciStatus] }
            report.status = values.contains(.fail) ? .fail : values.contains(.pending) ? .pending : values.contains(.skip) ? .skip : .pass
        }
        func persist() throws {
            aggregate()
            do { try dependencies.writeReport(JSONEncoder().encode(report), output.appendingPathComponent("verify-report.json")) }
            catch {
                report.phases.append(VerificationPhase(name: "report-write", status: .fail, failureCode: .outputUnavailable)); report.status = .fail
                try? JSONEncoder().encode(report).write(to: output.appendingPathComponent("verify-report.partial.json"), options: .atomic)
                throw VerificationFailure.outputUnavailable
            }
        }
        func replace(_ phase: VerificationPhase) throws { report.phases[report.phases.firstIndex(where: { $0.name == phase.name })!] = phase; try persist() }
        func internalPhase(_ name: String, _ body: (URL) throws -> Void) throws -> Bool {
            let logs = output.appendingPathComponent("internal-\(UUID())"); try fm.createDirectory(at: logs, withIntermediateDirectories: false)
            var phase = VerificationPhase(name: name, status: .pass, exitCode: 0)
            do { try body(logs) } catch { phase.status = .fail; phase.exitCode = nil; phase.failureCode = (error as? VerificationFailure) ?? (name.contains("recovery") ? .recoveryFailed : .toolFailed) }
            phase.evidence = (try fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)).map { logs.lastPathComponent + "/" + $0.lastPathComponent }.sorted()
            try replace(phase); return phase.status == .pass
        }
        func execute(_ name: String, _ executable: URL, _ args: [String], timeout: Double,
                     failure: VerificationFailure, validate: (Data, VerificationCommand, BoundedResult) throws -> VerificationStatus = { _, _, _ in .pass }) throws -> Bool {
            let child = output.appendingPathComponent("children/\(UUID())")
            try fm.createDirectory(at: child, withIntermediateDirectories: true)
            let validation = child.appendingPathComponent("validation-\(UUID())"), check = child.appendingPathComponent("check-output")
            try fm.createDirectory(at: check, withIntermediateDirectories: false)
            let resolvedArgs = args.map { $0 == "__VALIDATION_ROOT__" ? validation.path : $0 == "__CHECK_OUTPUT__" ? check.path : $0 }
            let command = VerificationCommand(phase: name, command: BoundedCommand(executable: executable, arguments: resolvedArgs,
                workingDirectory: repository, environment: ProcessInfo.processInfo.environment,
                stdoutURL: child.appendingPathComponent("stdout"), stderrURL: child.appendingPathComponent("stderr"), timeoutSeconds: timeout),
                childRoot: child, validationRoot: validation, checkOutput: check)
            var phase = VerificationPhase(name: name, status: .fail, failureCode: failure,
                evidence: ["children/\(child.lastPathComponent)/stdout", "children/\(child.lastPathComponent)/stderr", "children/\(child.lastPathComponent)/process-result.json"])
            do {
                let result = try dependencies.execute(command)
                try JSONEncoder().encode(result).write(to: child.appendingPathComponent("process-result.json"), options: .withoutOverwriting)
                phase.exitCode = result.exitCode; phase.timedOut = result.timedOut
                if result.timedOut { phase.failureCode = .timedOut }
                else if result.termination == .normal && (result.exitCode == 0 || name.hasPrefix("smoke-") && result.exitCode == 69) {
                    phase.status = try validate(Data(contentsOf: command.command.stdoutURL), command, result)
                    phase.failureCode = phase.status == .skip ? .windowServerUnavailable : nil
                }
            } catch { phase.failureCode = (error as? VerificationFailure) ?? failure }
            try replace(phase); return phase.status == .pass || phase.status == .skip
        }
        var start: SourceSnapshot?
        let sourceOK = try internalPhase("source-start") { logs in
            let value = try dependencies.snapshot(repository, logs); start = value; report.sourceIdentity = value.identity
            if code && dependencies.ciCode && value.identity.dirty { throw VerificationFailure.dirtySource }
        }
        let os = try execute("platform-os", URL(fileURLWithPath: "/usr/bin/sw_vers"), ["-productVersion"], timeout: 30, failure: .platformUnsupported) { bytes, _, _ in
            guard VerificationCapability.operatingSystem(String(decoding: bytes, as: UTF8.self)) else { throw VerificationFailure.platformUnsupported }; return .pass
        }
        let arch = try execute("platform-arch", URL(fileURLWithPath: "/usr/bin/uname"), ["-m"], timeout: 30, failure: .platformUnsupported) { bytes, _, _ in
            guard VerificationCapability.architecture(String(decoding: bytes, as: UTF8.self)) else { throw VerificationFailure.platformUnsupported }; return .pass
        }
        let swift = try execute("platform-swift", URL(fileURLWithPath: "/usr/bin/swift"), ["--version"], timeout: 30, failure: .platformUnsupported) { bytes, _, _ in
            guard VerificationCapability.swiftVersion(String(decoding: bytes, as: UTF8.self)) else { throw VerificationFailure.platformUnsupported }; return .pass
        }
        let platform = os && arch && swift
        if code && platform && sourceOK {
            if try execute("code-build", URL(fileURLWithPath: "/usr/bin/swift"), ["build"], timeout: 900, failure: .buildFailed) {
                _ = try execute("code-full", repository.appendingPathComponent(".build/debug/FlowType"), ["--self-test", "--validation-root", "__VALIDATION_ROOT__"], timeout: 900, failure: .fullTestFailed) { data, _, _ in
                    guard VerificationValidation.fullSummary(data) else { throw VerificationFailure.fullTestFailed }; return .pass
                }
            }
        }
        if artifact {
            let recovered = try internalPhase("artifact-recovery-before") { _ in try dependencies.recover(repository) }
            let clean = try internalPhase("artifact-source") { _ in
                guard let start else { throw VerificationFailure.sourceInvalid }
                guard !start.identity.dirty else { throw VerificationFailure.dirtySource }
                guard !start.shallow else { throw VerificationFailure.shallowHistory }
            }
            var candidate: ArtifactManifest?
            if platform && sourceOK && recovered && clean {
                let ready: Bool
                if let candidateManifest {
                    ready = try internalPhase("artifact-reuse") { _ in
                        let expected = try canonicalExisting(repository).appendingPathComponent("build/FlowType.manifest.json")
                        guard candidateManifest.path == expected.path, try canonicalExisting(candidateManifest).path == expected.path else { throw VerificationFailure.identityMismatch }
                        let value = try dependencies.manifest(repository)
                        guard value.buildInfo.gitSHA == start?.identity.gitSHA, value.buildInfo.sourceTree == start?.identity.sourceTree, !value.buildInfo.dirty else { throw VerificationFailure.identityMismatch }
                    }
                } else {
                    ready = try execute("artifact-build", repository.appendingPathComponent("scripts/build-app.sh"), [], timeout: 900, failure: .buildFailed)
                }
                if ready {
                    let loaded = try internalPhase("artifact-manifest") { _ in
                        let value = try dependencies.manifest(repository)
                        guard value.buildInfo.gitSHA == start?.identity.gitSHA, value.buildInfo.sourceTree == start?.identity.sourceTree, !value.buildInfo.dirty else { throw VerificationFailure.identityMismatch }
                        candidate = value; report.artifactIdentity = value
                    }
                    if loaded, let candidate {
                        if try execute("artifact-signature", URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", "--verbose=2", repository.appendingPathComponent("build/FlowType.app").path], timeout: 30, failure: .signatureFailed) {
                            var seen: Set<String> = []
                            let checked = try execute("artifact-check", repository.appendingPathComponent("scripts/check-app.sh"), ["--app", repository.appendingPathComponent("build/FlowType.app").path, "--output", "__CHECK_OUTPUT__"], timeout: 120, failure: .artifactFailed) { _, request, _ in
                                try VerificationValidation.check(request.checkOutput, manifest: candidate, seen: &seen)
                                guard try dependencies.manifest(repository) == candidate else { throw VerificationFailure.identityMismatch }; return .pass
                            }
                            let recoveryAfter = try internalPhase("artifact-recovery-after") { _ in try dependencies.recover(repository) }
                            if checked && recoveryAfter {
                                for index in 1...10 {
                                    let name = String(format: "smoke-%02d", index)
                                    do {
                                        guard try dependencies.manifest(repository) == candidate else { throw VerificationFailure.identityMismatch }
                                    } catch {
                                        try replace(VerificationPhase(name: name, status: .fail, failureCode: .identityMismatch)); break
                                    }
                                    var stillValid = true
                                    _ = try execute(name, repository.appendingPathComponent("build/FlowType.app/Contents/MacOS/FlowType"), ["--smoke-test", "--validation-root", "__VALIDATION_ROOT__"], timeout: 15, failure: .smokeFailed) { bytes, _, result in
                                        guard try dependencies.manifest(repository) == candidate else { stillValid = false; throw VerificationFailure.identityMismatch }
                                        if result.exitCode == 0 { try VerificationValidation.smokeTiming(bytes, externalMs: result.durationMs) }
                                        let status = try VerificationValidation.runtime(bytes, mode: "smoke", manifest: candidate, exit: result.exitCode!, seen: &seen)
                                        guard try dependencies.manifest(repository) == candidate else { stillValid = false; throw VerificationFailure.identityMismatch }; return status
                                    }
                                    if !stillValid { break }
                                }
                            }
                        }
                    }
                }
            }
            if report.phases.first(where: { $0.name == "artifact-recovery-after" })?.status == .pending {
                _ = try internalPhase("artifact-recovery-after") { _ in try dependencies.recover(repository) }
            }
        }
        _ = try internalPhase("source-end") { logs in
            let end = try dependencies.snapshot(repository, logs)
            guard let start, end == start else { throw VerificationFailure.sourceChanged }
        }
        let statuses = ManualValidation.evaluate(manualReport: manualReport, ciReport: ciReport, artifact: report.artifactIdentity,
            expectedSourceIdentity: report.sourceIdentity, expectedAppPath: repository.appendingPathComponent("build/FlowType.app"))
        report.manualStatus = statuses.0.status; report.manualCases = statuses.0.cases; report.manualIssues = statuses.0.issues; report.ciStatus = statuses.1
        try persist(); return report
    }
}
