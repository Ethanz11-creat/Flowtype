import Foundation
import Darwin

@main
enum ProcessCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do { try BoundedProcess.dispatchChildIfNeeded(arguments: arguments) }
        catch { FileHandle.standardError.write(Data("FlowType runner: child control failed\n".utf8)); exit(125) }
        if ProcessRunnerSelfTests.fixture(arguments: arguments) { return }
        if arguments == ["--self-test"] { exit(ProcessRunnerSelfTests.run()) }
        var timeout: Double?; var stdout: String?; var stderr: String?; var report: String?; var target: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--" { target = Array(arguments.dropFirst(index + 1)); break }
            guard index + 1 < arguments.count else { exit(64) }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--timeout": guard timeout == nil, let number = Double(value), number.isFinite, number > 0 else { exit(64) }; timeout = number
            case "--stdout": guard stdout == nil else { exit(64) }; stdout = value
            case "--stderr": guard stderr == nil else { exit(64) }; stderr = value
            case "--result": guard report == nil else { exit(64) }; report = value
            default: exit(64)
            }
            index += 2
        }
        guard let timeout, let stdout, let stderr, let report, !target.isEmpty else { exit(64) }
        let reportURL = URL(fileURLWithPath: report).standardizedFileURL
        guard reportURL != URL(fileURLWithPath: stdout).standardizedFileURL,
              reportURL != URL(fileURLWithPath: stderr).standardizedFileURL else { exit(64) }
        do {
            guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw BoundedProcessError.outputUnavailable }
            let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: target[0]), arguments: Array(target.dropFirst()),
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), environment: ProcessInfo.processInfo.environment,
                stdoutURL: URL(fileURLWithPath: stdout), stderrURL: URL(fileURLWithPath: stderr), timeoutSeconds: timeout))
            try JSONEncoder().encode(result).write(to: reportURL, options: .withoutOverwriting)
            exit(result.cliExitCode)
        } catch { FileHandle.standardError.write(Data("FlowType runner: tool failure\n".utf8)); exit(125) }
    }
}
