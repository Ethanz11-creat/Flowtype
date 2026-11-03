import Foundation

/// Presentation values only. The controller retains all lifecycle authority.
struct SessionRecoveryState {
    var card: RecoveryCard?
    var copyText: String?
    var destination: ClientDestination = .settings(.speech)
}
