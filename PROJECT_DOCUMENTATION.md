# FlowType 项目文档

## 项目概述

FlowType 是一款面向 AI 编码场景的智能语音输入法 macOS 应用。用户通过语音输入开发需求，应用将口语化的语音转换为结构化的文本指令，可直接发送给 AI 编码助手（如 Codex、Cursor 等）。

### 核心交互方式

| 操作 | 行为 |
|------|------|
| 双击 Option | 开始录音 |
| 单击 Option（录音中） | 结束录音，输出原始口语化文本 |
| 双击 Option（录音中） | 结束录音，输出 LLM 润色后的结构化文本 |

---

## 项目结构

```
Sources/flowtype/
├── App/
│   └── FlowTypeApp.swift          # 应用入口，隐藏主窗口
├── Core/
│   ├── AppState.swift               # 录音状态机（idle/recording/processingASR/polishing/injecting）
│   ├── AsyncRefiner.swift           # 并行 ASR + 评分选择 + LLM 润色
│   ├── Configuration.swift          # 配置管理（API Key、模型选择、功能开关）
│   └── PipelineOrchestrator.swift   # 核心控制器：录音→ASR→润色→注入的完整流程
├── Services/
│   ├── AudioRecorder.swift          # AVAudioEngine 录音，分段 buffer 管理
│   ├── KeyboardInjector.swift       # 文本注入：粘贴模式（多行）/ 逐字模式（单行）
│   ├── LLMService.swift             # SiliconFlow SSE 流式 LLM 调用
│   └── Speech/
│       ├── ASRPostProcessor.swift   # ASR 后处理：去 filler、术语纠错、规范化
│       ├── ASRResultScorer.swift    # ASR 结果评分器（多维度打分选最优）
│       ├── AppleSpeechProvider.swift # Apple 本地语音识别（预留）
│       ├── SenseVoiceProvider.swift  # SenseVoice ASR Provider
│       ├── SiliconFlowSpeechProvider.swift # SiliconFlow API 通用 ASR 实现
│       ├── SpeechProvider.swift      # ASR Provider 协议
│       ├── SpeechRouter.swift        # Provider 路由
│       └── TeleSpeechProvider.swift  # TeleSpeech ASR Provider（主）
├── UI/
│   └── AudioVisualizer.swift        # 录音时的音频波形动画
├── Utilities/
│   ├── AudioFormatConverter.swift   # PCM→WAV 转换、静音修剪、音量归一化
│   └── DotEnv.swift                 # .env 文件解析
├── CapsuleView.swift                # 悬浮窗 UI（状态、图标、文字）
├── FloatingPanel.swift              # 无边框悬浮面板（可拖拽）
└── WindowManager.swift              # 全局 Option 键监听 + 窗口管理
```

---

## 核心数据流

```
用户按下 Option
    ↓
WindowManager (CGEventTap) 检测单击/双击
    ↓
PipelineOrchestrator.toggleRecording()
    ↓
开始录音: AudioRecorder.startRecording() → RecordingOutput
    ├── amplitude stream → UI 动画
    └── segment stream → 每满60s自动分段并行ASR
    ↓
用户再次按下 Option
    ↓
停止录音: AudioRecorder.stopRecording() → (segments, finalData)
    ↓
等待所有分段 ASR 完成 → 拼接完整文本
    ↓
[单击] 直接输出拼接后的原始文本
[双击] LLMService.polishText() → 结构化文本 → 输出
    ↓
KeyboardInjector.insertText() → 粘贴到当前输入框
```

---

## 遇到的问题及解决方案

### 问题 1：双击 Option 无反应 / 日志无任何输出

**现象**：用户快速双击 Option 结束录音，但应用没有任何反应，控制台日志为空。

**根因**：Swift 6.2 严格并发模式下，`CGEventTap` 的 C 回调（非隔离线程）通过 `DispatchQueue.main.async` 调用 `@MainActor` 隔离的 `recordOptionTap()` 方法。Swift 6 运行时会静默丢弃跨隔离域的调用，导致事件"消失"。

**解决**：
1. 提取独立的 `OptionTapDetector` 类（`nonisolated`），专门处理双击检测逻辑
2. C 回调中使用 `Task { @MainActor in }` 显式声明在 MainActor 上执行
3. Timer 改用 `Timer.scheduledTimer(timeInterval:target:selector:)` 替代 `@Sendable` 闭包

