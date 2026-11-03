import SwiftUI

enum SettingsSection: String, CaseIterable, Sendable {
    case speech, text, general, privacy
}

enum SettingsTarget: Hashable, Sendable {
    case localModels
    case provider(UUID)
    case microphone
    case accessibility
    case appleSpeech
}

enum ClientDestination: Equatable, Sendable {
    case tab(AppTab)
    case settings(SettingsSection, SettingsTarget? = nil)
    case history(String? = nil)
    case style(String? = nil)

    var tab: AppTab {
        switch self {
        case .tab(let tab): tab
        case .settings: .settings
        case .history: .history
        case .style: .style
        }
    }
}

struct NavigationRequest: Equatable, Sendable {
    let id: UUID
    let destination: ClientDestination
}

private struct ClientNavigationRequestKey: EnvironmentKey {
    static let defaultValue: NavigationRequest? = nil
}

extension EnvironmentValues {
    /// Pages receive the original request, so section selection and scrolling share its identity.
    /// Settings, history and style consume their associated targets in their own page work.
    var clientNavigationRequest: NavigationRequest? {
        get { self[ClientNavigationRequestKey.self] }
        set { self[ClientNavigationRequestKey.self] = newValue }
    }
}
