import Foundation

enum PermissionKind: Equatable, Sendable {
    case accessibility, microphone, speechRecognition
}

enum ASRConfigurationIssue: Equatable, Sendable {
    case credentials, endpointOrModel, unsupportedLanguage, requestRejected
}

enum RecordingFailure: Equatable, Sendable {
    case interrupted, invalidAudio, tooLarge
}

/// Safe domain categories; associated values never contain provider text or secrets.
enum FailureKind: Equatable, Sendable {
    case permission(PermissionKind)
    case readiness(ReadinessIssue)
    case configuration(ASRConfigurationIssue)
    case transientASR
    case recording(RecordingFailure)
    case processing
    case deliveryBlocked
    case deliveryUncertain
    case internalFailure
    case cancelled
}
