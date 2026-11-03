import Foundation

enum ProviderDraftCommitError: LocalizedError, Equatable {
    case deleted
    case conflict
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .deleted: return "此服务已被删除，请关闭编辑器。"
        case .conflict: return "此服务已存在，请重新打开编辑器。"
        case .invalid(let message): return message
        }
    }
}

enum ProviderDraftCommit {
    static func normalizedLLMProfile(_ value: LLMProvider) -> LLMProvider {
        var profile = value
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.baseURL = normalizeBaseURL(profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        return profile
    }
    static func apply(_ draft: ASRProviderDraft, to config: inout Configuration) throws {
        var latest = config
        let index = try targetIndex(draft.target, ids: latest.cloudASRConfig.providers.map(\.id))
        guard draft.profile.id == draft.target.id else { throw ProviderDraftCommitError.invalid("服务标识不匹配") }
        var profile = draft.profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty else { throw ProviderDraftCommitError.invalid("服务名称不能为空") }
        guard !profile.model.isEmpty else { throw ProviderDraftCommitError.invalid("模型 ID 不能为空") }
        guard !latest.cloudASRConfig.providers.contains(where: { $0.id != profile.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == profile.name }) else {
            throw ProviderDraftCommitError.invalid("服务名称不能重复")
        }
        do {
            switch profile.protocolKind {
            case .openAICompatible: _ = try CloudASREndpoint.transcriptionURL(profile.baseURL)
            case .dashScopeRealtime: _ = try CloudASREndpoint.validateRealtimeURL(profile.baseURL)
            }
        } catch { throw ProviderDraftCommitError.invalid(error.localizedDescription) }
        if let index {
            // Activation is a separate action; a stale editor never changes the latest choice.
            profile.isActive = latest.cloudASRConfig.providers[index].isActive
            latest.cloudASRConfig.providers[index] = profile
        } else {
            profile.isActive = latest.cloudASRConfig.providers.isEmpty
            latest.cloudASRConfig.providers.append(profile)
        }
        apply(draft.keyEdit, id: profile.id, keys: &latest.cloudASRConfig.providerAPIKeys)
        config = latest
    }

    static func apply(_ draft: LLMProviderDraft, to config: inout Configuration) throws {
        var latest = config
        let index = try targetIndex(draft.target, ids: latest.llmProviders.map(\.id))
        guard draft.profile.id == draft.target.id else { throw ProviderDraftCommitError.invalid("服务标识不匹配") }
        var profile = normalizedLLMProfile(draft.profile)
        if let error = validateProvider(profile, existingProviders: latest.llmProviders) {
            throw ProviderDraftCommitError.invalid(error.localizedDescription)
        }
        if let index {
            profile.isActive = latest.llmProviders[index].isActive
            latest.llmProviders[index] = profile
        } else {
            profile.isActive = latest.llmProviders.isEmpty
            latest.llmProviders.append(profile)
        }
        apply(draft.keyEdit, id: profile.id, keys: &latest.providerAPIKeys)
        config = latest
    }

    private static func targetIndex(_ target: ProviderDraftTarget, ids: [UUID]) throws -> Int? {
        let index = ids.firstIndex(of: target.id)
        switch target {
        case .new:
            guard index == nil else { throw ProviderDraftCommitError.conflict }
            return nil
        case .existing:
            guard let index else { throw ProviderDraftCommitError.deleted }
            return index
        }
    }

    private static func apply(_ edit: APIKeyEdit, id: UUID, keys: inout [String: String]) {
        switch edit {
        case .preserve: break
        case .replace(let value):
            // Empty input means keep the latest key, including a concurrently replaced one.
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { keys[id.uuidString] = value }
        case .remove: keys.removeValue(forKey: id.uuidString)
        }
    }
}
