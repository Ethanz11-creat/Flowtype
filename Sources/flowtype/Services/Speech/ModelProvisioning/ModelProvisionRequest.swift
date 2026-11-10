import Foundation

enum ModelProvisionOrigin: Sendable { case automatic, manual, offlineImport }
enum ModelProvisionTarget: Sendable, Equatable {
    case preset(ModelPreset)
    case offline(ResolvedModel)
    case imported(ImportedASRModel)
    /// Legacy/folder intent reserves the same lifecycle before its first inspection.
    case uninspectedDirectory(URL)
}
struct ModelProvisionRequest: Sendable {
    let target: ModelProvisionTarget
    let source: DownloadSource
    let origin: ModelProvisionOrigin
    let validationSample: ASRValidationSample?
    let restoringValidatedRuntime: Bool

    init(target: ModelProvisionTarget, source: DownloadSource, origin: ModelProvisionOrigin,
         validationSample: ASRValidationSample? = nil, restoringValidatedRuntime: Bool = false) {
        self.target = target; self.source = source; self.origin = origin
        self.validationSample = validationSample; self.restoringValidatedRuntime = restoringValidatedRuntime
    }
}
