import Foundation

enum ManualCaseID: String, CaseIterable, Codable {
    case launch10 = "R1.launch10", sessions20 = "R2.sessions20"
    case axRecovery = "R3.axRecovery", micRecovery = "R3.micRecovery", noEngine = "R3.noEngine", multipleBlockers = "R3.multipleBlockers"
    case metadata = "R4.metadata", switchSource = "R4.switchSource", retry = "R4.retry", autoFallback = "R4.autoFallback", manualSelection = "R4.manualSelection"
    case builtin06 = "R4.builtin06", builtin17 = "R4.builtin17", importQwen = "R4.importQwen", importWhisper = "R4.importWhisper"
    case silence = "R5.silence", quiet = "R5.quiet", short = "R5.short", noise = "R5.noise"
    case layout = "R6.layout", focus = "R6.focus", displays = "R6.displays"
    case weak = "V1.weak", offline = "V1.offline", badKey = "V1.badKey"
    case textEdit = "V2.textEdit", vscode = "V2.vscode", chrome = "V2.chrome", terminal = "V2.terminal", cursor = "V2.cursor", safeTargets = "V2.safeTargets"
    case formats = "V3.formats", concurrentCopy = "V3.concurrentCopy"
    case preparing = "V4.preparing", recording = "V4.recording", asr = "V4.asr", polish = "V4.polish", injection = "V4.injection", postEvent = "V4.postEvent"
    case unplug = "V5.unplug", bluetooth = "V5.bluetooth"
}
enum ManualValidationIssue: String, Codable { case malformed, identityMismatch, unknownCase, duplicateCase, missingDetails, invalidEvidence, falsePass, unreadableReport }
struct ManualCaseResult: Codable { let id: ManualCaseID; let status: VerificationStatus }
struct ManualValidationResult {
    let status: VerificationStatus; let cases: [ManualCaseResult]; let issues: [ManualValidationIssue]
}
private enum AcceptanceStatus: String, Codable { case pending = "Pending", pass = "Pass", fail = "Fail" }
private struct ManualCandidate: Codable, Equatable {
    let gitSHA: String; let sourceTree: String; let binarySHA256: String; let appPath: String
    static let empty = ManualCandidate(gitSHA: "", sourceTree: "", binarySHA256: "", appPath: "")
}
private struct ManualEnvironment: Codable { let macOS: String; let hardware: String; let target: String }
private struct ManualObservation: Codable { let actions: String; let result: String; let count: Int; let durationMs: Int }
private struct ManualRow: Codable {
    let id: String; let status: AcceptanceStatus
    let testedAt: String?; let tester: String?; let environment: ManualEnvironment?; let observation: ManualObservation?
    let gitSHA: String?; let sourceTree: String?; let binarySHA256: String?; let appPath: String?; let evidence: [String]?
    var identity: ManualCandidate? {
        guard let gitSHA, let sourceTree, let binarySHA256, let appPath else { return nil }
        return ManualCandidate(gitSHA: gitSHA, sourceTree: sourceTree, binarySHA256: binarySHA256, appPath: appPath)
    }
    var hasIdentity: Bool { [gitSHA, sourceTree, binarySHA256, appPath].contains { !($0 ?? "").isEmpty } }
}
private struct ManualDocument: Codable { let schemaVersion: Int; let candidate: ManualCandidate; let cases: [ManualRow]; let status: AcceptanceStatus? }
private enum AcceptanceFiles {
    static func read(_ file: URL?) throws -> Data? {
        guard let file else { return nil }
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw VerificationFailure.malformedReport }
        guard fm.fileExists(atPath: file.path) else { return nil }
        guard try canonicalExisting(file).path == file.path,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw VerificationFailure.malformedReport }
        return try Data(contentsOf: file)
    }
    static func evidence(_ paths: [String], root: URL) -> Bool {
        guard !paths.isEmpty, (try? canonicalExisting(root).path) == root.path else { return false }
        let fm = FileManager.default
        return paths.allSatisfy { path in
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
            var current = root
            for (index, part) in pieces.enumerated() {
                current.appendPathComponent(String(part))
                guard (try? fm.destinationOfSymbolicLink(atPath: current.path)) == nil,
                      (try? canonicalExisting(current).path) == current.path,
                      let info = try? current.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                      index == pieces.count - 1 ? info.isRegularFile == true : info.isDirectory == true else { return false }
            }
            return true
        }
    }
}
enum ManualValidation {
    private static let parents = Set(["R1", "R2", "R3", "R4", "R5", "R6", "V1", "V2", "V3", "V4", "V5"])
    private static func filled(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func utc(_ value: String) -> Bool {
        guard value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{3})?Z\z"#, options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
    static func evaluate(data: Data?, manifest: ArtifactManifest?, expectedSourceIdentity: SourceIdentity?, expectedAppPath: URL, evidenceRoot: URL) -> ManualValidationResult {
        var states = Dictionary(uniqueKeysWithValues: ManualCaseID.allCases.map { ($0, VerificationStatus.pending) })
        var issues: [ManualValidationIssue] = []
        func result() -> ManualValidationResult {
            let status: VerificationStatus = !issues.isEmpty || states.values.contains(.fail) ? .fail : states.values.allSatisfy { $0 == .pass } ? .pass : .pending
            return ManualValidationResult(status: status, cases: ManualCaseID.allCases.map { ManualCaseResult(id: $0, status: states[$0]!) }, issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue })
        }
        guard let data else { return result() }
        guard let document = try? JSONDecoder().decode(ManualDocument.self, from: data), document.schemaVersion == 1 else { issues.append(.malformed); return result() }
        let expected: ManualCandidate? = {
            guard let manifest, let source = expectedSourceIdentity,
                  source.gitSHA == manifest.buildInfo.gitSHA, source.sourceTree == manifest.buildInfo.sourceTree else { return nil }
            return ManualCandidate(gitSHA: source.gitSHA, sourceTree: source.sourceTree, binarySHA256: manifest.binarySHA256, appPath: expectedAppPath.path)
        }()
        let empty = document.candidate == .empty
        if !empty && document.candidate != expected { issues.append(.identityMismatch) }
        var seen: Set<String> = [], aggregateRows: [ManualRow] = []
        for row in document.cases {
            guard seen.insert(row.id).inserted else { issues.append(.duplicateCase); continue }
            guard let id = ManualCaseID(rawValue: row.id) else {
                if parents.contains(row.id) { aggregateRows.append(row) } else { issues.append(.unknownCase) }
                continue
            }
            var state = VerificationStatus(rawValue: row.status.rawValue)!
            if row.hasIdentity && row.identity != expected { state = .fail; issues.append(.identityMismatch) }
            if let evidence = row.evidence, !evidence.isEmpty, !AcceptanceFiles.evidence(evidence, root: evidenceRoot) { state = .fail; issues.append(.invalidEvidence) }
            if row.status == .pass {
                if empty || row.identity == nil || row.identity != expected { state = .fail; issues.append(.identityMismatch) }
                let minimum = id == .launch10 ? 10 : id == .sessions20 ? 20 : 1
                guard let date = row.testedAt, utc(date), filled(row.tester),
                      let environment = row.environment, filled(environment.macOS), filled(environment.hardware), filled(environment.target),
                      let observation = row.observation, filled(observation.actions), filled(observation.result), observation.count >= minimum, observation.durationMs > 0,
                      let evidence = row.evidence, AcceptanceFiles.evidence(evidence, root: evidenceRoot) else {
                    states[id] = .fail; issues.append(.missingDetails); continue
                }
            }
            states[id] = state
        }
        for row in aggregateRows {
            let children = ManualCaseID.allCases.filter { $0.rawValue.hasPrefix(row.id + ".") }.map { states[$0]! }
            let expected: VerificationStatus = children.contains(.fail) ? .fail : children.allSatisfy { $0 == .pass } ? .pass : .pending
            if row.status.rawValue != expected.rawValue { issues.append(.falsePass) }
        }
        if let claimed = document.status, claimed.rawValue != result().status.rawValue { issues.append(.falsePass) }
        return result()
    }
    static func templateData() throws -> Data {
        let cases = ManualCaseID.allCases.map { ["id": $0.rawValue, "status": "Pending"] }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "candidate": ["gitSHA": "", "sourceTree": "", "binarySHA256": "", "appPath": ""], "cases": cases], options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    }
    static func writeTemplate(to file: URL) throws {
        guard try canonicalExisting(file.deletingLastPathComponent()).path == file.deletingLastPathComponent().path,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw VerificationFailure.outputUnavailable }
        try templateData().write(to: file, options: .withoutOverwriting)
    }
    static func evaluate(manualReport: URL?, ciReport: URL?, artifact: ArtifactManifest?, expectedSourceIdentity: SourceIdentity?, expectedAppPath: URL) -> (ManualValidationResult, VerificationStatus) {
        var manual: ManualValidationResult
        do { manual = evaluate(data: try AcceptanceFiles.read(manualReport), manifest: artifact, expectedSourceIdentity: expectedSourceIdentity, expectedAppPath: expectedAppPath,
                              evidenceRoot: manualReport?.deletingLastPathComponent() ?? expectedAppPath.deletingLastPathComponent()) }
        catch { manual = ManualValidationResult(status: .fail, cases: ManualCaseID.allCases.map { ManualCaseResult(id: $0, status: .pending) }, issues: [.unreadableReport]) }
        let ci: VerificationStatus
        do {
            let data = try AcceptanceFiles.read(ciReport)
            ci = CIValidation.evaluate(data: data, expectedGitSHA: expectedSourceIdentity?.gitSHA ?? "", expectedSourceTree: expectedSourceIdentity?.sourceTree ?? "")
        } catch { return (manual, .fail) }
        return (manual, ci)
    }
}
enum CIValidation {
    private struct CIReport: Decodable { let schemaVersion: Int; let status: AcceptanceStatus; let gitSHA: String; let sourceTree: String; let lane: String; let runURL: String; let evidence: [String] }
    static func evaluate(data: Data?, expectedGitSHA: String, expectedSourceTree: String) -> VerificationStatus {
        guard let data else { return .pending }
        guard let report = try? JSONDecoder().decode(CIReport.self, from: data), report.schemaVersion == 1, report.lane == "code" else { return .fail }
        if report.status == .pending, report.gitSHA.isEmpty, report.sourceTree.isEmpty, report.runURL.isEmpty, report.evidence.isEmpty { return .pending }
        guard expectedGitSHA.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
              expectedSourceTree.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
              report.gitSHA == expectedGitSHA, report.sourceTree == expectedSourceTree else { return .fail }
        if report.status == .fail { return .fail }
        let validRun = report.runURL.range(of: #"\Ahttps://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*\z"#, options: .regularExpression) != nil
        guard report.runURL.isEmpty || validRun else { return .fail }
        let prefix = report.runURL + "/artifacts/"
        guard report.evidence.allSatisfy({ $0.hasPrefix(prefix) && String($0.dropFirst(prefix.count)).range(of: #"\A[1-9][0-9]*\z"#, options: .regularExpression) != nil }) else { return .fail }
        if report.status == .pass { return validRun && !report.evidence.isEmpty ? .pass : .fail }
        return .pending
    }
}
