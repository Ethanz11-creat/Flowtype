import Foundation

/// All handle, formatter and rotation state is confined to the private serial queue.
/// Explicit paths keep initialization failure from falling back to production logs.
final class DiagnosticLogWriter: @unchecked Sendable {
    let fileURL: URL
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let role: ProcessRole
    private let runID: UUID
    private let identity: BuildIdentity
    private let maxLogSize: UInt64
    private let maxRotatedFiles: Int
    private let formatter: ISO8601DateFormatter
    private var handle: FileHandle?
    private var offset: UInt64 = 0

    init(fileURL: URL, role: ProcessRole, runID: UUID, identity: BuildIdentity,
         maxLogSize: UInt64 = 10 * 1024 * 1024, maxRotatedFiles: Int = 3,
         queue: DispatchQueue = DispatchQueue(label: "com.flowtype.diagnostics", qos: .utility)) throws {
        precondition(maxLogSize > 0 && maxRotatedFiles >= 1)
        self.fileURL = fileURL; self.queue = queue; self.role = role; self.runID = runID
        self.identity = identity; self.maxLogSize = maxLogSize; self.maxRotatedFiles = maxRotatedFiles
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        queue.setSpecific(key: queueKey, value: 1)
        // Required startup identity is synchronous, including disk synchronization, and may throw.
        try onQueue {
            try open()
            try appendHeader()
            try handle?.synchronize()
        }
    }

    deinit { try? handle?.close() }

    func log(_ message: String) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { write(message) }
        else { queue.async { self.write(message) } }
    }

    func flush() {
        onQueue { try? handle?.synchronize() }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    private func line(_ message: String) -> Data {
        let marker = role == .selfTest ? " [SelfTest]" : ""
        let prefix = "[\(formatter.string(from: Date()))] role=\(role.rawValue) runID=\(runID.uuidString)\(marker) "
        // Prefix each physical line; multiline diagnostics cannot lose their role/run ownership.
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return Data((normalized.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n") + "\n").utf8)
    }

    private func append(_ data: Data) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func appendHeader() throws {
        let encoded = try JSONEncoder().encode(identity)
        let json = String(decoding: encoded, as: UTF8.self)
        try append(line("BuildIdentity \(json)"))
    }

    private func write(_ message: String) {
        do {
            if handle == nil { try open(); try appendHeader() }
            // Rotate before the next record, preserving its sentinel in the active file.
            if offset >= maxLogSize { try rotate(); try open(); try appendHeader() }
            try append(line(message))
        } catch {
            // Later diagnostic I/O failures must not crash dictation. Never select another path.
            try? handle?.close(); handle = nil
        }
    }

    private func open() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let file = try FileHandle(forWritingTo: fileURL)
        offset = try file.seekToEnd()
        handle = file
    }

    private func rotate() throws {
        try handle?.close(); handle = nil
        let fm = FileManager.default
        func archive(_ index: Int) -> URL { URL(fileURLWithPath: fileURL.path + ".\(index)") }
        if fm.fileExists(atPath: archive(maxRotatedFiles).path) { try fm.removeItem(at: archive(maxRotatedFiles)) }
        if maxRotatedFiles > 1 {
            for index in (1..<maxRotatedFiles).reversed() where fm.fileExists(atPath: archive(index).path) {
                try fm.moveItem(at: archive(index), to: archive(index + 1))
            }
        }
        try fm.moveItem(at: fileURL, to: archive(1))
    }
}
