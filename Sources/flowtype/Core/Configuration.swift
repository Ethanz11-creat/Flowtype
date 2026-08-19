import Foundation
import CoreGraphics

enum TriggerKey: String, Codable, CaseIterable {
    case fn, control, option, command, f13, f14, f15, capsLock, rightCommand

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .capsLock: return "Caps Lock"
        case .rightCommand: return "Right Command"
        }
    }

    var isModifier: Bool {
        switch self {
        case .fn, .control, .option, .command, .rightCommand:
            return true
        case .f13, .f14, .f15, .capsLock:
            return false
        }
    }

    var cgEventFlag: CGEventFlags? {
        switch self {
        case .fn: return .maskSecondaryFn
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .rightCommand: return .maskCommand
        case .f13, .f14, .f15, .capsLock:
            return nil
        }
    }

    var keyCode: CGKeyCode? {
        switch self {
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .capsLock: return 57
        case .rightCommand: return 54
        case .fn, .control, .option, .command:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .fn: return "Fn"
        case .rightCommand: return "Right ⌘"
        default: return displayName
        }
    }
}

enum InteractionMode: String, Codable, CaseIterable {
    case tapToStart
    case toggle

    var displayName: String {
        switch self {
        case .tapToStart: return "Tap to Start"
        case .toggle: return "Toggle"
        }
    }
}

enum WhisperLanguage: String, Codable, CaseIterable {
    case auto, zh, en

    var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    /// Qwen3-ASR language hint. nil = auto-detect.
    var qwenLanguageCode: String? {
        self == .auto ? nil : rawValue
    }

    /// Apple Speech recognizer locale (live preview / fallback). `.auto` falls back to zh-CN.
    var appleLocaleIdentifier: String {
        self == .en ? "en-US" : "zh-CN"
    }
}

enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
}

enum ASREngineType: String, Codable, CaseIterable, Identifiable {
    case local = "local"
    case cloud = "cloud"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local: return "本地识别（离线）"
        case .cloud: return "云端识别（联网）"
        }
    }
}

enum HardwareTier: String, Codable {
    case low   // <12GB
    case mid   // 12GB-24GB
    case high  // ≥24GB
}

// MARK: - Provider Presets

struct ProviderPreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let baseURL: String
    let isCustom: Bool

    static let siliconFlow = ProviderPreset(name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", isCustom: false)
    static let openAI = ProviderPreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", isCustom: false)
    static let azure = ProviderPreset(name: "Azure OpenAI", baseURL: "https://your-resource.openai.azure.com/openai/deployments/", isCustom: false)
    static let custom = ProviderPreset(name: "自定义", baseURL: "", isCustom: true)

    static let all: [ProviderPreset] = [.siliconFlow, .openAI, .azure, .custom]
}

// MARK: - LLM Model Presets

struct LLMModelPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let modelId: String

    static let deepseekV3 = LLMModelPreset(
        id: "deepseek-v3",
        name: "DeepSeek-V3 (通用，推荐)",
        modelId: "deepseek-ai/DeepSeek-V3"
    )
    static let qwen2572b = LLMModelPreset(
        id: "qwen25-72b",
        name: "Qwen2.5-72B-Instruct",
        modelId: "Qwen/Qwen2.5-72B-Instruct"
    )
    static let glm4 = LLMModelPreset(
        id: "glm-4",
        name: "GLM-4",
        modelId: "THUDM/glm-4"
    )

    static let siliconFlowModels: [LLMModelPreset] = [.deepseekV3, .qwen2572b, .glm4]
}

// MARK: - LLM Provider

struct LLMProvider: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var provider: String       // preset name: "SiliconFlow", "OpenAI", "Azure", "Custom"
    var baseURL: String
    var model: String
    var isActive: Bool

    init(id: UUID = UUID(), name: String, provider: String, baseURL: String, model: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.isActive = isActive
    }

    static func defaultSiliconFlow(id: UUID = UUID(), isActive: Bool = true) -> LLMProvider {
        LLMProvider(
            id: id,
            name: "默认配置",
            provider: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            model: LLMModelPreset.deepseekV3.modelId,
            isActive: isActive
        )
    }
}

// MARK: - Cloud ASR Model Presets

