import Foundation

enum HFFileDigest: Codable, Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String)
}

struct HFPlannedFile: Codable, Equatable, Sendable {
    let source: HFRepositorySelection
    let downloadEndpoint: URL
    let resolvedCommit: String
    let remotePath: String
    let relativeDestination: String
    let sizeBytes: Int64
    let digest: HFFileDigest
}

struct HFRepositoryFile: Codable, Equatable, Sendable {
    let remotePath: String
    let sizeBytes: Int64
    let digest: HFFileDigest
}

struct HFResolvedRepository: Sendable {
    let selection: HFRepositorySelection
    let commit: String
    let downloadEndpoint: URL
    let files: [HFRepositoryFile]
    let licenseURL: URL?
    // Ephemeral preview identity; never persisted into install plans.
    let resolutionContextID: UUID?

    init(selection: HFRepositorySelection, commit: String, downloadEndpoint: URL, files: [HFRepositoryFile],
         licenseURL: URL?, resolutionContextID: UUID? = nil) {
        self.selection = selection; self.commit = commit; self.downloadEndpoint = downloadEndpoint
        self.files = files; self.licenseURL = licenseURL; self.resolutionContextID = resolutionContextID
    }
}

enum HFRepositoryError: Error, Equatable {
    case invalidEndpoint, invalidCredential, unauthorized, forbidden, notFound
    case httpStatus(Int)
    case invalidMetadata, invalidCommit, invalidPath, missingFileMetadata
    case paginationLoop, invalidPagination, pageLimit, fileLimit, byteLimit, totalSizeOverflow
    case conflictingFile, fileNotInRepository, digestMismatch, network
}

struct HFMetadataLimits: Sendable {
    let responseBytes: Int
    let preflightBytes: Int
    init(responseBytes: Int = 16 * 1024 * 1024, preflightBytes: Int = 32 * 1024 * 1024) {
        self.responseBytes = max(1, min(responseBytes, 16 * 1024 * 1024))
        self.preflightBytes = max(1, min(preflightBytes, 32 * 1024 * 1024))
    }
}
