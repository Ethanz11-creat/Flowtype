import Foundation
import Darwin

struct DistributionOptions {
    let app: URL; let manifest: URL; let dmg: URL; let evidence: URL; let output: URL
    let distribute: Bool
    static func parse(_ args: [String]) throws -> DistributionOptions {
        var args = args, distribute = false
        if args.first == "--distribute" { distribute = true; args.removeFirst() }
        let keys: Set<String> = ["--app", "--manifest", "--dmg", "--notary-evidence", "--output"]
        guard args.count == 10 else { throw VerificationFailure.usage }
        var values: [String: URL] = [:]
        for index in stride(from: 0, to: args.count, by: 2) {
            let key = args[index], path = args[index + 1]
            guard keys.contains(key), values[key] == nil, path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw VerificationFailure.usage }
            values[key] = URL(fileURLWithPath: path)
        }
        guard Set(values.keys) == keys, values["--app"]!.pathExtension == "app", values["--dmg"]!.pathExtension == "dmg",
              Set(values.values.map(\.path)).count == 5,
              !values["--output"]!.path.hasPrefix(values["--app"]!.path + "/") else { throw VerificationFailure.usage }
        return DistributionOptions(app: values["--app"]!, manifest: values["--manifest"]!, dmg: values["--dmg"]!, evidence: values["--notary-evidence"]!, output: values["--output"]!, distribute: distribute)
    }
}
@main enum DistributionVerificationCLI {
    static func write(_ report: DistributionVerificationReport, to output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
    }
    /// Deliberately no candidate: D2 cannot decode this marker as a successful attestation.
    static func invalidate(_ output: URL) throws {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "status": "Fail",
            "issues": ["Verification incomplete; candidate unavailable"]], options: [.sortedKeys]).write(to: output, options: .atomic)
    }
    static func persistFailure(_ error: Error, options: DistributionOptions) throws {
        guard let m = try? validateManifest(app: options.app, file: options.manifest) else { try invalidate(options.output); return }
        let hash = try? packagingHash(options.dmg)
        var report = DistributionVerificationReport(schemaVersion: 1, status: .fail,
            candidate: DistributionCandidate(gitSHA: m.buildInfo.gitSHA, sourceTree: m.buildInfo.sourceTree, binarySHA256: m.binarySHA256,
                appPath: options.app.path, packageSHA256: hash), dmgSHA256: hash)
        report.issues = [(error as? VerificationFailure)?.rawValue ?? "Distribution verification failed"]
        try write(report, to: options.output)
    }
    static func main() {
        var selected: DistributionOptions?
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            try BoundedProcess.dispatchChildIfNeeded(arguments: args)
            if args == ["--self-test"] { exit(DistributionVerificationSelfTests.run()) }
            let options = try DistributionOptions.parse(args)
            let fm = FileManager.default
            try fm.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try canonicalExisting(options.output.deletingLastPathComponent()).path == options.output.deletingLastPathComponent().path,
                  (try? fm.destinationOfSymbolicLink(atPath: options.output.path)) == nil,
                  try (!fm.fileExists(atPath: options.output.path) || options.output.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true) else { throw VerificationFailure.outputUnavailable }
            // Invalidate prior success before *any* app/manifest/hash/source/command work.
            selected = options
            try invalidate(options.output)
            try packagingCancellation.install()
            let repo = try canonicalExisting(URL(fileURLWithPath: fm.currentDirectoryPath))
            guard try canonicalExisting(options.app).path == options.app.path else { throw VerificationFailure.outputUnavailable }
            let logs = options.output.deletingLastPathComponent().appendingPathComponent("distribution-\(UUID())")
            try fm.createDirectory(at: logs, withIntermediateDirectories: false)
            let command: DistributionCommand = { executable, arguments in
                let token = UUID().uuidString, out = logs.appendingPathComponent("\(token).stdout"), err = logs.appendingPathComponent("\(token).stderr")
                let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: executable), arguments: arguments,
                    workingDirectory: repo, environment: ProcessInfo.processInfo.environment, stdoutURL: out, stderrURL: err,
                    timeoutSeconds: arguments.contains("submit") ? 1800 : 180), shouldCancel: { packagingCancellation.isCancelled() })
                let data = try Data(contentsOf: out)
                return DistributionCommandResult(exitCode: result.cliExitCode, output: data.isEmpty ? try Data(contentsOf: err) : data)
            }
            let environment = ProcessInfo.processInfo.environment
            let profile = environment["FLOWTYPE_NOTARY_PROFILE"], identity = environment["FLOWTYPE_SIGNING_IDENTITY"]
            let report: DistributionVerificationReport
            if options.distribute, let identity, !identity.isEmpty, let profile, !profile.isEmpty {
                guard options.app.path == repo.appendingPathComponent("build/FlowType.app").path,
                      options.manifest.path == repo.appendingPathComponent("build/FlowType.manifest.json").path,
                      options.dmg.deletingLastPathComponent().path == repo.appendingPathComponent("build").path,
                      options.evidence.path.hasPrefix(repo.appendingPathComponent("build").path + "/") else { throw VerificationFailure.usage }
                let source = try packagingSnapshot(repo: repo, logs: logs)
                let manifest = try validateManifest(app: options.app, file: options.manifest)
                guard manifest.buildInfo.gitSHA == source,
                      manifest.buildInfo.sourceTree == (try packagingGit(["rev-parse", "HEAD:Sources"], repo: repo, logs: logs)) else { throw VerificationFailure.identityMismatch }
                report = try DistributionVerification.distribute(repository: repo, app: options.app, manifest: options.manifest, dmg: options.dmg,
                    evidence: options.evidence, identity: identity, profile: profile, command: command, beforePublish: {
                        guard try packagingSnapshot(repo: repo, logs: logs) == source else { throw VerificationFailure.sourceChanged }
                        guard !packagingCancellation.isCancelled() else { throw PackagingFailure.interrupted }
                    }, publishReport: { try write($0, to: options.output) })
            } else {
                var evaluated = try DistributionVerification.evaluate(app: options.app, manifest: options.manifest, dmg: options.dmg,
                    evidence: options.evidence, profile: options.distribute && (identity ?? "").isEmpty ? nil : profile, command: command)
                if options.distribute && (identity ?? "").isEmpty && evaluated.status != .fail {
                    evaluated.status = .pending; evaluated.issues.append("FLOWTYPE_SIGNING_IDENTITY unavailable")
                }
                try write(evaluated, to: options.output)
                report = evaluated
            }
            print("Distribution verification: \(report.status.rawValue)")
            exit(report.exitCode)
        } catch {
            if let selected {
                do { try persistFailure(error, options: selected) }
                catch {
                    // A reporting failure must not leave a previous successful attestation.
                    try? FileManager.default.removeItem(at: selected.output)
                }
            }
            print("Distribution verification: \((error as? VerificationFailure)?.rawValue ?? "toolFailed")")
            exit(selected == nil && (error as? VerificationFailure) == .usage ? 64 : 1)
        }
    }
}