struct CloudASRModelPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let modelId: String

    static let senseVoiceSmall = CloudASRModelPreset(
        id: "sensevoice-small",
        name: "SenseVoiceSmall (多语言，推荐)",
        modelId: "FunAudioLLM/SenseVoiceSmall"
    )
    static let teleSpeechASR = CloudASRModelPreset(
        id: "telespeech-asr",
        name: "TeleSpeechASR (中文)",
        modelId: "TeleAI/TeleSpeechASR"
    )

    static let siliconFlowModels: [CloudASRModelPreset] = [.senseVoiceSmall, .teleSpeechASR]
}

// MARK: - Cloud ASR Provider

struct CloudASRProviderConfig: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var provider: String
    var baseURL: String
    var model: String
    var isActive: Bool

    init(id: UUID = UUID(), name: String, provider: String, baseURL: String, model: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.isActive = isActive
    }

    static func defaultSiliconFlow(id: UUID = UUID(), isActive: Bool = true) -> CloudASRProviderConfig {
        CloudASRProviderConfig(
            id: id,
            name: "硅基流动",
            provider: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            model: "",
            isActive: isActive
        )
    }
}

struct CloudASRConfig: Codable, Equatable {
    var providers: [CloudASRProviderConfig] = []
    var providerAPIKeys: [String: String] = [:]

    static let defaultSiliconFlow = CloudASRConfig(
        providers: [.defaultSiliconFlow()],
        providerAPIKeys: [:]
    )

    var activeProvider: CloudASRProviderConfig? {
        providers.first(where: \.isActive) ?? providers.first
    }
}

// MARK: - Service Config

struct ServiceConfig: Codable, Equatable {
    var provider: String
    var baseURL: String
    var apiKey: String
    var model: String

    static let `default` = ServiceConfig(
        provider: "SiliconFlow",
        baseURL: "https://api.siliconflow.cn/v1",
        apiKey: "",
        model: ""
    )
}

// MARK: - Configuration

struct Configuration: Codable, Equatable {
    // ASR
    var asrLanguage: WhisperLanguage = .zh

    // LLM
    var llmProviders: [LLMProvider] = []

    /// Per-provider API keys, stored LOCALLY (providerID.uuidString → key). Kept here rather than in
    /// the Keychain on purpose: this is an unsigned, local-only tool, and the data-protection keychain
    /// needs an entitlement we don't have (SecItemAdd returns -34018). Trade-off: keys live in the
    /// local config (UserDefaults) in plaintext — acceptable for a personal on-device tool whose
    /// threat model is other local processes, not the network.
    var providerAPIKeys: [String: String] = [:]

    // Backward-compatible computed properties (active provider).
    // Setters fall back to the first provider when none is active — matching the
    // read-side fallback in LLMService — instead of silently dropping the write.
    private var activeOrFirstProviderIndex: Int? {
        llmProviders.firstIndex(where: \.isActive) ?? llmProviders.indices.first
    }
    var llmProvider: String {
        get { llmProviders.first(where: \.isActive)?.provider ?? "" }
        set {
            guard let idx = activeOrFirstProviderIndex else { return }
            llmProviders[idx].provider = newValue
        }
    }
    var llmBaseURL: String {
        get { llmProviders.first(where: \.isActive)?.baseURL ?? "" }
        set {
            guard let idx = activeOrFirstProviderIndex else { return }
            llmProviders[idx].baseURL = newValue
        }
    }
    var llmModel: String {
        get { llmProviders.first(where: \.isActive)?.model ?? "" }
        set {
            guard let idx = activeOrFirstProviderIndex else { return }
            llmProviders[idx].model = newValue
        }
    }
    var llmApiKey: String {
        get {
            guard let id = llmProviders.first(where: \.isActive)?.id else { return "" }
            return providerAPIKeys[id.uuidString] ?? ""
        }
        set {
            guard let idx = activeOrFirstProviderIndex else { return }
            let id = llmProviders[idx].id
            if newValue.isEmpty { providerAPIKeys.removeValue(forKey: id.uuidString) }
            else { providerAPIKeys[id.uuidString] = newValue }
        }
    }

