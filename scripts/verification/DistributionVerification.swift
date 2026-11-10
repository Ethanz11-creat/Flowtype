import Foundation

struct DistributionCandidate: Codable, Equatable {
    let gitSHA: String; let sourceTree: String; let binarySHA256: String; let appPath: String; let packageSHA256: String?
}
struct DistributionVerificationReport: Codable {
    let schemaVersion: Int
    var status: VerificationStatus
    let candidate: DistributionCandidate
    var teamID: String?
    var hardenedRuntime: Bool = false
    var appNotarizationID: String?
    var dmgNotarizationID: String?
    var stapled: Bool = false
    var gatekeeperAccepted: Bool = false
    let dmgSHA256: String?
    var issues: [String] = []
    var exitCode: Int32 { status == .pass ? 0 : status == .fail ? 1 : 2 }
}
struct DistributionCommandResult { let exitCode: Int32; let output: Data }
typealias DistributionCommand = (String, [String]) throws -> DistributionCommandResult
struct DistributionSubmission: Codable {
    let acceptedOutput: String
    let submittedSHA256: String
    let finalSHA256: String
}
struct DistributionNotaryEvidence: Codable {
    let schemaVersion: Int
    let signingIdentity: String
    let teamID: String
    let app: DistributionSubmission
    let dmg: DistributionSubmission
}
enum DistributionVerification {
    private struct Accepted: Decodable { let id: String; let status: String }
    private struct NotaryLog: Decodable { let jobId: String; let status: String; let sha256: String }
    struct Signature: Equatable { let identity: String; let team: String; let runtime: Bool; let cdhash: String }
    static func required(_ executable: String, _ args: [String], command: DistributionCommand) throws -> Data {
        let result = try command(executable, args)
        guard result.exitCode == 0 else { throw VerificationFailure.toolFailed }
        return result.output
    }
    static func signature(_ url: URL, command: DistributionCommand) throws -> Signature? {
        _ = try required("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path], command: command)
        let text = String(decoding: try required("/usr/bin/codesign", ["--display", "--verbose=4", url.path], command: command), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        guard let authority = lines.first(where: { $0.hasPrefix("Authority=Developer ID Application: ") }) else { return nil }
        let identity = String(authority.dropFirst("Authority=".count)), team = try PackagingSigning.developerIdentity(identity)
        guard lines.contains("TeamIdentifier=" + team), let cd = lines.first(where: { $0.hasPrefix("CDHash=") }),
              String(cd.dropFirst(7)).range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil else { throw VerificationFailure.identityMismatch }
        return Signature(identity: identity, team: team, runtime: lines.contains(where: { $0.hasPrefix("CodeDirectory ") && $0.contains("(runtime)") }), cdhash: String(cd.dropFirst(7)))
    }
    static func acceptedID(_ raw: String) throws -> String {
        let result = try JSONDecoder().decode(Accepted.self, from: Data(raw.utf8))
        guard result.status == "Accepted", UUID(uuidString: result.id) != nil else { throw VerificationFailure.artifactFailed }
        return result.id
    }
    static func authenticate(_ submission: DistributionSubmission, package: URL, profile: String, command: DistributionCommand) throws -> String {
        let id = try acceptedID(submission.acceptedOutput)
        guard try packagingHash(package) == submission.submittedSHA256 else { throw VerificationFailure.identityMismatch }
        // A pasted Accepted ID/output alone is not evidence. Apple's fresh log must attest these submitted bytes.
        let bytes = try required("/usr/bin/xcrun", ["notarytool", "log", id, "--keychain-profile", profile], command: command)
        let log = try JSONDecoder().decode(NotaryLog.self, from: bytes)
        guard log.jobId == id, log.status == "Accepted", log.sha256 == submission.submittedSHA256 else { throw VerificationFailure.identityMismatch }
        return id
    }
    static func verifyContents(app: URL, manifest: URL, archive: URL, images: [URL], expected: Signature, command: DistributionCommand) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flowtype-distribution-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let original = try validateManifest(app: app, file: manifest)
        func checkApp(_ candidate: URL) throws {
            guard try validateManifest(app: candidate, file: manifest) == original,
                  try signature(candidate, command: command) == expected else { throw VerificationFailure.identityMismatch }
        }
        let extracted = root.appendingPathComponent("archive")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try required("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], command: command)
        try checkApp(extracted.appendingPathComponent("FlowType.app"))
        for image in images {
            let mount = root.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: mount, withIntermediateDirectories: false)
            _ = try required("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path], command: command)
            do {
                try checkApp(mount.appendingPathComponent("FlowType.app"))
                _ = try required("/usr/bin/hdiutil", ["detach", mount.path], command: command)
            } catch {
                _ = try? required("/usr/bin/hdiutil", ["detach", mount.path], command: command)
                throw error
            }
        }
    }
    static func evaluate(app: URL, manifest: URL, dmg: URL, evidence: URL, profile: String?, command: DistributionCommand) throws -> DistributionVerificationReport {
        let m = try JSONDecoder().decode(PackagingManifest.self, from: Data(contentsOf: manifest))
        let fm = FileManager.default
        let hash = fm.fileExists(atPath: dmg.path) ? try packagingHash(dmg) : nil
        var report = DistributionVerificationReport(schemaVersion: 1, status: .pending,
            candidate: DistributionCandidate(gitSHA: m.buildInfo.gitSHA, sourceTree: m.buildInfo.sourceTree, binarySHA256: m.binarySHA256, appPath: app.path, packageSHA256: hash), dmgSHA256: hash)
        do {
            _ = try validateManifest(app: app, file: manifest)
            guard let signed = try signature(app, command: command) else { report.issues = ["Developer ID Application signature unavailable"]; return report }
            report.teamID = signed.team; report.hardenedRuntime = signed.runtime
            guard signed.runtime else { throw VerificationFailure.signatureFailed }
            guard let profile, !profile.isEmpty else { report.issues = ["FLOWTYPE_NOTARY_PROFILE unavailable"]; return report }
            guard hash != nil, fm.fileExists(atPath: evidence.path) else { report.issues = ["Final DMG or notary evidence unavailable"]; return report }
            let record = try JSONDecoder().decode(DistributionNotaryEvidence.self, from: Data(contentsOf: evidence))
            guard record.schemaVersion == 1, record.signingIdentity == signed.identity, record.teamID == signed.team,
                  try record.app.finalSHA256 == packagingFingerprint(app), record.dmg.finalSHA256 == hash,
                  let dmgSigned = try signature(dmg, command: command), dmgSigned.identity == signed.identity, dmgSigned.team == signed.team else { throw VerificationFailure.identityMismatch }
            let root = evidence.deletingLastPathComponent(), archive = root.appendingPathComponent("app-submitted.zip"), submittedDMG = root.appendingPathComponent("dmg-submitted.dmg")
            guard try signature(submittedDMG, command: command) == dmgSigned else { throw VerificationFailure.identityMismatch }
            report.appNotarizationID = try authenticate(record.app, package: archive, profile: profile, command: command)
            report.dmgNotarizationID = try authenticate(record.dmg, package: submittedDMG, profile: profile, command: command)
            guard report.appNotarizationID != report.dmgNotarizationID else { throw VerificationFailure.identityMismatch }
            try verifyContents(app: app, manifest: manifest, archive: archive, images: [submittedDMG, dmg], expected: signed, command: command)
            for target in [app, dmg] { _ = try required("/usr/bin/xcrun", ["stapler", "validate", target.path], command: command) }
            report.stapled = true
            _ = try required("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", app.path], command: command)
            _ = try required("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", dmg.path], command: command)
            report.gatekeeperAccepted = true
            guard try validateManifest(app: app, file: manifest) == m, try packagingHash(dmg) == hash,
                  try packagingFingerprint(app) == record.app.finalSHA256,
                  try packagingHash(archive) == record.app.submittedSHA256, try packagingHash(submittedDMG) == record.dmg.submittedSHA256 else { throw VerificationFailure.identityMismatch }
            report.status = .pass
        } catch {
            report.status = .fail
            report.issues = [(error as? VerificationFailure)?.rawValue ?? "Invalid distribution evidence or command failure"]
        }
        return report
    }