**关键代码**（`WindowManager.swift`）：
```swift
// C 回调中：显式调度到 MainActor
Task { @MainActor in
    OptionTapDetector.shared.recordTap()
}

// TapDetector 使用 target/selector Timer，无闭包隔离问题
final class OptionTapDetector: @unchecked Sendable { ... }
```

---

### 问题 2：LLM 润色后的结构化文本注入后格式丢失

**现象**：日志中 LLM 返回了带换行、列表缩进的格式化文本，但注入到输入框后变成了一行连续文本。

**根因**：`KeyboardInjector.insertText()` 逐字符模拟键盘输入。换行符 `\n` 被当作普通 Unicode 字符发送，但多数输入框（尤其是聊天应用）将物理 Return 键识别为"发送"指令，而非插入换行。

**解决**：
- 文本含换行时，改用 **剪贴板粘贴**（Command+V）
- 粘贴保留所有格式（换行、缩进、列表符号）
- 粘贴前保存用户剪贴板内容，粘贴后自动恢复

**关键代码**（`KeyboardInjector.swift`）：
```swift
static func insertText(_ text: String) async throws {
    // 含换行的文本走粘贴路径，避免 Return 键触发发送
    if text.contains("\n") || text.contains("\r") {
        try await pasteText(text)
    } else {
        try await typeText(text)
    }
}

private static func pasteText(_ text: String) async throws {
    // 1. 保存原剪贴板（所有类型）
    // 2. 写入新文本
    // 3. 模拟 Cmd+V
    // 4. 恢复原剪贴板
}
```

---

### 问题 3：超过 60s 录音被强行截断

**现象**：用户长时间录音（如 46s 的测试），60s 后新数据被丢弃，只保留前 60s。

**根因**：`AudioRecorder` 使用单一 `AVAudioPCMBuffer`，容量固定为 `16000 * 60 = 960,000` 帧（60s @ 16kHz）。当 buffer 满时，后续数据直接丢弃。

**解决**：实现 **分段并发识别**：
1. 每满 60s 自动将当前 buffer 转换为 WAV，通过 `AsyncStream<Data>` 推送
2. `PipelineOrchestrator` 后台消费 segment stream，每段立即启动并行 ASR
3. 录音结束后，等待所有分段 ASR 完成，按顺序拼接结果 + 最后一段 ASR
4. 单击：拼接后直接输出；双击：拼接后统一润色输出

**关键代码**（`AudioRecorder.swift`）：
```swift
struct RecordingOutput: @unchecked Sendable {
    let amplitude: AsyncStream<Float>      // VU  meter
    let segments: AsyncStream<Data>         // 每满60s推送的WAV数据
}

// installTap 回调中，buffer 满时：
if currentLength + newLength <= mainBuffer.frameCapacity {
    // 正常追加
} else {
    // Buffer 满：flush 为 segment，重置，继续录音
    if let wavData = AudioFormatConverter.normalizeAndConvertToWAV(mainBuffer) {
        self.segmentContinuation?.yield(wavData)
    }
    mainBuffer.frameLength = 0
    // 继续写入新数据...
}
```

**关键代码**（`PipelineOrchestrator.swift`）：
```swift
// 后台消费 segment stream，每段并行 ASR
Task { @MainActor [weak self] in
    for await segmentData in output.segments {
        let index = self.nextSegmentIndex
        self.nextSegmentIndex += 1
        let task = Task { @MainActor in
            if let result = await self.asyncRefiner.transcribeWithScoring(audioData: segmentData) {
                self.segmentResults[index] = result.text
            }
        }
        self.segmentTasks.append(task)
    }
}

// 录音结束后，等待所有段完成并拼接
for task in segmentTasks { await task.value }
let orderedTexts = (0..<nextSegmentIndex).compactMap { segmentResults[$0] }
let combinedText = orderedTexts.joined(separator: "\n")
```

---

### 问题 4：ASR 识别结果总有重复字

**现象**：TeleSpeech 和 SenseVoice 返回的文本中频繁出现重复字，如"然然后"、"那个那个"。

**根因**：
1. 口语中确实存在重复词（"然后然后"、"那个那个"）
2. ASR 模型本身在处理连续重复音节时可能产生重复输出

**解决**（`ASRPostProcessor.swift`）：
```swift
/// 修复连续重复字符（3+ 相同字符 → 1个）
func fixCommonASRErrors(_ text: String) -> String {
    // "然然后" → "然后"
    // 扫描连续相同字符，超过2个去重
}

/// 删除 filler 词
func stripFillers(_ text: String) -> String {
    // "嗯"、"啊"、"那个"、"然后" 等独立出现的 filler 词删除
}
```

