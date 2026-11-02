import AppKit
import Combine

/// Informational menu item whose session is injectable without application UI.
@MainActor
final class LastDeliveryMenuController {
    let item: NSMenuItem
    private var summaryCancellable: AnyCancellable?

    init(session: SessionController) {
        item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        refresh(for: session.lastDeliverySummary)
        // @Published emits before its stored property changes. Use the emitted
        // summary synchronously so a menu already tracking also stays current.
        summaryCancellable = session.$lastDeliverySummary.sink { [weak self] summary in
            self?.refresh(for: summary)
        }
    }

    func refresh(for summary: LastDeliverySummary?) {
        item.title = lastDeliveryMenuTitle(summary)
        item.isEnabled = false
    }
}