    // Other settings
    var triggerKey: TriggerKey = .command
    var interactionMode: InteractionMode = .tapToStart
    var enableAudioFeedback: Bool = true
    var maxRecordingDuration: Int = 600 // seconds, default 10 minutes

    // Module 2a: Microphone device selection
    var microphoneDeviceID: String? = nil

    // Module 2b: Onboarding
    var hasCompletedOnboarding: Bool = false

    // Appearance: 浅色 / 深色 / 随系统
    var appearancePreference: AppearancePreference = .system

    // Privacy: whether to persist transcript text alongside session metadata
    var storeTranscriptText: Bool = true

    // Model provisioning
    var localModelPath: String? = nil          // user-specified model folder (offline load)
    var downloadSource: DownloadSource = .auto

    // ASR engine selection
    var asrEngine: ASREngineType = .local
    var cloudASRConfig: CloudASRConfig = .defaultSiliconFlow
    var selectedLocalModelID: String? = nil
    var customLocalModelPath: String? = nil

    // Constants
    let temperature: Double = 0.3
    let maxTokens: Int = 2048

    // Security: validated bounds
    static let minRecordingDuration = 10   // seconds
    static let maxRecordingDurationCap = 600 // seconds (10 minutes)
    var systemPrompt: String = """
    你是一位面向 AI 编码场景的语音指令整理助手。

    用户输入的是语音识别后的原始开发需求，通常存在口语化、重复、断句混乱、识别错误和表达跳跃等问题。你的任务是将其整理成一段清晰、准确、边界明确、适合直接发送给 AI 编码助手的指令文本。

    处理时请遵守以下原则：

    1. 修正语音识别错误、错别字和断句问题。
    2. 删除无意义口头词、重复词和无信息噪音。
    3. 保持用户原意，不得擅自增加功能、页面、技术实现或需求范围。
    4. 保留所有关键限制条件，包括：
    - 修改范围
    - 不要改动的部分
    - 优先级
    - 风格参考
    - 输出方式
    5. 将模糊、跳跃的口语整理为自然、清楚、连续的开发指令，但不要强行写成正式文档。
    6. 如用户表达中包含"先做简单版、局部改、不要重构、只改样式、别动后端"这类边界条件，必须明确保留。
    7. 不要解释你的处理过程，不要补充建议，不要反问，不要输出多个版本。
    8. 只输出最终整理后的文本，不要添加任何前缀、说明、引号或客套话。
    9. 如果输入只包含语气词、口头词、停顿词、无意义重复，或整体上没有可整理的有效内容，例如"嗯""啊""那个""嗯嗯""哦哦"，则不输出任何文字。
    10. 如果输入信息不足但仍包含少量可保留内容，则只做最小必要修正后输出，不要自行补全。
    """

    // MARK: - Backward Compatibility Accessors

    var apiKey: String { llmApiKey }
    var baseURL: String { llmBaseURL }

    // MARK: - Effective Values

    var effectiveLLMConfig: ServiceConfig {
        ServiceConfig(
            provider: llmProvider,
            baseURL: llmBaseURL,
            apiKey: llmApiKey,
            model: llmModel
        )
    }

    var effectiveCloudASRConfig: (provider: CloudASRProviderConfig, apiKey: String)? {
        guard let provider = cloudASRConfig.activeProvider else { return nil }
        let key = cloudASRConfig.providerAPIKeys[provider.id.uuidString] ?? ""
        return (provider, key)
    }

    // MARK: - Default

    init() {}

    static let `default` = Configuration()

    // MARK: - Backward-Compatible Decoding

