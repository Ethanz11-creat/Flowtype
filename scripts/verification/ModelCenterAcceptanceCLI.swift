import Foundation
import Darwin

struct ModelCenterAcceptanceOptions {
    let report: URL
    let manifest: URL
    let distributionReport: URL
    static func parse(_ args: [String]) throws -> ModelCenterAcceptanceOptions {
        var values: [String: URL] = [:]
        let flags: Set<String> = ["--report", "--manifest", "--distribution-report"]
        guard args.count == 6 else { throw VerificationFailure.usage }
        for index in stride(from: 0, to: args.count, by: 2) {
            let flag = args[index], path = args[index + 1]
            guard flags.contains(flag), values[flag] == nil, !path.isEmpty, !path.hasPrefix("--") else { throw VerificationFailure.usage }
            values[flag] = URL(fileURLWithPath: path)
        }
        guard let report = values["--report"], let manifest = values["--manifest"], let distribution = values["--distribution-report"] else { throw VerificationFailure.usage }
        return ModelCenterAcceptanceOptions(report: report, manifest: manifest, distributionReport: distribution)
    }
}

@main enum ModelCenterAcceptanceCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--self-test"] { exit(ModelCenterAcceptanceSelfTests.run()) }
        do {
            if args.first == "--write-template" {
                guard args.count == 2, !args[1].isEmpty, !args[1].hasPrefix("--") else { throw VerificationFailure.usage }
                let file = URL(fileURLWithPath: args[1])
                guard try canonicalExisting(file.deletingLastPathComponent()).path == file.deletingLastPathComponent().path,
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw VerificationFailure.outputUnavailable }
                try ModelCenterAcceptance.templateData().write(to: file, options: .withoutOverwriting)
                print("Model center template: 30 Pending")
                return
            }
            let options = try ModelCenterAcceptanceOptions.parse(args)
            let status = try ModelCenterAcceptance.evaluate(report: options.report, manifest: options.manifest, distributionReport: options.distributionReport)
            print("Model center acceptance: \(status.rawValue)")
            exit(status == .pass ? 0 : status == .fail ? 1 : 2)
        } catch {
            FileHandle.standardError.write(Data("Model center acceptance: \(error)\n".utf8))
            exit((error as? VerificationFailure) == .usage ? 64 : 1)
        }
    }
}
