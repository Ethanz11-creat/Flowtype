import Foundation
import Darwin

struct VerificationOptions {
    let lane: VerificationLane; let manual: URL?; let ci: URL?
    var candidateManifest: URL? = nil
    static func parse(_ arguments: [String]) throws -> VerificationOptions {
        var lane: VerificationLane?; var manual: URL?; var ci: URL?; var candidate: URL?; var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw VerificationFailure.usage }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--lane": guard lane == nil, let parsed = VerificationLane(rawValue: value) else { throw VerificationFailure.usage }; lane = parsed
            case "--manual-report": guard manual == nil else { throw VerificationFailure.usage }; manual = URL(fileURLWithPath: value)
            case "--ci-report": guard ci == nil else { throw VerificationFailure.usage }; ci = URL(fileURLWithPath: value)
            case "--candidate-manifest": guard candidate == nil, value.hasPrefix("/") else { throw VerificationFailure.usage }; candidate = URL(fileURLWithPath: value)
            default: throw VerificationFailure.usage
            }
            index += 2
        }
        guard candidate == nil || lane == .artifact || lane == .release else { throw VerificationFailure.usage }
        return VerificationOptions(lane: lane ?? .code, manual: manual, ci: ci, candidateManifest: candidate)
    }
}
struct VerificationExportOptions {
    let root: URL; let output: URL
    static func parse(_ args: [String]) throws -> VerificationExportOptions {
        guard args.count == 4, args[0] == "--export-evidence", args[2] == "--output",
              !args[1].isEmpty, !args[3].isEmpty, !args[1].hasPrefix("--"), !args[3].hasPrefix("--") else { throw VerificationFailure.usage }
        return VerificationExportOptions(root: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[3]))
    }
}
@main enum VerificationCLI {
    static func verify(_ options: VerificationOptions, repository: URL, dependencies: VerificationDependencies = .live(), announce: (String) -> Void = { print($0) }) throws -> VerificationReport {
        let output = try VerificationPaths.prepare(repository: repository).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        announce("build/verification/\(output.lastPathComponent)/verify-report.json")
        let report = try VerificationRunner.run(lane: options.lane, repository: repository, output: output, manualReport: options.manual, ciReport: options.ci, candidateManifest: options.candidateManifest, dependencies: dependencies)
        return report
    }
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do { try BoundedProcess.dispatchChildIfNeeded(arguments: arguments) }
        catch { FileHandle.standardError.write(Data("FlowType verification: child control failed\n".utf8)); exit(125) }
        if arguments == ["--self-test"] { exit(VerificationSelfTests.run()) }
        do {
            if arguments.first == "--write-manual-template" {
                guard arguments.count == 2, !arguments[1].isEmpty, !arguments[1].hasPrefix("--") else { throw VerificationFailure.usage }
                try ManualValidation.writeTemplate(to: URL(fileURLWithPath: arguments[1]))
                print("Manual template: 41 Pending")
                exit(0)
            }
            if arguments.first == "--export-evidence" {
                let options = try VerificationExportOptions.parse(arguments)
                let files = try VerificationEvidence.exportRun(runRoot: options.root, destination: options.output)
                print("Evidence export: \(files.count) files")
                exit(0)
            }
            let options = try VerificationOptions.parse(arguments)
            try packagingCancellation.install()
            let repository = try canonicalExisting(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            let report = try verify(options, repository: repository)
            print("Verification \(options.lane.rawValue): \(report.status.rawValue)")
            exit(report.exitCode)
        } catch {
            let failure = (error as? VerificationFailure) ?? .toolFailed
            FileHandle.standardError.write(Data("FlowType verification: \(failure.rawValue)\n".utf8))
            exit(failure == .usage ? 64 : 1)
        }
    }
}