    private enum LegacyKeys: String, CodingKey {
        case whisperLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let d = Configuration.default
        asrLanguage = (try? c.decode(WhisperLanguage.self, forKey: .asrLanguage))
            ?? (try? legacy?.decode(WhisperLanguage.self, forKey: .whisperLanguage))
            ?? d.asrLanguage
        triggerKey = (try? c.decode(TriggerKey.self, forKey: .triggerKey)) ?? d.triggerKey
        interactionMode = (try? c.decode(InteractionMode.self, forKey: .interactionMode)) ?? d.interactionMode
        enableAudioFeedback = (try? c.decode(Bool.self, forKey: .enableAudioFeedback)) ?? d.enableAudioFeedback
        let rawDuration = (try? c.decode(Int.self, forKey: .maxRecordingDuration)) ?? d.maxRecordingDuration
        maxRecordingDuration = min(max(rawDuration, Configuration.minRecordingDuration), Configuration.maxRecordingDurationCap)
        systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? d.systemPrompt
        microphoneDeviceID = (try? c.decode(String?.self, forKey: .microphoneDeviceID)) ?? d.microphoneDeviceID
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        appearancePreference = (try? c.decode(AppearancePreference.self, forKey: .appearancePreference)) ?? d.appearancePreference
        localModelPath = (try? c.decode(String?.self, forKey: .localModelPath)) ?? d.localModelPath
        downloadSource = (try? c.decode(DownloadSource.self, forKey: .downloadSource)) ?? d.downloadSource
        asrEngine = (try? c.decode(ASREngineType.self, forKey: .asrEngine)) ?? d.asrEngine
        cloudASRConfig = (try? c.decode(CloudASRConfig.self, forKey: .cloudASRConfig)) ?? d.cloudASRConfig
        selectedLocalModelID = (try? c.decode(String?.self, forKey: .selectedLocalModelID)) ?? d.selectedLocalModelID
        customLocalModelPath = (try? c.decode(String?.self, forKey: .customLocalModelPath)) ?? d.customLocalModelPath
        storeTranscriptText = (try? c.decodeIfPresent(Bool.self, forKey: .storeTranscriptText)) ?? true
        providerAPIKeys = (try? c.decodeIfPresent([String: String].self, forKey: .providerAPIKeys)) ?? [:]

        // Try new multi-provider format first
        if let providers = try? c.decode([LLMProvider].self, forKey: .llmProviders), !providers.isEmpty {
            llmProviders = providers
        } else {
            // Migrate from old single-provider format
            let oldProvider = (try? c.decode(String.self, forKey: .llmProvider)) ?? d.llmProvider
            let oldBaseURL = (try? c.decode(String.self, forKey: .llmBaseURL)) ?? d.llmBaseURL
            let oldModel = (try? c.decode(String.self, forKey: .llmModel)) ?? d.llmModel
            llmProviders = [LLMProvider(
                id: UUID(),
                name: "默认配置",
                provider: oldProvider,
                baseURL: oldBaseURL,
                model: oldModel,
                isActive: true
            )]
        }
    }
}

extension Configuration {
    private enum CodingKeys: String, CodingKey {
        case asrLanguage
        case llmProviders
        case triggerKey
        case interactionMode
        case enableAudioFeedback
        case maxRecordingDuration
        case systemPrompt
        case microphoneDeviceID
        case hasCompletedOnboarding
        case appearancePreference
        case localModelPath
        case downloadSource
        case asrEngine
        case cloudASRConfig
        case selectedLocalModelID
        case customLocalModelPath
        case storeTranscriptText
        case providerAPIKeys
        // Legacy keys (for migration only, not stored properties)
        case llmProvider
        case llmBaseURL
        case llmModel
        case llmApiKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asrLanguage, forKey: .asrLanguage)
        try container.encode(llmProviders, forKey: .llmProviders)
        try container.encode(triggerKey, forKey: .triggerKey)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encode(enableAudioFeedback, forKey: .enableAudioFeedback)
        try container.encode(maxRecordingDuration, forKey: .maxRecordingDuration)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(microphoneDeviceID, forKey: .microphoneDeviceID)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(appearancePreference, forKey: .appearancePreference)
        try container.encode(localModelPath, forKey: .localModelPath)
        try container.encode(downloadSource, forKey: .downloadSource)
        try container.encode(asrEngine, forKey: .asrEngine)
        try container.encode(cloudASRConfig, forKey: .cloudASRConfig)
        try container.encode(selectedLocalModelID, forKey: .selectedLocalModelID)
        try container.encode(customLocalModelPath, forKey: .customLocalModelPath)
        try container.encode(storeTranscriptText, forKey: .storeTranscriptText)
        try container.encode(providerAPIKeys, forKey: .providerAPIKeys)
    }
}

extension Configuration {
    static var shared: Configuration {
        ConfigurationStore.shared.current
    }
}