---

### 问题 5：Swift 6 并发编译警告

**现象**：构建时出现大量 `main actor-isolated property can not be referenced from a Sendable closure` 警告。

**根因**：Swift 6 严格并发检查下，`@MainActor` 类的属性/方法不能在 `@Sendable` 闭包中直接访问。

**解决**：
1. `WindowManager`：提取 `OptionTapDetector` 到 `@MainActor` 之外
2. `PipelineOrchestrator`：Timer 改用 target/selector
3. `AudioRecorder`：`isRecording`/`isStopping` 使用 `OSAllocatedUnfairLock` 保护
4. `LLMService`：SSE 解析保留在 `actor` 内部

---

## 关键设计决策

### 1. 为什么使用 CGEventTap 而不是 NSEvent 全局监视器？

`NSEvent.addGlobalMonitorForEvents` 无法捕获 modifier key（Option、Command 等）的 `flagsChanged` 事件。`CGEventTap` 是唯一能全局监听 Option 键状态变化的机制。

### 2. 为什么使用剪贴板粘贴而不是逐字输入？

- **保留格式**：换行、缩进、列表符号完整保留
- **避免副作用**：物理 Return 键在聊天应用中会触发"发送"
- **速度**：粘贴比逐字输入快 100 倍以上
- **补偿机制**：粘贴前保存/恢复用户原剪贴板内容

### 3. 为什么分段是 60s 而不是更短？

- **ASR 质量**：较短的音频片段缺少上下文，ASR 准确率下降
- **API 开销**：每段都需要一次 HTTP 请求，过短的段会增加延迟和成本
- **平衡**：60s 是大多数口语表达的合理上限，同时避免单段过长

### 4. 为什么并行调用两个 ASR Provider？

TeleSpeech 和 SenseVoice 各有优劣：
- **TeleSpeech**：中文标准普通话识别准确率高
- **SenseVoice**：对口语化、中英混合场景更鲁棒

通过 `ASRResultScorer` 多维度打分（非空、长度、中文比例、filler 比例、术语命中率、重复惩罚、标点比例），自动选择最优结果。

---

## 配置文件（.env）

```bash
SILICONFLOW_API_KEY=your_api_key_here

# ASR 模型
ASR_PRIMARY_MODEL=TeleAI/TeleSpeechASR
ASR_FALLBACK_MODEL=FunAudioLLM/SenseVoiceSmall
ASR_STRATEGY=parallel

# LLM 模型
LLM_MODEL=deepseek-ai/DeepSeek-V3

# 调试
FLOWTYPE_DUMP_AUDIO=0

# 后处理开关
ENABLE_FILLER_STRIP=1
ENABLE_TERM_CORRECTION=1
```

---

## 状态机

```
.idle ──双击Option──► .recording ──单击Option──► .processingASR ──► .injecting ──► .idle
                     │                              │
                     │                              └── 双击Option ──► .polishing ──► .injecting ──► .idle
                     │
                     └── 双击Option（结束）──► .processingASR ──► .polishing ──► .injecting ──► .idle
```

---

## 扩展点

| 扩展 | 位置 | 说明 |
|------|------|------|
| 新 ASR Provider | 实现 `SpeechProvider` 协议 | 如 Whisper、阿里云、科大讯飞 |
| 新 LLM Provider | 修改 `LLMService.streamPolish` | 更换 API endpoint 和请求格式 |
| 术语词典 | `Resources/tech_terms.json` | 添加行业/项目专属术语 |
| Filler 词 | `Resources/filler_words.json` | 添加方言或个性化 filler |
| 后处理规则 | `ASRPostProcessor` | 添加自定义文本替换逻辑 |

---

## 已知限制

1. **macOS 独占**：依赖 `CGEventTap`、`AVAudioEngine`、`NSPanel`，无法移植到 Windows/Linux
2. **Accessibility 权限**：首次运行需在系统设置中授予辅助功能权限
3. **网络依赖**：ASR 和 LLM 均需云端 API，离线无法工作
4. **60s 分段边界**：超长录音在 60s 边界处可能有极短的音频丢失（约 10-20ms）
5. **剪贴板覆盖风险**：粘贴注入期间（约 100ms）用户剪贴板被临时替换
