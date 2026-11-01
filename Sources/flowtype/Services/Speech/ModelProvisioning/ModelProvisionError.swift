import Foundation

/// Safe endpoint information only: never retain request queries, credentials, headers, or bodies.
struct ModelEndpointSummary: Sendable, Equatable {
    let host: String
    let safePath: String
    let httpStatus: Int?

    init(host: String, safePath: String, httpStatus: Int?) {
        self.host = host
        self.safePath = safePath
        self.httpStatus = httpStatus
    }

    init(url: URL, httpStatus: Int? = nil) {
        host = url.host ?? ""
        safePath = url.path.isEmpty ? "/" : url.path
        self.httpStatus = httpStatus
    }
}

enum ModelProvisionError: Error, Sendable, Equatable {
    case metadataInvalid(summary: ModelEndpointSummary? = nil)
    case network(summary: ModelEndpointSummary? = nil)
    case stalled(summary: ModelEndpointSummary? = nil)
    case incompleteLocal(summary: ModelEndpointSummary? = nil)
    case loadFailed(summary: ModelEndpointSummary? = nil)
    case insufficientDisk(summary: ModelEndpointSummary? = nil)

    var summary: ModelEndpointSummary? {
        switch self {
        case .metadataInvalid(let value), .network(let value), .stalled(let value),
             .incompleteLocal(let value), .loadFailed(let value), .insufficientDisk(let value): value
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .stalled: true
        case .metadataInvalid, .incompleteLocal, .loadFailed, .insufficientDisk: false
        }
    }
}
