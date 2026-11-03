import SwiftUI

extension SettingsPage {
    func setActiveProvider(_ id: UUID) {
        for i in store.current.llmProviders.indices {
            store.current.llmProviders[i].isActive = (store.current.llmProviders[i].id == id)
        }
    }

    func startAddingProvider() {
        let profile = LLMProvider.defaultSiliconFlow(isActive: false)
        providerDraft = LLMProviderDraft(target: .new(profile.id), profile: profile)
    }

    func startEditing(_ provider: LLMProvider) {
        providerDraft = LLMProviderDraft(target: .existing(provider.id), profile: provider)
    }

    func deleteProvider(_ id: UUID) {
        var latest = store.current
        let wasActive = latest.llmProviders.first(where: { $0.id == id })?.isActive ?? false
        latest.llmProviders.removeAll(where: { $0.id == id })
        latest.providerAPIKeys.removeValue(forKey: id.uuidString)
        // Auto-activate another provider if the active one was deleted
        if wasActive, !latest.llmProviders.isEmpty {
            latest.llmProviders[0].isActive = true
        }
        store.save(latest)
    }
}
