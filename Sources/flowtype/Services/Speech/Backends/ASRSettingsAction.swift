import Foundation

/// Explicit compatibility controls update selection and legacy presentation together.
/// Generic settings saves never infer a new selection from legacy fields.
enum ASRSettingsAction {
    case selectPrimary(ASRBackendID)
    case selectFallback(ASRBackendID?)
    case allowCloudFallback(Bool)
    case deselect(ASRBackendID)
    case activateCloud(UUID)
    case deleteCloud(UUID, confirmSelected: Bool)
    case changePolicy(ASRRoutingPolicy)

    enum Conflict: LocalizedError {
        case missingProfile, localOnly, cloudOnly, duplicateRoles, cloudConsent, validationRequired, multipleNativeModels, occupiedRoles, noIntendedBackend, confirmDeletion
        var errorDescription: String? {
            switch self {
            case .multipleNativeModels: "同一时间只能使用一个原生模型，请先明确解除另一个原生模型的选择。"
            case .validationRequired: "请先主动试识别并确认成功，再设置为备选。"
            case .cloudOnly: "当前为仅云端模式，请先调整策略再选择本地后端。"
            case .duplicateRoles: "主选和备选不能是同一后端，请先解除原选择。"
            case .cloudConsent: "将本地识别配上云端备选前，请明确允许向云端发送识别音频。"
            case .missingProfile: "此服务已不存在，请重新选择。"
            case .localOnly: "当前为仅本地模式，请先切换到自动或仅云端，再选用云端服务。"
            case .occupiedRoles: "当前主选和备选均为本地后端，请先明确调整选择，再选用云端服务。"
            case .noIntendedBackend: "此模式没有明确选中的后端；配置和选择已保留，请先选择对应的服务或本地模型。"
            case .confirmDeletion: "此服务仍被主选或备选引用；删除后该选择将不可用，请确认删除。"
            }
        }
    }

    static func referencesCloud(_ id: UUID, in config: Configuration) -> Bool {
        let selection = ASRBackendMigration.selection(from: config)
        let backendID = ASRBackendID(rawValue: "cloud:" + id.uuidString)
        return selection.primary == backendID || selection.fallback == backendID
    }

    static func isCloudPrimary(_ id: UUID, in config: Configuration) -> Bool {
        ASRBackendMigration.selection(from: config).primary == .init(rawValue: "cloud:" + id.uuidString)
    }

    static func validateChoice(_ id: ASRBackendID, in config: Configuration) throws {
        let cloud = id.rawValue.hasPrefix("cloud:")
        guard config.asrRoutingPolicy != .localOnly || !cloud else { throw Conflict.localOnly }
        guard config.asrRoutingPolicy != .cloudOnly || cloud else { throw Conflict.cloudOnly }
    }

    private static func validateRoles(_ selection: ASRBackendSelection) throws {
        if let primary = selection.primary, let fallback = selection.fallback,
           primary.rawValue.hasPrefix("native:"), fallback.rawValue.hasPrefix("native:"), primary != fallback {
            throw Conflict.multipleNativeModels
        }
        if let fallback = selection.fallback, fallback.rawValue.hasPrefix("cloud:"),
           selection.primary?.rawValue.hasPrefix("cloud:") != true, !selection.allowsCloudFallback {
            throw Conflict.cloudConsent
        }
    }