    /// Live CLI invocation requires explicit --distribute; self-tests inject every external command.
    @discardableResult
    static func distribute(repository: URL, app: URL, manifest: URL, dmg: URL, evidence: URL, identity: String, profile: String, command: DistributionCommand, beforePublish: () throws -> Void = {}, publishReport: (DistributionVerificationReport) throws -> Void = { _ in }) throws -> DistributionVerificationReport {
        let fm = FileManager.default
        _ = try PackagingSigning.developerIdentity(identity)
        guard !profile.isEmpty, let signed = try signature(app, command: command), signed.identity == identity, signed.runtime else { throw VerificationFailure.signatureFailed }
        let original = try validateManifest(app: app, file: manifest)
        let root = evidence.deletingLastPathComponent()
        guard !fm.fileExists(atPath: evidence.path), !fm.fileExists(atPath: root.appendingPathComponent("app-submitted.zip").path),
              !fm.fileExists(atPath: root.appendingPathComponent("dmg-submitted.dmg").path) else { throw VerificationFailure.outputUnavailable }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("app-submitted.zip"), submitted = root.appendingPathComponent("dmg-submitted.dmg")
        func submit(_ package: URL, label: String) throws -> (String, String) {
            let before = try packagingHash(package)
            let response = try command("/usr/bin/xcrun", ["notarytool", "submit", package.path, "--keychain-profile", profile, "--wait", "--output-format", "json"])
            let raw = response.output
            // Preserve even rejected raw responses for diagnosis; never synthesize an Accepted result.
            try raw.write(to: root.appendingPathComponent(label + "-submit.json"), options: .withoutOverwriting)
            guard response.exitCode == 0 else { throw VerificationFailure.artifactFailed }
            let text = String(decoding: raw, as: UTF8.self)
            _ = try acceptedID(text)
            guard try packagingHash(package) == before else { throw VerificationFailure.identityMismatch }
            return (text, before)
        }
        _ = try required("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path], command: command)
        let appSubmission = try submit(archive, label: "app")
        _ = try required("/usr/bin/xcrun", ["stapler", "staple", app.path], command: command)
        _ = try required("/usr/bin/xcrun", ["stapler", "validate", app.path], command: command)
        guard try validateManifest(app: app, file: manifest) == original, try signature(app, command: command) == signed else { throw VerificationFailure.identityMismatch }
        let check = root.appendingPathComponent("app-check")
        try fm.createDirectory(at: check, withIntermediateDirectories: false)
        _ = try required(repository.appendingPathComponent("scripts/check-app.sh").path, ["--app", app.path, "--output", check.path], command: command)
        let image = root.appendingPathComponent("image")
        try fm.createDirectory(at: image, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: image) }
        _ = try required("/usr/bin/ditto", [app.path, image.appendingPathComponent("FlowType.app").path], command: command)
        try fm.createSymbolicLink(atPath: image.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        _ = try required("/usr/bin/hdiutil", ["create", "-volname", "FlowType", "-srcfolder", image.path, "-format", "UDZO", submitted.path], command: command)
        _ = try required("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp", submitted.path], command: command)
        let dmgSubmission = try submit(submitted, label: "dmg")
        let final = root.appendingPathComponent("final.dmg")
        try fm.copyItem(at: submitted, to: final)
        _ = try required("/usr/bin/xcrun", ["stapler", "staple", final.path], command: command)
        _ = try required("/usr/bin/xcrun", ["stapler", "validate", final.path], command: command)
        let record = try DistributionNotaryEvidence(schemaVersion: 1, signingIdentity: signed.identity, teamID: signed.team,
            app: DistributionSubmission(acceptedOutput: appSubmission.0, submittedSHA256: appSubmission.1, finalSHA256: packagingFingerprint(app)),
            dmg: DistributionSubmission(acceptedOutput: dmgSubmission.0, submittedSHA256: dmgSubmission.1, finalSHA256: packagingHash(final)))
        try JSONEncoder().encode(record).write(to: evidence, options: .withoutOverwriting)
        let checked = try evaluate(app: app, manifest: manifest, dmg: final, evidence: evidence, profile: profile, command: command)
        guard checked.status == .pass else { throw VerificationFailure.artifactFailed }
        // Source/cancellation validation is the last pre-publication condition. Retain the
        // previous bytes until the success report is durable; reporting failure rolls back.
        try beforePublish()
        let backup = root.appendingPathComponent("previous.dmg")
        let hadPrevious = fm.fileExists(atPath: dmg.path)
        guard (try? fm.destinationOfSymbolicLink(atPath: dmg.path)) == nil else { throw VerificationFailure.outputUnavailable }
        if hadPrevious {
            guard try dmg.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw VerificationFailure.outputUnavailable }
            try fm.linkItem(at: dmg, to: backup)
        }
        guard rename(final.path, dmg.path) == 0 else {
            if hadPrevious { try? fm.removeItem(at: backup) }
            throw VerificationFailure.outputUnavailable
        }
        do { try publishReport(checked) }
        catch {
            if hadPrevious {
                guard rename(backup.path, dmg.path) == 0 else { throw VerificationFailure.recoveryFailed }
            } else { try fm.removeItem(at: dmg) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
        return checked
    }
}
