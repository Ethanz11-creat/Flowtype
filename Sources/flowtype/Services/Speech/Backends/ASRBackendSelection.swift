import Foundation

struct ASRBackendSelection: Codable, Equatable, Sendable {
    var primary: ASRBackendID? = nil
    var fallback: ASRBackendID? = nil
    var allowsCloudFallback: Bool = false
}
