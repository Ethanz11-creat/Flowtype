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
    static let chunkBytes = 64 * 1024
    static func verify(file: HFPlannedFile, at url: URL) throws {
        do {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard file.sizeBytes > 0, values[.type] as? FileAttributeType == .typeRegular,
                  (values[.size] as? NSNumber)?.int64Value == file.sizeBytes else { throw HFDownloadError(code: .integrity) }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var sha256 = SHA256(), sha1 = Insecure.SHA1()
            sha1.update(data: Data("blob \(file.sizeBytes)\0".utf8))
            var count: Int64 = 0
            while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                if count == 0 {
                    let prefix = String(decoding: chunk.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !prefix.hasPrefix("<!doctype html"), !prefix.hasPrefix("<html"),
                          !prefix.hasPrefix("version https://git-lfs.github.com/spec/v1") else { throw HFDownloadError(code: .integrity) }
                }
                count += Int64(chunk.count)
                guard count <= file.sizeBytes else { throw HFDownloadError(code: .integrity) }
                switch file.digest { case .sha256: sha256.update(data: chunk); case .gitBlobSHA1: sha1.update(data: chunk) }
            }
            guard count == file.sizeBytes else { throw HFDownloadError(code: .integrity) }
            let actual: String, expected: String
            switch file.digest {
            case .sha256(let digest): actual = sha256.finalize().map { String(format: "%02x", $0) }.joined(); expected = digest
            case .gitBlobSHA1(let digest): actual = sha1.finalize().map { String(format: "%02x", $0) }.joined(); expected = digest
            }
            guard actual == expected.lowercased() else { throw HFDownloadError(code: .integrity) }
        } catch let error as HFDownloadError { throw error }
        catch { throw HFDownloadError.disk(error) }
    }
}
