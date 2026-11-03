import Foundation
import AppKit
import os

enum AppLoggerError: String, Error { case alreadyConfigured }

/// Configured once at main's role boundary, before any shared service can log.
enum AppLogger {
    private struct State: Sendable {
        var writer: DiagnosticLogWriter?
        var identity: BuildIdentity?
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(context: RuntimeContext, identity: BuildIdentity) throws {
        try state.withLock { value in
            guard value.writer == nil else { throw AppLoggerError.alreadyConfigured }
            let filename: String
            switch context.role {
            case .app: filename = "diagnostic.log"
            case .selfTest: filename = "diagnostic-selftest.log"
            case .smokeTest: filename = "diagnostic-smoke.log"
            }
            let writer = try DiagnosticLogWriter(fileURL: context.paths.logsDirectory.appendingPathComponent(filename),
                                                 role: context.role, runID: context.runID, identity: identity)
            value.identity = identity
            value.writer = writer
        }
    }

    static func log(_ message: String) { state.withLock { $0.writer }?.log(message) }
    static func flush() { state.withLock { $0.writer }?.flush() }

    static var identity: BuildIdentity {
        state.withLock { value in
            guard let identity = value.identity else { preconditionFailure("AppLogger accessed before configure") }
            return identity
        }
    }

    static var logFileURL: URL {
        state.withLock { value in
            guard let writer = value.writer else { preconditionFailure("AppLogger accessed before configure") }
            return writer.fileURL
        }
    }

    static func openLogInFinder() {
        guard RuntimeEnvironment.current.role == .app else { return }
        NSWorkspace.shared.open(logFileURL)
    }
}
