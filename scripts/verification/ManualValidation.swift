import Foundation

/// C1 deliberately does not attest manual or remote CI evidence. C3 supplies strict validation.
enum ManualValidation {
    static func evaluate(manualReport: URL?, ciReport: URL?, artifact: ArtifactManifest?) -> (VerificationStatus, VerificationStatus) {
        (.pending, .pending)
    }
}
