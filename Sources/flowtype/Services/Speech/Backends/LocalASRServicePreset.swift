import Foundation

/// Creation-only wire defaults. The user supplies an already-running service URL.
/// Editing a saved profile never reapplies these defaults or changes its model.
enum LocalASRServicePreset: Sendable {
    case customOpenAICompatible, mlxAudio, whisperKit, whisperCpp

    func makeProfile(baseURL: String, modelID: String?) -> LocalASRServiceProfile {
        let name: String
        let fields: CloudASRFieldCapabilities
        switch self {
        case .customOpenAICompatible:
            name = "自定义 OpenAI 兼容服务"; fields = .init()
        case .mlxAudio:
            name = "MLX Audio"; fields = .init(sendLanguage: true, sendPrompt: true, sendResponseFormat: true)
        case .whisperKit:
            name = "WhisperKit"; fields = .init(sendLanguage: true, sendPrompt: true, sendResponseFormat: true)
        case .whisperCpp:
            name = "whisper.cpp"; fields = .init(sendLanguage: true, sendPrompt: true, sendResponseFormat: true)
        }
        return .init(id: UUID(), revision: UUID(), name: name, baseURL: baseURL,
            protocolKind: self == .whisperCpp ? .whisperCpp : .openAICompatible,
            modelID: self == .whisperCpp ? nil : modelID, authentication: .none, fieldCapabilities: fields)
    }
}
