# FlowType 功能盘点 & 验证清单

> 活文档，方便对着打勾。最后更新：2026-06-03。
> 图例：⭐ = 针对语音输入痛点的差异化功能。

---

## 一、已实现功能 ✅

### 录音与触发
- [x] 全局热键（Fn/Ctrl/Option/Command/右Command/F13–15/CapsLock）；修饰键双击检测，普通键按住 0.2s 防误触
- [x] ⭐ 单击=原文 / 双击=LLM 润色；tap-to-start / toggle 两种交互模式
- [x] Esc 取消；EventTap 5s 自愈；录音时长上限+倒计时；30 分钟体积硬上限
- [x] ⭐ 设备掉线心跳检测（拔麦/蓝牙断→显式报错而非吐静音）
- [x] ⭐ 指定麦克风设备 + 录音时临时切换并还原 + 失效橙色警告

### ASR 与转写
- [x] ⭐ 本地 Qwen3-ASR 批量（离线）+ AppleSpeech 实时预览 + 双引擎兜底路由
- [x] 模型生命周期状态机（下载进度/加载/就绪/失败可重试）；转写可取消
- [x] ⭐ **识别语言** → Qwen `language` 提示 + AppleSpeech locale（本轮接上）
- [x] ⭐ **词典 → Qwen `context`**：启用词条作为识别提示，连原文模式也受益（本轮接上）

### ASR 后处理（⭐ 贴 coding 场景）
- [x] 口头词剥离、重复幻觉折叠、叠字修正、技术术语纠正（tech_terms.json）
- [x] ⭐ 中文标点智能转换，但**保护代码片段/小数/方法链/文件名/URL/函数括号**

### LLM 润色与风格
- [x] 流式 SSE 润色 + 逐 token 预览
- [x] ⭐ 多 Provider（增删改/默认/连接测试/自动故障转移）；预设 SiliconFlow/OpenAI/Azure/自定义
- [x] ⭐ 风格包系统（内置3+自定义+JSON 导入导出）；系统提示词可编辑/恢复默认
- [x] 空内容跳过润色；失败可重试（重试/复制原文/忽略）
- [x] 安全：BaseURL 校验、Key 脱敏、SSE 错误帧识别

### 文本注入（⭐ 本轮重做）
- [x] ⭐ 纯键盘注入（分块 Unicode），多行用 **Shift+Enter** 软换行
- [x] ⭐ **无处可注入兜底**：切 app / 无焦点字段 → 复制到剪贴板 + 区别提示音（不丢字）
- [x] ⭐ **密码框保护**：检测 AXSecureTextField → 不注入也不留剪贴板
- [x] 防重复注入；注入失败也兜底剪贴板

### 词典与自动纠错
- [x] ⭐ 个人专名词典（启用/备注/命中统计）
- [x] ⭐ 自动检测纠错词（原文≠润色 → diff 出新词入库，注入安全过滤）
- [x] 启用词注入润色 prompt（`{{HOTWORDS}}` 占位符）

### 历史 / 统计 / 设置 / 引导 / UI
- [x] 历史 500 条（搜索/过滤/导出 JSON·CSV，公式注入防护）
- [x] 每日统计 + ⭐节省时间估算（vs 40 WPM 打字）；概览仪表盘
- [x] 4-Tab 设置面板（概览/历史/词典/风格/设置）+ 自动保存(0.5s 防抖)
- [x] 4 步首启引导（权限/配置/Demo 试用，独立 Demo pipeline）
- [x] 浮动胶囊 + 音柱可视化 + 实时预览文本 + 4 种提示音

### 架构 / 配置
- [x] ⭐ 5 段可插拔流水线（Recording→ASR→PostProcess→Polish→Injection）+ 会话隔离防竞态 + stage 级错误恢复
- [x] 配置 5 级迁移 + Keychain（按 Provider）；.env 迁移；损坏配置备份不丢
- [x] 诊断日志（10MB 轮转，转写文本只记长度不记内容）
- [x] 无 Xcode 自测入口 `swift run FlowType --self-test`（35 个纯逻辑断言）

---

## 二、待真机验证（代码已绿，效果未实测）⏳

> 都需真实 GUI + 权限；日志在 `~/Library/Logs/flowtype/diagnostic.log`，会写明走了哪条路。
> 出 `.app`：`./scripts/build-app.sh && open build/FlowType.app`（已含 metallib）。

### 键盘注入（本轮重做）
- [ ] **四类目标各注入一次**：终端 Claude Code/Codex、Cursor/VS Code、浏览器 textarea、原生 mac 应用
- [ ] **多行 Shift+Enter**：带换行的内容是软换行、**不会在终端误提交**（个别终端若异常→告诉我，针对它调）
- [ ] **走开兜底**：开始口述后切到别的 app / 点桌面再结束 → 不注入、听到区别提示音(Tink)、Cmd+V 能粘到
- [ ] **密码框**：对 GUI 密码框口述 → 不注入、剪贴板也不留

### ASR 接线（本轮接上）
- [ ] **识别语言**：设置里选「English」后口述英文，确认 Qwen 识别更准（对比「自动」）
- [ ] **词典→识别**：把项目名/黑话加进词典并启用，**单击原文模式**下口述，确认模型直接认对（不靠润色）

### 其他历史改动（更早几轮，未单独实测）
- [ ] 拔蓝牙耳机录音中断 → 自动恢复 idle、不卡死（B2）
- [ ] 剪贴板/SSE/损坏配置等加固在真实使用中无回归

---

## 三、已砍 / 不做（明确决策，勿再提）❌

- 翻译模式（PRD §4.3 曾规划，**不做**）
- Phase-2 差异化：按 app 定制风格 / 上下文感知润色(选中文本) / 剪贴板上下文（死字段已删）
- 设置搜索（已删，从没生效）
- 后处理分步开关 enableFillerStrip/enableTermCorrection、dumpAudio WAV 调试（已删）

> 注：`docs/2026-05-25-flowtype-feature-roadmap-prd.md` 仍列着翻译等，**该 PRD 在这些点上已过时**，以本文件为准。

---

## 四、可选的后续轻量化（未决策）

- `reloadConfiguration` 菜单项冗余（配置本就自动持久），可删
- `AppleSpeechProvider.isAvailable()` 静态方法无调用方（死代码），可删
- `docs/` 历史 spec/plan ~9800 行，如想让仓库更"体现 coding 而非文档"可归档精简
