import Foundation

/// This ledger is independent of the original 41-case ManualValidation schema.
struct ModelCenterCandidate: Codable, Equatable {
    let gitSHA: String
    let sourceTree: String
    let binarySHA256: String
    let appPath: String
    let packageSHA256: String?
}

enum ModelCenterAcceptance {
    static let schema = "flowtype.model-center-acceptance"
    static let caseIDs = [
        "H1.repo", "H1.variant", "H1.tokenizer", "H1.gated",
        "H2.resume", "H2.restart", "H2.integrity", "H2.disk",
        "H3.qwen06", "H3.qwen17", "H3.whisperTiny", "H3.whisperBase", "H3.offlineLong",
        "H4.mlxAudio", "H4.whisperKit", "H4.whisperCpp", "H4.disconnect",
        "H5.siliconCN", "H5.openAI", "H5.custom", "H5.errors",
        "H6.switch", "H6.cancel", "H6.delete", "H6.credentials",
        "H7.layout", "H7.keyboard", "H7.accessibility", "H8.fresh", "H8.upgrade"
    ]
    private enum Status: String, Codable { case pass = "Pass", fail = "Fail", pending = "Pending" }
    private struct Attestation: Decodable {
        let kind: String
        let verification: String
        let tester: String
        let testedAt: String
        let hardware: String
        let macOS: String
        let modelCommitOrServiceVersion: String
        let actions: String
        let observation: String
        let evidence: [String]
    }
    private struct Row: Decodable {
        let id: String
        let status: Status
        let candidate: ModelCenterCandidate?
        let attestation: Attestation?
    }
    private struct Document: Decodable {
        let schema: String
        let schemaVersion: Int
        let status: Status
        let candidate: ModelCenterCandidate
        let cases: [Row]
    }
    /// Wire view of the D4 report. D4 owns execution and validation of distribution checks.
    private struct Distribution: Decodable {
        let schemaVersion: Int
        let status: Status
        let candidate: ModelCenterCandidate
        let teamID: String?
        let hardenedRuntime: Bool
        let appNotarizationID: String?
        let dmgNotarizationID: String?
        let stapled: Bool
        let gatekeeperAccepted: Bool
        let dmgSHA256: String?
        let issues: [String]
    }
    private static func filled(_ value: String?) -> Bool {
        !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.range(of: "\\A[0-9a-f]{\(count)}\\z", options: .regularExpression) != nil
    }
    private static func valid(_ candidate: ModelCenterCandidate) -> Bool {
        hex(candidate.gitSHA, count: 40) && hex(candidate.sourceTree, count: 40)
            && hex(candidate.binarySHA256, count: 64)
            && candidate.appPath.hasPrefix("/") && candidate.appPath.hasSuffix(".app")
            && URL(fileURLWithPath: candidate.appPath).standardizedFileURL.path == candidate.appPath
            && (candidate.packageSHA256 == nil || hex(candidate.packageSHA256!, count: 64))
    }
    private static func empty(_ candidate: ModelCenterCandidate) -> Bool {
        candidate.gitSHA.isEmpty && candidate.sourceTree.isEmpty && candidate.binarySHA256.isEmpty
            && candidate.appPath.isEmpty && candidate.packageSHA256 == nil
    }
    private static func utc(_ value: String) -> Bool {
        guard value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{3})?Z\z"#, options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
    private static func read(_ file: URL) throws -> Data {
        guard try canonicalExisting(file).path == file.path,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw VerificationFailure.malformedReport }
        return try Data(contentsOf: file)
    }
    private static func evidence(_ paths: [String], root: URL) -> Bool {
        guard !paths.isEmpty, (try? canonicalExisting(root).path) == root.path else { return false }
        return paths.allSatisfy { path in
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
            var current = root
            for (index, component) in components.enumerated() {
                current.appendPathComponent(String(component))
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil,
                      (try? canonicalExisting(current).path) == current.path,
                      let info = try? current.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { return false }
                if index == components.count - 1 {
                    guard info.isRegularFile == true, (info.fileSize ?? 0) > 0 else { return false }
                } else if info.isDirectory != true { return false }
            }
            return true
        }
    }
    private static func requiredVerification(_ id: String) -> String {
        if id == "H7.accessibility" { return "realAccessibility" }
        if id.hasPrefix("H3.") || ["H4.mlxAudio", "H4.whisperKit", "H4.whisperCpp", "H5.siliconCN", "H5.openAI", "H5.custom"].contains(id) { return "realRecognition" }
        return "realInteraction"
    }
    private static func details(_ attestation: Attestation, root: URL) -> Bool {
        [attestation.tester, attestation.hardware, attestation.modelCommitOrServiceVersion, attestation.actions, attestation.observation].allSatisfy { filled($0) }
            && utc(attestation.testedAt) && VerificationCapability.operatingSystem(attestation.macOS)
            && evidence(attestation.evidence, root: root)
    }
    private static func keys(_ value: Any?, allowed: Set<String>) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys).isSubset(of: allowed)
    }
    private static let candidateKeys: Set<String> = ["gitSHA", "sourceTree", "binarySHA256", "appPath", "packageSHA256"]
    private static func ledgerShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              keys(object, allowed: ["schema", "schemaVersion", "status", "candidate", "cases"]),
              keys(object["candidate"], allowed: candidateKeys), let rows = object["cases"] as? [[String: Any]] else { return false }
        return rows.allSatisfy { row in
            guard keys(row, allowed: ["id", "status", "candidate", "attestation"]) else { return false }
            if let identity = row["candidate"], !(identity is NSNull), !keys(identity, allowed: candidateKeys) { return false }
            if let attestation = row["attestation"], !(attestation is NSNull), !keys(attestation, allowed: ["kind", "verification", "tester", "testedAt", "hardware", "macOS", "modelCommitOrServiceVersion", "actions", "observation", "evidence"]) { return false }
            return true
        }
    }
    /// Can evaluate an unbound Pending template before distribution. A Pass always needs a package.
    static func evaluate(report: URL, candidate: ModelCenterCandidate) throws -> VerificationStatus {
        let data = try read(report)
        guard valid(candidate), ledgerShape(data), let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schema == schema, document.schemaVersion == 1,
              document.cases.count == caseIDs.count,
              Set(document.cases.map(\.id)) == Set(caseIDs),
              empty(document.candidate) || document.candidate == candidate else { return .fail }
        var statuses: [Status] = []
        for row in document.cases {
            if let identity = row.candidate, identity != candidate { return .fail }
            if let attestation = row.attestation, !details(attestation, root: report.deletingLastPathComponent()) { return .fail }
            if row.status == .pass {
                guard candidate.packageSHA256 != nil, document.candidate == candidate, row.candidate == candidate,
                      let attestation = row.attestation, attestation.kind == "realManual",
                      attestation.verification == requiredVerification(row.id) else { return .fail }
            }
            statuses.append(row.status)
        }
        let actual: Status = statuses.contains(.fail) ? .fail : statuses.allSatisfy { $0 == .pass } ? .pass : .pending
        guard document.status == actual else { return .fail }
        return actual == .pass ? .pass : actual == .fail ? .fail : .pending
    }
    /// Public gate: verify manifest bytes and consume the declared D4 report, without performing signing checks.
    static func evaluate(report: URL, manifest: URL, distributionReport: URL) throws -> VerificationStatus {
        let data = try read(distributionReport)
        guard let distribution = try? JSONDecoder().decode(Distribution.self, from: data), distribution.schemaVersion == 1,
              valid(distribution.candidate), distribution.candidate.packageSHA256 == distribution.dmgSHA256 else { return .fail }
        let candidate = distribution.candidate
        let app = URL(fileURLWithPath: candidate.appPath)
        guard try canonicalExisting(app).path == app.path else { return .fail }
        _ = try read(manifest)
        let artifact = try validateManifest(app: app, file: manifest)
        guard artifact.buildInfo.gitSHA == candidate.gitSHA, artifact.buildInfo.sourceTree == candidate.sourceTree,
              artifact.binarySHA256 == candidate.binarySHA256 else { return .fail }
        if distribution.status == .pass {
            guard candidate.packageSHA256 != nil, filled(distribution.teamID), distribution.hardenedRuntime,
                  filled(distribution.appNotarizationID), filled(distribution.dmgNotarizationID), distribution.stapled,
                  distribution.gatekeeperAccepted, distribution.issues.isEmpty else { return .fail }
        }
        let manual = try evaluate(report: report, candidate: candidate)
        if manual == .fail || distribution.status == .fail { return .fail }
        return manual == .pass && distribution.status == .pass ? .pass : .pending
    }
    static func templateData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "schemaVersion": 1, "status": "Pending",
            "candidate": ["gitSHA": "", "sourceTree": "", "binarySHA256": "", "appPath": "", "packageSHA256": NSNull()],
            "cases": caseIDs.map { ["id": $0, "status": "Pending"] }], options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    }
}
