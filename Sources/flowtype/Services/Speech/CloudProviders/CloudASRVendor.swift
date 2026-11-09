import Foundation

enum CloudASRVendorID: String, Codable, Sendable {
    case siliconFlow, openAI, dashScope, custom
}

struct CloudASRFieldCapabilities: Codable, Sendable, Equatable {
    var sendLanguage = false
    var sendPrompt = false
    var sendTemperature = false
    var sendResponseFormat = false
}

/// Creation defaults and explicit wire capabilities, independent of URL/display labels.
enum CloudASRVendor {
    /// Read-only choices; editing or rendering never reapplies creation defaults.
    static func modelPresets(for profile: CloudASRProviderConfig) -> [CloudASRModelPreset] {
        switch (profile.vendorID, profile.protocolKind) {
        case (.siliconFlow, .openAICompatible): return CloudASRModelPreset.siliconFlowModels
        case (.openAI, .openAICompatible):
            return [CloudASRModelPreset(id: "gpt-transcribe", name: "GPT Transcribe（推荐）", modelId: "gpt-transcribe"),
                    CloudASRModelPreset(id: "whisper-1", name: "Whisper-1（已弃用）", modelId: "whisper-1", isDeprecated: true)]
        case (.dashScope, .dashScopeRealtime): return [.paraformerRealtimeV2]
        default: return []
        }
    }

    static func makeProfile(_ vendor: CloudASRVendorID, isActive: Bool) -> CloudASRProviderConfig {
        switch vendor {
        case .siliconFlow:
            return .defaultSiliconFlow(isActive: isActive)
        case .openAI:
            return CloudASRProviderConfig(name: "OpenAI", provider: "OpenAI", baseURL: "https://api.openai.com/v1",
                                          model: "gpt-transcribe", isActive: isActive, vendorID: .openAI)
        case .dashScope:
            return .defaultParaformer(isActive: isActive)
        case .custom:
            return CloudASRProviderConfig(name: "自定义兼容服务", provider: "Custom", baseURL: "", model: "",
                                          isActive: isActive, vendorID: .custom)
        }
    }

    static func capabilities(for profile: CloudASRProviderConfig) -> CloudASRFieldCapabilities {
        guard profile.protocolKind == .openAICompatible else { return CloudASRFieldCapabilities() }
        switch profile.vendorID {
        case .siliconFlow, .dashScope:
            return CloudASRFieldCapabilities()
        case .openAI:
            // Verified official guide: docs/superpowers/research/2026-11-09-asr-model-center-sources.json (openai-speech-md).
            // gpt-transcribe accepts prompt; its languages field is not the legacy language hint.
            if profile.model == "gpt-transcribe" { return CloudASRFieldCapabilities(sendPrompt: true) }
            if profile.model == "whisper-1" {
                return CloudASRFieldCapabilities(sendResponseFormat: true)
            }
            return CloudASRFieldCapabilities()
        case .custom:
            return profile.customFieldCapabilities
        }
    }

    static func maxUploadBytes(for profile: CloudASRProviderConfig) -> Int64? {
        guard profile.vendorID == .openAI, profile.protocolKind == .openAICompatible,
              ["gpt-transcribe", "whisper-1"].contains(profile.model) else { return nil }
        return 25_000_000
    }

    /// Legacy identity comes only from exact saved provider values, never a domain substring.
    static func legacyVendorID(for provider: String) -> CloudASRVendorID {
        switch provider {
        case "SiliconFlow": return .siliconFlow
        case "OpenAI": return .openAI
        case "DashScope": return .dashScope
        default: return .custom
        }
    }
}