    func apply(to config: inout Configuration, activeNativeID: ASRBackendID? = nil) throws {
        var updated = config
        let previousSelection = ASRBackendMigration.selection(from: config)
        var selection = previousSelection
        func isCloud(_ id: ASRBackendID) -> Bool { id.rawValue.hasPrefix("cloud:") }
        func isLocal(_ id: ASRBackendID) -> Bool {
            id.rawValue.hasPrefix("native:") || id.rawValue.hasPrefix("service:")
        }
        let roles = [selection.primary, selection.fallback].compactMap { $0 }
        switch self {
        case .selectPrimary(let id):
            try Self.validateChoice(id, in: config)
            guard selection.fallback != id else { throw Conflict.duplicateRoles }
            selection.primary = id
            try Self.validateRoles(selection)
            for index in updated.cloudASRConfig.providers.indices {
                updated.cloudASRConfig.providers[index].isActive = "cloud:" + updated.cloudASRConfig.providers[index].id.uuidString == id.rawValue
            }
        case .selectFallback(let id):
            if let id {
                try Self.validateChoice(id, in: config)
                guard selection.primary != id else { throw Conflict.duplicateRoles }
            }
            selection.fallback = id
            try Self.validateRoles(selection)
        case .allowCloudFallback(let allowed):
            selection.allowsCloudFallback = allowed
        case .deselect(let id):
            let exactImported = id.rawValue.hasPrefix("native:import:")
                ? UUID(uuidString: String(id.rawValue.dropFirst("native:import:".count))) : nil
            func matches(_ candidate: ASRBackendID?) -> Bool {
                if candidate == id { return true }
                guard let exactImported, let candidate, candidate.rawValue.hasPrefix("native:import:") else { return false }
                return UUID(uuidString: String(candidate.rawValue.dropFirst("native:import:".count))) == exactImported
            }
            let wasPrimary = matches(selection.primary)
            let wasReferenced = wasPrimary || matches(selection.fallback)
            if wasPrimary { selection.primary = nil }
            if matches(selection.fallback) { selection.fallback = nil }
            let exactPreset = updated.selectedLocalModelID.map { id.rawValue == "native:preset:" + $0 } ?? false
            let retainedNative = [selection.primary, selection.fallback].compactMap { $0 }.contains { $0.rawValue.hasPrefix("native:") }
            if id.rawValue.hasPrefix("native:"), !retainedNative,
               wasReferenced || (exactImported != nil && updated.activeImportedASRModelID == exactImported) || exactPreset {
                // Explicitly retiring the final native intent allows B6's guarded removal;
                // the runtime, library, installed records and user files remain owned by B.
                updated.activeImportedASRModelID = nil; updated.selectedLocalModelID = nil
                updated.customLocalModelPath = nil; updated.localModelPath = nil
            }
            if wasPrimary && isCloud(id) {
                for index in updated.cloudASRConfig.providers.indices {
                    updated.cloudASRConfig.providers[index].isActive = false
                }
            }
        case .activateCloud(let id):
            guard updated.cloudASRConfig.providers.contains(where: { $0.id == id }) else { throw Conflict.missingProfile }
            guard updated.asrRoutingPolicy != .localOnly else { throw Conflict.localOnly }
            let locals = roles.filter(isLocal)
            guard Set(locals).count <= 1 else { throw Conflict.occupiedRoles }
            let backendID = ASRBackendID(rawValue: "cloud:" + id.uuidString)
            let retained = locals.first ?? selection.fallback.flatMap { $0 == backendID ? nil : $0 }
            selection.primary = backendID
            selection.fallback = retained
            for index in updated.cloudASRConfig.providers.indices {
                updated.cloudASRConfig.providers[index].isActive = updated.cloudASRConfig.providers[index].id == id
            }
        case .deleteCloud(let id, let confirmed):
            guard updated.cloudASRConfig.providers.contains(where: { $0.id == id }) else { throw Conflict.missingProfile }
            if Self.referencesCloud(id, in: config), !confirmed { throw Conflict.confirmDeletion }
            updated.cloudASRConfig.providers.removeAll { $0.id == id }
            updated.cloudASRConfig.providerAPIKeys.removeValue(forKey: id.uuidString)
            // Retain unavailable selected identity; never choose a remaining row or delete captured credentials.
        case .changePolicy(let policy):
            guard policy != updated.asrRoutingPolicy else { return }
            let configuredNative: ASRBackendID? = updated.activeImportedASRModelID.map { .init(rawValue: "native:import:" + $0.uuidString) }
                ?? updated.selectedLocalModelID.map { .init(rawValue: "native:preset:" + $0) }
                ?? activeNativeID
            let explicitlyActiveCloud = updated.cloudASRConfig.providers.filter(\.isActive)
            let configuredCloud: ASRBackendID? = explicitlyActiveCloud.count == 1
                ? .init(rawValue: "cloud:" + explicitlyActiveCloud[0].id.uuidString) : nil
            let chosen: ASRBackendID?
            switch policy {
            case .localOnly: chosen = roles.first(where: isLocal) ?? configuredNative
            case .cloudOnly: chosen = roles.first(where: isCloud) ?? configuredCloud
            case .auto: chosen = selection.primary ?? configuredCloud ?? configuredNative
            }
            guard let chosen else { throw Conflict.noIntendedBackend }
            if !roles.contains(chosen), Set(roles).count == 2 { throw Conflict.occupiedRoles }
            if chosen != selection.primary {
                selection.fallback = roles.first { $0 != chosen }
                selection.primary = chosen
            }
            // Auto may restore the explicitly configured native role; never invent cloud fallback consent.
            if policy == .auto, selection.fallback == nil, isCloud(chosen) {
                selection.fallback = configuredNative
            }
            updated.asrRoutingPolicy = policy
            if isCloud(chosen) {
                for index in updated.cloudASRConfig.providers.indices {
                    updated.cloudASRConfig.providers[index].isActive = "cloud:" + updated.cloudASRConfig.providers[index].id.uuidString == chosen.rawValue
                }
            }
        }
        let unresolvedNativeRoleIsRetained = config.pendingLegacyNativeResolution
            && config.asrRoutingPolicy == updated.asrRoutingPolicy
            && ((config.asrRoutingPolicy == .auto && previousSelection.fallback == nil && selection.fallback == nil)
                || (config.asrRoutingPolicy == .localOnly && previousSelection.primary == nil && selection.primary == nil))
        switch self {
        case .deleteCloud where unresolvedNativeRoleIsRetained,
             .activateCloud where unresolvedNativeRoleIsRetained:
            // These actions leave the unresolved native role intact. Preserve its
            // migration marker instead of treating the cloud edit as an explicit clear.
            updated.asrBackendSelection = selection
        default:
            updated.setASRBackendSelection(selection)
        }
        config = updated
    }
}
