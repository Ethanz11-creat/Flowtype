import Foundation
import Darwin

struct BoundedCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]
    let stdoutURL: URL
    let stderrURL: URL
    let timeoutSeconds: Double
}
enum BoundedTermination: String, Codable, Sendable { case normal, signal, launchFailure, timeout }
enum BoundedFailure: String, Codable, Sendable { case launchFailed, handshakeFailed, deadlineExceeded, childSignaled, childFailed, cleanupFailed }
struct BoundedResult: Codable, Sendable {
    let schemaVersion: Int
    let exitCode: Int32?
    let termination: BoundedTermination
    let durationMs: Int
    let timedOut: Bool
    let failureCode: BoundedFailure?
    private enum CodingKeys: String, CodingKey { case schemaVersion, exitCode, termination, durationMs, timedOut, failureCode }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(exitCode, forKey: .exitCode)
        try c.encode(termination, forKey: .termination); try c.encode(durationMs, forKey: .durationMs)
        try c.encode(timedOut, forKey: .timedOut); try c.encode(failureCode, forKey: .failureCode)
    }
    var cliExitCode: Int32 {
        switch termination { case .normal: exitCode ?? 1; case .timeout: 124; case .signal, .launchFailure: 1 }
    }
}
enum BoundedProcessError: Error { case invalidCommand, outputUnavailable, childControl }

