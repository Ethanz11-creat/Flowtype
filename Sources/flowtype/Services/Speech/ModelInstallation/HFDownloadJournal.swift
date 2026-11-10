import Foundation
import CryptoKit

struct HFDownloadError: Error, Equatable, Sendable {
    enum Code: String, Codable, Sendable { case auth, rateLimit, network, integrity, diskFull, cancelled }
    let code: Code
    /// A long server-requested delay pauses the job rather than holding the network slot.
    var retryAfter: TimeInterval? = nil
    var requiresPause: Bool = false

    static func disk(_ error: Error) -> HFDownloadError {
        let e = error as NSError
        let full = (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) ||
            (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError) ||
            (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC) } == true
        return .init(code: full ? .diskFull : .network)
    }
}

/// Transport-owned sidecar, separate from the coordinator's job journal. Never stores resolved CDN URLs.
struct HFDownloadJournal: Codable, Equatable, Sendable {
    let file: HFPlannedFile
    let writtenBytes: Int64
    let validator: String?
    let credentialID: String?

    static func sidecarURL(for partialURL: URL) -> URL { partialURL.appendingPathExtension("hf-journal.json") }
    func write(for partialURL: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.sidecarURL(for: partialURL), options: .atomic)
    }
    static func read(for partialURL: URL) throws -> Self {
        let url = sidecarURL(for: partialURL)
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              (values[.size] as? NSNumber)?.int64Value ?? Int64.max <= 128 * 1024 else {
            throw HFDownloadError(code: .integrity)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    static func safeValidator(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 256, !value.isEmpty else { return nil }
        // Opaque ETags only: exclude URLs, queries, credentials and control characters.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./\"")
        guard value.unicodeScalars.allSatisfy(allowed.contains), value.hasSuffix("\""),
              value.hasPrefix("\"") || value.hasPrefix("W/\"") else { return nil }
        return value
    }
}

enum HFFileVerifier {
    typealias Verification = @Sendable (HFPlannedFile, URL) throws -> Void
    typealias ChunkReader = @Sendable (FileHandle, Int) throws -> Data?
    static let chunkBytes = 64 * 1024
    /// Same task and cancellation state, explicitly away from the caller's actor executor.
    /// Returning awaits all synchronous reads; no worker can outlive its ownership interval.
    @concurrent static func verifyAsync(file: HFPlannedFile, at url: URL,
                                       verification: Verification = { try HFFileVerifier.verify(file: $0, at: $1) }) async throws {
        try Task.checkCancellation()
        try verification(file, url)
        try Task.checkCancellation()
    }
    static func verify(file: HFPlannedFile, at url: URL,
                       readChunk: ChunkReader = { try $0.read(upToCount: $1) }) throws {
        do {
            try Task.checkCancellation()
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            try Task.checkCancellation()
            guard file.sizeBytes > 0, values[.type] as? FileAttributeType == .typeRegular,
                  (values[.size] as? NSNumber)?.int64Value == file.sizeBytes else { throw HFDownloadError(code: .integrity) }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var sha256 = SHA256(), sha1 = Insecure.SHA1()
            sha1.update(data: Data("blob \(file.sizeBytes)\0".utf8))
            var count: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try readChunk(handle, chunkBytes)
                try Task.checkCancellation()
                guard let chunk, !chunk.isEmpty else { break }
                if count == 0 {
                    let prefix = String(decoding: chunk.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !prefix.hasPrefix("<!doctype html"), !prefix.hasPrefix("<html"),
                          !prefix.hasPrefix("version https://git-lfs.github.com/spec/v1") else { throw HFDownloadError(code: .integrity) }
                }
                count += Int64(chunk.count)
                guard count <= file.sizeBytes else { throw HFDownloadError(code: .integrity) }
                switch file.digest { case .sha256: sha256.update(data: chunk); case .gitBlobSHA1: sha1.update(data: chunk) }
            }
            try Task.checkCancellation()
            guard count == file.sizeBytes else { throw HFDownloadError(code: .integrity) }
            let actual: String, expected: String
            switch file.digest {
            case .sha256(let digest): actual = sha256.finalize().map { String(format: "%02x", $0) }.joined(); expected = digest
            case .gitBlobSHA1(let digest): actual = sha1.finalize().map { String(format: "%02x", $0) }.joined(); expected = digest
            }
            guard actual == expected.lowercased() else { throw HFDownloadError(code: .integrity) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as HFDownloadError { throw error }
        catch { throw HFDownloadError.disk(error) }
    }
}
