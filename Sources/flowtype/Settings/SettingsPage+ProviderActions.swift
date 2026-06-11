import SwiftUI

extension SettingsPage {
    func refreshDevices() {
        availableDevices = AudioRecorder.availableInputDevices()
        if let selectedID = store.current.microphoneDeviceID {
            selectedDeviceUnavailable = !availableDevices.contains(where: { $0.id == selectedID })
        } else {
            selectedDeviceUnavailable = false
        }
    }

    func setActiveProvider(_ id: UUID) {
        for i in store.current.llmProviders.indices {
            store.current.llmProviders[i].isActive = (store.current.llmProviders[i].id == id)
        }
    }

    func startEditing(_ provider: LLMProvider) {
        // Populate drafts before presenting so the sheet's first frame shows current values
        draftProvider = provider
        draftApiKey = ConfigurationStore.shared.loadProviderAPIKey(provider.id) ?? ""
        editingHadStoredKey = !draftApiKey.isEmpty
        editingProvider = provider
    }

    func deleteProvider(_ id: UUID) {
        let wasActive = store.current.llmProviders.first(where: { $0.id == id })?.isActive ?? false
        store.current.llmProviders.removeAll(where: { $0.id == id })
        ConfigurationStore.shared.deleteProviderAPIKey(id)
        // Auto-activate another provider if the active one was deleted
        if wasActive, !store.current.llmProviders.isEmpty {
            store.current.llmProviders[0].isActive = true
        }
    }
}
