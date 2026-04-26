import Foundation

struct Configuration {
    static let shared = Configuration()

    private let env: [String: String]

    let baseURL = "https://api.siliconflow.cn/v1"

    init() {
        // Load .env file and merge with environment variables
        let dotEnv = DotEnv.load(path: ".env")
        let processEnv = ProcessInfo.processInfo.environment
        self.env = dotEnv.merging(processEnv) { _, new in new }
    }

    var apiKey: String {
        env["SILICONFLOW_API_KEY"] ?? ""
    }

    // ASR Models
    var asrPrimaryModel: String {
        env["ASR_PRIMARY_MODEL"] ?? "TeleAI/TeleSpeechASR"
    }

    var asrFallbackModel: String {
        env["ASR_FALLBACK_MODEL"] ?? "FunAudioLLM/SenseVoiceSmall"
    }

    // ASR Strategy: "parallel" (default) or "fallback"
    var asrStrategy: String {
        env["ASR_STRATEGY"] ?? "parallel"
    }

    // Debug: dump audio to ~/Library/Logs/langstream/
    var dumpAudio: Bool {
        env["LANGSTREAM_DUMP_AUDIO"] == "1"
    }

    // Post-processing switches
    var enableFillerStrip: Bool {
        env["ENABLE_FILLER_STRIP"] != "0"
    }

    var enableTermCorrection: Bool {
        env["ENABLE_TERM_CORRECTION"] != "0"
    }

    // LLM
    var llmModel: String {
        env["LLM_MODEL"] ?? "deepseek-ai/DeepSeek-V3"
    }

    let temperature = 0.3
    let maxTokens = 2048

    let systemPrompt = """
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
}
