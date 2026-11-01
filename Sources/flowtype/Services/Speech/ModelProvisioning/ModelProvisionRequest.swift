import Foundation

enum ModelProvisionOrigin: Sendable { case automatic, manual, offlineImport }
enum ModelProvisionTarget: Sendable, Equatable {
    case preset(ModelPreset)
    case offline(ResolvedModel)
}
struct ModelProvisionRequest: Sendable {
    let target: ModelProvisionTarget
    let source: DownloadSource
    let origin: ModelProvisionOrigin
}
