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
    static func makeProfile(_ vendor: CloudASRVendorID, isActive: Bool) -> CloudASRProviderConfig {
        switch vendor {
        case .siliconFlow:
            return .defaultSiliconFlow(isActive: isActive)
        case .openAI:
            return CloudASRProviderConfig(name: "OpenAI", provider: "OpenAI", baseURL: "https://api.openai.com/v1",
                                          model: "whisper-1", isActive: isActive, vendorID: .openAI)
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
            // Official optional-field verification remains pending (source access was HTTP 403).
            // The first version retains only the existing whisper-1 JSON contract.
            return CloudASRFieldCapabilities(sendResponseFormat: profile.model == "whisper-1")
        case .custom:
            return profile.customFieldCapabilities
        }
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
