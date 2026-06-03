import AppKit

/// Applies the user's appearance preference to the whole app. `.system` clears the override
/// so FlowType follows macOS; `.light`/`.dark` force that appearance (the frosted material,
/// accent, and bevels all adapt automatically).
enum AppearanceController {
    @MainActor
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
