import Combine

@MainActor
final class SettingsChangeCoordinator {
    private let store: ConfigurationStore
    private let reloadHotkey: @MainActor () -> Void
    private var subscription: AnyCancellable?
    private var changeScheduled = false
    private var lastHandled: Configuration

    init(store: ConfigurationStore, reloadHotkey: @escaping @MainActor () -> Void) {
        self.store = store
        self.reloadHotkey = reloadHotkey
        lastHandled = store.current
    }

    func startObserving() {
        guard subscription == nil else { return }
        lastHandled = store.current
        subscription = store.$current.dropFirst().sink { [weak self] _ in
            self?.scheduleChange()
        }
    }

    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        // @Published emits in willSet. Never save its argument synchronously:
        // save() assigns current again, and an earlier queued value can overwrite
        // later field edits. Read the latest committed snapshot on the next turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            self.handleChange(from: self.lastHandled, to: self.store.current)
        }
    }

    func handleChange(from old: Configuration, to new: Configuration) {
        guard old != new, lastHandled != new else { return }
        // Advance before save publishes again, so its duplicate is a no-op.
        lastHandled = new
        store.save(new)
        if old.triggerKey != new.triggerKey || old.interactionMode != new.interactionMode {
            reloadHotkey()
        }
    }
}