enum BoundedProcess {
    /// Every consuming CLI must call this before its ordinary option parsing.
    /// fd0 is a private full-duplex launch socket only until exec; target stdin is /dev/null.
    static func dispatchChildIfNeeded(arguments: [String]) throws {
        guard arguments.first == "--bounded-child" else { return }
        guard arguments.count >= 3, arguments[1] == "--" else { throw BoundedProcessError.childControl }
        var type: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(STDIN_FILENO, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == SOCK_STREAM else {
            throw BoundedProcessError.childControl
        }
        let control = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        guard control >= 0 else { throw BoundedProcessError.childControl }
        defer { close(control) }
        guard setpgid(0, 0) == 0 else { throw BoundedProcessError.childControl }
        let ready = Array("READY \(getpid())\n".utf8)
        guard ready.withUnsafeBytes({ Darwin.write(control, $0.baseAddress, $0.count) }) == ready.count else { throw BoundedProcessError.childControl }
        let null = open("/dev/null", O_RDONLY)
        guard null >= 0 else { throw BoundedProcessError.childControl }
        guard dup2(null, STDIN_FILENO) >= 0 else { close(null); throw BoundedProcessError.childControl }
        if null != STDIN_FILENO { close(null) }
        let target = Array(arguments.dropFirst(2))
        let strings = target.map { strdup($0) }
        defer { for string in strings { free(string) } }
        var argv = strings + [nil]
        argv.withUnsafeMutableBufferPointer { buffer in _ = execv(target[0], buffer.baseAddress!) }
        let failure = Array("EXECFAIL\n".utf8)
        _ = failure.withUnsafeBytes { Darwin.write(control, $0.baseAddress, $0.count) }
        throw BoundedProcessError.childControl
    }

    /// Synchronous, external process watchdog. No target actor/run loop participates in its deadline.
    static func run(_ command: BoundedCommand, runnerExecutableURL: URL? = nil,
                    shouldCancel: () -> Bool = { false }, onLaunch: (Int32) throws -> Void = { _ in }) throws -> BoundedResult {
        guard command.timeoutSeconds.isFinite, command.timeoutSeconds > 0,
              command.stdoutURL.standardizedFileURL != command.stderrURL.standardizedFileURL,
              !([command.executable.path] + command.arguments).contains(where: { $0.utf8.contains(0) }) else {
            throw BoundedProcessError.invalidCommand
        }
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
        func result(_ termination: BoundedTermination, _ failure: BoundedFailure?, _ exit: Int32? = nil) -> BoundedResult {
            BoundedResult(schemaVersion: 1, exitCode: exit, termination: termination, durationMs: Int(elapsed() * 1000),
                          timedOut: termination == .timeout, failureCode: failure)
        }
        let fm = FileManager.default
        try Data().write(to: command.stdoutURL, options: .withoutOverwriting)
        try Data().write(to: command.stderrURL, options: .withoutOverwriting)
        let stdout = try FileHandle(forWritingTo: command.stdoutURL)
        let stderr = try FileHandle(forWritingTo: command.stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        guard fm.isExecutableFile(atPath: command.executable.path) else { return result(.launchFailure, .launchFailed) }
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw BoundedProcessError.childControl }
        let parent = sockets[0]
        let input = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        defer { close(parent); try? input.close() }
        _ = fcntl(parent, F_SETFD, FD_CLOEXEC)
        _ = fcntl(parent, F_SETFL, O_NONBLOCK)
        let process = Process()
        process.executableURL = runnerExecutableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--bounded-child", "--", command.executable.path] + command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = command.environment
        process.standardInput = input; process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { return result(.launchFailure, .launchFailed) }
        try input.close()
        let pid = process.processIdentifier
        var ready = false
        func groupExists() -> Bool { kill(-pid, 0) == 0 || errno == EPERM }
        func stopOwned() -> Bool {
            // A handshake grants group ownership. Before it, verify this exact child's group.
            let ownGroup = pid > 1 && pid != getpgrp() && (ready || getpgid(pid) == pid)
            let target = ownGroup ? -pid : pid
            if process.isRunning || (ownGroup && groupExists()) { kill(target, SIGTERM) }
            let grace = elapsed() + 2
            while elapsed() < grace && (process.isRunning || (ownGroup && groupExists())) { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning || (ownGroup && groupExists()) { kill(target, SIGKILL) }
            let reap = elapsed() + 1
            while elapsed() < reap && (process.isRunning || (ownGroup && groupExists())) { Thread.sleep(forTimeInterval: 0.01) }
            return !process.isRunning && (!ownGroup || !groupExists())
        }
        do { try onLaunch(pid) }
        catch { _ = stopOwned(); throw error }
        var received = Data()
        var execConfirmed = false
        let handshakeLimit = min(command.timeoutSeconds, 5)
        while elapsed() < handshakeLimit {
            if shouldCancel() { let clean = stopOwned(); return result(.signal, clean ? .childSignaled : .cleanupFailed) }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(parent, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                if received.count > 512 { break }
                ready = String(decoding: received, as: UTF8.self).hasPrefix("READY \(pid)\n")
                if String(decoding: received, as: UTF8.self).contains("EXECFAIL") { break }
            } else if count == 0 {
                execConfirmed = received == Data("READY \(pid)\n".utf8)
                break
            } else if errno != EAGAIN && errno != EINTR { break }
            else { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard ready, execConfirmed else {
            let clean = stopOwned()
            return result(.launchFailure, !clean ? .cleanupFailed : String(decoding: received, as: UTF8.self).contains("EXECFAIL") ? .launchFailed : .handshakeFailed)
        }
        while process.isRunning && elapsed() < command.timeoutSeconds && !shouldCancel() { Thread.sleep(forTimeInterval: 0.01) }
        if shouldCancel() { let clean = stopOwned(); return result(.signal, clean ? .childSignaled : .cleanupFailed) }
        if process.isRunning {
            let clean = stopOwned()
            return result(.timeout, clean ? .deadlineExceeded : .cleanupFailed)
        }
        let reason = process.terminationReason
        let status = process.terminationStatus
        // A normally exiting parent may leave helpers in this owned group; clean that group too.
        guard stopOwned() else { return result(.launchFailure, .cleanupFailed) }
        if reason == .uncaughtSignal { return result(.signal, .childSignaled) }
        return result(.normal, status == 0 ? nil : .childFailed, status)
    }
}
