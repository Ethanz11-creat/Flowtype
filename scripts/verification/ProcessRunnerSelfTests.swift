import Foundation
import Darwin

enum ProcessRunnerSelfTests {
    private static func spawn(_ executable: String, _ arguments: [String]) -> pid_t {
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { for string in strings { free(string) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let status = argv.withUnsafeMutableBufferPointer { buffer in
            environment.withUnsafeMutableBufferPointer { values in
                posix_spawn(&pid, executable, nil, nil, buffer.baseAddress!, values.baseAddress!)
            }
        }
        precondition(status == 0)
        return pid
    }

    static func fixture(arguments: [String]) -> Bool {
        guard arguments.first == "--fixture", arguments.count >= 2 else { return false }
        switch arguments[1] {
        case "signal": raise(SIGKILL)
        case "output": FileHandle.standardOutput.write(Data(repeating: 65, count: 2 * 1024 * 1024)); exit(23)
        case "descendants", "grandchild":
            signal(SIGTERM, SIG_IGN)
            if arguments[1] == "descendants" {
                let child = spawn(CommandLine.arguments[0], ["--fixture", "grandchild", arguments[2]])
                try! Data("\(getpid())\n\(child)\n".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            } else {
                let child = spawn("/bin/sleep", ["30"])
                let url = URL(fileURLWithPath: arguments[2] + ".grandchild")
                try! Data("\(child)".utf8).write(to: url)
            }
            while true { pause() }
        case "blocked", "independent": while true { pause() }
        default: exit(64)
        }
        exit(0)
    }

    static func run() -> Int32 {
        var passed = 0; var failed = 0
        func check(_ value: Bool, _ name: String) { if value { passed += 1 } else { failed += 1; print("FAIL: \(name)") } }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("flowtype-process-\(UUID())")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            var sequence = 0
            func command(_ args: [String], timeout: Double = 0.4, executable: URL? = nil) -> BoundedCommand {
                sequence += 1
                return BoundedCommand(executable: executable ?? own, arguments: args, workingDirectory: root, environment: [:],
                    stdoutURL: root.appendingPathComponent("stdout-\(sequence)"), stderrURL: root.appendingPathComponent("stderr-\(sequence)"), timeoutSeconds: timeout)
            }
            let independent = Process(); independent.executableURL = own; independent.arguments = ["--fixture", "independent"]
            independent.standardInput = FileHandle.nullDevice; independent.standardOutput = FileHandle.nullDevice; independent.standardError = FileHandle.nullDevice
            try independent.run()
            defer { if independent.isRunning { kill(independent.processIdentifier, SIGKILL) } }
            let blocked = try BoundedProcess.run(command(["--fixture", "blocked"]))
            check(blocked.timedOut && blocked.termination == .timeout && blocked.durationMs < 5000, "blocked main times out without unbounded wait")
            check(blocked.cliExitCode == 124, "timeout CLI status124")
            let signaled = try BoundedProcess.run(command(["--fixture", "signal"], timeout: 3))
            check(signaled.termination == .signal && !signaled.timedOut, "signal exit is failure")
            check(signaled.cliExitCode == 1 && signaled.failureCode == .childSignaled, "signal CLI failure status")
            let outputCommand = command(["--fixture", "output"], timeout: 3)
            let output = try BoundedProcess.run(outputCommand)
            check(output.termination == .normal && output.exitCode == 23, "normal child exit status preserved")
            check(try Data(contentsOf: outputCommand.stdoutURL).count == 2 * 1024 * 1024, "large stdout fully drained to file")
            check(output.cliExitCode == 23, "CLI preserves normal nonzero child status")
            let inputCommand = command([], timeout: 3, executable: URL(fileURLWithPath: "/bin/cat"))
            let input = try BoundedProcess.run(inputCommand)
            check(input.cliExitCode == 0 && input.failureCode == nil, "normal successful CLI status0")
            check(try Data(contentsOf: inputCommand.stdoutURL).isEmpty, "target stdin is closed /dev/null")
            let successJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
            check(successJSON["failureCode"] is NSNull, "successful result failure is explicit null")
            let literal = "literal spaces; $(touch forbidden)"
            let literalCommand = command(["%s", literal], timeout: 3, executable: URL(fileURLWithPath: "/usr/bin/printf"))
            let literalResult = try BoundedProcess.run(literalCommand)
            check(try literalResult.exitCode == 0 && String(contentsOf: literalCommand.stdoutURL, encoding: .utf8) == literal,
                  "arguments remain literal without shell evaluation")
            let pids = root.appendingPathComponent("descendants.pid")
            let descendants = try BoundedProcess.run(command(["--fixture", "descendants", pids.path], timeout: 1))
            var owned: [pid_t] = []
            if let text = try? String(contentsOf: pids, encoding: .utf8) { owned += text.split(separator: "\n").compactMap { Int32($0) } }
            if let text = try? String(contentsOf: URL(fileURLWithPath: pids.path + ".grandchild"), encoding: .utf8), let pid = Int32(text) { owned.append(pid) }
            defer { for pid in owned where kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
            check(descendants.timedOut && descendants.durationMs >= 2900 && descendants.durationMs < 6000, "TERM grace then bounded KILL")
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline && owned.contains(where: { kill($0, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.02) }
            if owned.contains(where: { kill($0, 0) == 0 }) { print("owned fixture states: " + owned.map { "pid=\($0) group=\(getpgid($0)) alive=\(kill($0, 0) == 0)" }.joined(separator: "; ")) }
            check(owned.count == 3 && owned.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }, "all owned descendants terminated")
            check(independent.isRunning, "independent fixture survives other group cleanup")
            let missing = try BoundedProcess.run(command([], executable: root.appendingPathComponent("missing")))
            check(missing.termination == .launchFailure && missing.failureCode != nil, "missing executable is closed launch failure")
            let handshake = try BoundedProcess.run(command(["--fixture", "blocked"]), runnerExecutableURL: URL(fileURLWithPath: "/usr/bin/true"))
            check(handshake.termination == .launchFailure && handshake.failureCode == .handshakeFailed && !handshake.timedOut, "missing child handshake fails without launching target")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as! [String: Any]
            check(encoded["timedOut"] as? Bool == false, "result is Codable")
        } catch { check(false, "process fixture operation failed") }
        print("=== process runner self-test: \(passed) passed, \(failed) failed ===")
        return failed == 0 ? 0 : 1
    }
}
