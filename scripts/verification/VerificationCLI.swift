import Foundation
import Darwin

struct VerificationOptions {
    let lane: VerificationLane; let manual: URL?; let ci: URL?
    static func parse(_ arguments: [String]) throws -> VerificationOptions {
        var lane: VerificationLane?; var manual: URL?; var ci: URL?; var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw VerificationFailure.usage }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--lane": guard lane == nil, let parsed = VerificationLane(rawValue: value) else { throw VerificationFailure.usage }; lane = parsed
            case "--manual-report": guard manual == nil else { throw VerificationFailure.usage }; manual = URL(fileURLWithPath: value)
            case "--ci-report": guard ci == nil else { throw VerificationFailure.usage }; ci = URL(fileURLWithPath: value)
            default: throw VerificationFailure.usage
            }
            index += 2
        }
        return VerificationOptions(lane: lane ?? .code, manual: manual, ci: ci)
    }
}
@main enum VerificationCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do { try BoundedProcess.dispatchChildIfNeeded(arguments: arguments) }
        catch { FileHandle.standardError.write(Data("FlowType verification: child control failed\n".utf8)); exit(125) }
        if arguments == ["--self-test"] { exit(VerificationSelfTests.run()) }
        do {
            let options = try VerificationOptions.parse(arguments)
            try packagingCancellation.install()
            let repository = try canonicalExisting(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            let output = try VerificationPaths.prepare(repository: repository).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let report = try VerificationRunner.run(lane: options.lane, repository: repository, output: output, manualReport: options.manual, ciReport: options.ci)
            print("Verification \(options.lane.rawValue): \(report.status.rawValue)")
            print("build/verification/\(output.lastPathComponent)/verify-report.json")
            exit(report.exitCode)
        } catch {
            let failure = (error as? VerificationFailure) ?? .toolFailed
            FileHandle.standardError.write(Data("FlowType verification: \(failure.rawValue)\n".utf8))
            exit(failure == .usage ? 64 : 1)
        }
    }
}
