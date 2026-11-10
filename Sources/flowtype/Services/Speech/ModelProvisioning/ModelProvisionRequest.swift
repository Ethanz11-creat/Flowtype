import Foundation

enum NativeASRSelectionIntent: Sendable { case existingRole, primary, fallback, trialOnly, relocation }

/// Transient quality preview; never encoded into configuration or validation records.
struct ASRModelTrialResult: Equatable, Sendable {
    let backendID: ASRBackendID
    let text: String
    let latencyMs: Int
}

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
    /// Explicit model-center intent; committed with validation and the actual successful lease.
    let selectionIntent: NativeASRSelectionIntent

    init(target: ModelProvisionTarget, source: DownloadSource, origin: ModelProvisionOrigin,
         validationSample: ASRValidationSample? = nil, restoringValidatedRuntime: Bool = false, selectionIntent: NativeASRSelectionIntent = .existingRole) {
        self.target = target; self.source = source; self.origin = origin
        self.selectionIntent = selectionIntent
        self.validationSample = validationSample; self.restoringValidatedRuntime = restoringValidatedRuntime
    }
}
