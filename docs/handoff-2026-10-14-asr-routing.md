# Flowtype ASR 路由 / 探测工作流 — Handoff

日期：2026-10-14 · 分支：`flowtype-local` · HEAD：`d3941dd`

> 面向下一个会话/Agent：无需回读原始对话即可接续。

---

## 1. 一句话现状

已完成「统一 ASR 能力层 + 无感择优路由 + 前台上下文采集 + 端到端指标」（方向 A/B）以及「云端握手探测」。
`swift build` 干净、`swift run FlowType --self-test` → **412 passed, 0 failed, exit 0**。
**未推送、未合并，`main` 自始至终未改动。**

### 立刻可用的验证

```bash
swift build
swift run FlowType --self-test   # 期望：412 passed, 0 failed, exit 0
```

---

## 2. Git 状态（已核实）

| 项 | 值 |
|---|---|
| 分支 / HEAD | `flowtype-local` / `d3941dd` |
| 本工作流 commit 数 | 25（`b033e7d..d3941dd`；`b033e7d` 是 spec+plan 的文档提交） |
| 相对 `origin/flowtype-local` | 领先 29 个 commit，**未推送** |
| `main` / `origin/main` | 均为 `f34c5db`（2026-05-07），**未改动** |

### ⚠️ 关于合并回 main

`main` 是**旧单体架构快照**（2026-05-07），与本分支已严重分叉：186 文件差异、试合并 **25 处冲突**，其中 6 处是"本分支已删除的旧 provider 架构文件"（`SpeechRouter`/`SenseVoiceProvider`/`SiliconFlowSpeechProvider`/`TeleSpeechProvider`/`AppState`/`AsyncRefiner`）。

**不要用常规 merge 合回 main。** 若要把当前状态落到 main，应走 `main` 直接指向本分支（破坏性，需用户明确授权；`main` 上只有 5 月的 `v1.0`/`v1.1 listening` 两个 commit）。用户此前已明确选择**不合并、工作留在 `flowtype-local`**。

---

## 3. 交付物地图

### 新增

| 文件 | 职责 |
|---|---|
| `Sources/flowtype/Services/Speech/ASRContract.swift` | 统一契约：`ASRCapabilities` / `ASRContext` / `ASRRequest` / `ASRResult` / `ASRProviderID`（id 单一事实来源）/ `composeProviderContext` / `fallbackReason(for:)` |
| `.../ASRRoutingPolicy.swift` | `ASRRoutingPolicy`（auto/cloudOnly/localOnly）、`ASRRoutingInputs`、`ASRRoutingThresholds`、纯决策 `selectASRChain` |
| `.../ASRRouter.swift` | 健康画像（EWMA + 时序）、`NWPathMonitor`、探测定时器、纯装配 `routingInputs(from:policy:localAvailable:cloudAvailable:now:)`，纯助手 `updateLatencyEWMA` / `sampleIsFresh` / `agedLatencySample` / `PathSignature` / `pathChanged` / `invalidateLinkSamples` / `shouldProbeCloud` |
| `.../CloudProbe.swift` | TCP+TLS 握手计时（2s 超时）+ `SingleResumeBox`（exactly-once resume） |
| `Services/Context/ContextProvider.swift` | `ForegroundContext`、`ContextProvider` 协议、纯函数 `buildContextText` / `redactContextSecrets` / `isSecureFocus` |
| `Services/Context/AXContextProvider.swift` | Accessibility API 采集前台上下文 + 安全字段守卫 |
| `Core/SessionMetrics.swift` | `percentile`（round((n−1)×p) index）+ `SessionMetrics.report`（P50/P95，content-free） |

### 删除
- `SpeechProvider.swift`、`SpeechRouter.swift`

### 关键改动
- `Core/Pipeline/Stages/ASRStage.swift` — 重写为纯编排（组装 `ASRRequest` → 走候选链 → 首个成功即停）
- `Core/PipelineOrchestrator.swift` — 消除 `as?` 特判、指标埋点、本地模型启动暖机、启动探测
- `Core/Configuration.swift` — `asrRoutingPolicy` 取代 `asrEngine`（legacy 键优先映射），新增 `cloudASRSendContext`
- `Core/Database/{Records,AppDatabase}.swift` — 7 个指标列 + 迁移 `v4_metrics`
- `Core/Pipeline/Stages/{RecordingStage,InjectionStage,PolishStage}.swift`、`Settings/SettingsPage+ASR.swift`、`Settings/ASRModelStatusCard.swift`

---

## 4. 设计决策（有意为之，勿"顺手改掉"）

1. **不做流式 ASR、不做中间文本上屏**（用户明确要求，对齐 typeless）。Apple Speech 预览降级为「全部候选失败时的内部兜底」。录音中只显示波形 + 计时。
2. **路由默认为云端优先，网络差时无感切本地**（用户明确，与"本地优先"相反）。老配置 `asrEngine=local→localOnly`、`cloud→cloudOnly` 保持原有行为。
3. **云端默认携带前台上下文**（用户明确接受），并提供「云端发送上下文」开关作为隐私退路；本地路径音频与上下文都不出设备。
4. **两套阈值必须分开，量纲不同**：`cloudLatencyMs = 3000`（整轮请求延迟，EWMA 的标定对象）vs `cloudProbeHandshakeMs = 600`（TCP+TLS 握手，探测的标定对象）。**绝不可共用。**
5. **样本时效是非对称的**：陈旧的「慢」证据保留（保守不需要新鲜证据）；陈旧的「快」值降级为未知，交给探测按当前链路重判。若两者都清零，「握手快但服务端慢」的链路会在 cloud/local 间振荡 —— 因为握手**看不见服务端推理耗时**，而云端 ASR 延迟大头正是推理。
6. `ASRCapabilities` / `ASRProviderID` 作为单一事实来源；无 consumer 的字段（`maxAudioDuration`/`estimatedWarmLatencyMs`）已裁掉 —— 新增字段前请确认有真实 reader。

