import Foundation
import Combine

enum ProviderDraftTarget: Equatable {
    case new(UUID)
    case existing(UUID)

    var id: UUID {
        switch self { case .new(let id), .existing(let id): return id }
    }
}

enum APIKeyEdit: Equatable {
    case preserve
    case replace(String)
    case remove
}

struct ASRProviderDraft: Equatable {
    var target: ProviderDraftTarget
    var profile: CloudASRProviderConfig
    var keyEdit: APIKeyEdit = .preserve

    mutating func selectVendor(_ vendor: CloudASRVendorID) {
        profile.vendorID = vendor
        profile.provider = CloudASRVendor.makeProfile(vendor, isActive: false).provider
    }

    /// Endpoint, model, and protocol defaults require an explicit user action.
    mutating func useVendorDefaults() {
        let defaults = CloudASRVendor.makeProfile(profile.vendorID, isActive: false)
        profile.baseURL = defaults.baseURL
        profile.model = defaults.model
        profile.protocolKind = defaults.protocolKind
    }
}

struct LLMProviderDraft: Equatable, Identifiable {
    var target: ProviderDraftTarget
    var profile: LLMProvider
    var keyEdit: APIKeyEdit = .preserve
    var id: UUID { target.id }

    mutating func selectVendor(_ vendor: String) {
        profile.provider = vendor
    }

    mutating func useVendorDefaults() {
        guard let preset = ProviderPreset.all.first(where: { $0.name == profile.provider }) else { return }
        profile.baseURL = preset.baseURL
        // Only SiliconFlow has a configured model default in the existing catalog.
        profile.model = preset == .siliconFlow ? LLMModelPreset.deepseekV3.modelId : ""
    }
}

/// Owns the editor's close decision, including navigation initiated outside the sheet.
@MainActor
final class LLMProviderDraftSession: ObservableObject {
    @Published var draft: LLMProviderDraft
    @Published var isConfirmingDiscard = false
    private(set) var pendingNavigation: NavigationRequest?
    private let initialDraft: LLMProviderDraft

    var isModified: Bool { draft != initialDraft }

    private let guardOwner = UUID()
    private weak var navigation: SettingsNavigation?
    private var onClose: (() -> Void)?

    init(draft: LLMProviderDraft) { self.draft = draft; initialDraft = draft }

    func attach(to navigation: SettingsNavigation?, onClose: @escaping () -> Void) {
        detach()
        self.navigation = navigation
        self.onClose = onClose
        navigation?.installNavigationGuard(owner: guardOwner) { [weak self] request in
            guard let self else { return true }
            if self.draft != self.initialDraft {
                self.pendingNavigation = request
                self.isConfirmingDiscard = true
                return false
            }
            self.finishClose()
            return true
        }
    }

    func detach() {
        navigation?.removeNavigationGuard(owner: guardOwner)
        navigation = nil
        onClose = nil
        pendingNavigation = nil
        isConfirmingDiscard = false
    }

    func requestCancel() {
        if draft != initialDraft { isConfirmingDiscard = true }
        else { finishClose() }
    }

    func keepEditing() {
        pendingNavigation = nil
        isConfirmingDiscard = false
    }

    func discard() {
        let request = pendingNavigation
        let navigation = navigation
        finishClose()
        if let request { navigation?.navigate(request) }
    }

    private func finishClose() {
        let close = onClose
        detach()
        close?()
    }
}