---

## 5. 已修的真实 bug 与陷阱（勿重犯）

| 陷阱 | 说明 |
|---|---|
| **探测曾结构性空操作** | 握手耗时（实测 85–191ms）被塞进为整轮请求标定的 3000ms 槽位，且 2s 超时把值域截在 `[0, 2000)` → 数学上**永不触发**。 |
| **测试用了生产不可达的值** | 旧断言 `probe: 5000` 是生产永远造不出的值，正是它把上述 bug 藏住。**新测试必须用生产可达值**（如 900ms）。 |
| **测了逻辑、没测可达性** | 若断言在测试内部自制合成、不经过生产组装路径，则回退接线仍全绿。解法：把组装抽成纯函数并钉住它；条件允许时做**变异测试**确认"回退会被抓到"。 |
| 安全输入框 | 读 `kAXValueAttribute` **和** `kAXSelectedTextAttribute` 都必须过 `isSecureIncludingParent` 守卫（元素**或父级**）。 |
| 脱敏正则 | `sk-` 必须带**左词边界**，否则 `disk-partitioning` → `di[REDACTED]`；上下文会喂进 ASR 提示词偏向技术词，过度脱敏**反而伤害技术词命中率**。 |
| 合成 `Decodable` 不认属性默认值 | 非可选的"带默认值"新字段会让 legacy JSON 解码抛 `keyNotFound`。`usedFallback` 曾因此导致旧 `history.json` 静默导入 0 条。**新字段一律 Optional 或显式 `decodeIfPresent`。** |
| 计划文档本身有错 | `docs/superpowers/plans/2026-10-13-...md` 里的 `percentile` 片段（`ceil(n*p)-1`）与其自带测试矛盾；实现已按测试修正为 `round((n-1)*p)`，**但 plan 文档未同步**。 |

---

## 6. 下一步

### 6.1 待用户决策（阻塞项）
**是否允许「慢探测否决新鲜 EWMA」。**
现状：`recordSuccess` 每次成功都刷新 `cloudLatencySampledAt`，因此只要云端每 <5 分钟成功一次，EWMA 永远"新鲜"，探测被**无限期旁路** —— "首次请求前预测慢"只在"云端连续 5 分钟零成功"的窄窗口生效（该窗口已由 TTL 修复覆盖）。
要真正闭合，需给探测**只向下（更保守）的否决权**：慢握手可强行否决云端，快握手永远不能翻案。属产品行为决策，故未擅自实现。

### 6.2 真机验证（只能人工，需麦克风/网络/前台应用）
1. **核心场景**：限速/弱网下**第一轮**录音应直接走本地（此前必然干等云端）。
2. 日志 `~/Library/Logs/flowtype/diagnostic.log` 应约每 30s 出现 `[ASRRouter] cloud probe <host> → <N>ms`；`> 600ms` 即切本地。
3. `.localOnly` / `.cloudOnly` 或未配置云端时，**不应**出现 probe 日志；计费/受限链路也应跳过。
4. 抓包确认探测**只做 TLS 握手**：无 `Authorization`、无音频、无上下文。
5. AX 上下文：授予辅助功能权限后录音应出现 `Foreground context: N chars`；撤销权限后录音仍成功。
6. 延迟矩阵：本地模型冷启动 vs 暖机的 `stop→inject` P50/P95（用设置页「复制指标报告」）。

### 6.3 已知缺口（验证报告标出，尚未修）
- 计费链路只做到"不探测"，未做到"倾向本地"（注释有暗示，属产品决策）
- 云 provider / baseURL 变更不清探测样本（影响 ≤18–30s）
- 启动首 ~1s 无样本
- `AXContextProvider` 的父级上溯逻辑与全部 AX 行为**无自动化测试**（只能真机验证）
- 历史表 `usedFallback` / `fallbackReason` 已打通写入，但"本轮是否降级"的跨阶段透传仍只覆盖 provider 失败与预览兜底两条路径

### 6.4 尚未开始
**方向 C：前端交互框架**（对标 typeless 的单一状态机 + 胶囊即皮肤 + fatal/recoverable 分级）。用户排定的顺序是 A → B → C。

---

## 7. 权威文档

- spec：`docs/superpowers/specs/2026-10-13-unified-asr-routing-and-accuracy-design.md`
- plan：`docs/superpowers/plans/2026-10-13-unified-asr-routing-and-accuracy.md`（注意 §5 表格里 plan 文档自身的 `percentile` 已知错误）
- 对标逆向报告：`/Users/yiheng/pycode/typeless-re/TYPELESS-2.8.1-REVERSE-ENGINEERING.md`
- 逐任务进度台账：`.superpowers/sdd/progress.md`（gitignored，含每一轮的审查结论、遗留项与决策依据）

---

## 8. 硬约束

- `SessionController` 保持 `@MainActor`；`ASRProvider` 实现用 `@unchecked Sendable` + 内部锁/串行队列。
- 音频字节契约：协议边界上是 **16kHz 单声道 Float32 裸样本**（非 WAV）。
- API Key 存在 `Configuration.providerAPIKeys`（UserDefaults），**不得**迁回 Keychain。
- 不做流式、不上屏中间文本；可执行代码中不得出现 `as?` / `is` provider 类型判断（测试断言字符串除外）。
- 每步结束必须 `swift build` + `swift run FlowType --self-test` 双绿。
- 提交风格：`feat(...)` / `fix(...)` / `refactor(...)` / `test(...)` / `chore(...)`。
