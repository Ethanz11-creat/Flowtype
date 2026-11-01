# M2-B 云端 ASR 厂商接入设计

日期：2026-11-01；收口更新：2026-11-02。状态：方案已批准，M2-B 已实现并完成阶段审查（6fc1973，2034/0）；真实云端服务、GUI 和 V1 变体验收仍 Pending，最终全 M2 审查由控制器执行。
总范围：[M2 设计](2026-11-01-m2-model-recovery-design.md)。

## 目标

用户选择厂商，获得已填好的 URL、模型和识别方式，填入密钥后即可启用。
模型名称可见且可更换；自定义兼容服务支持填写自己的 URL / Key / 模型 ID。
保留既有路由、完整音频回退、配置快照与单次交付，不改 LLM 配置。

## 厂商目录与能力

| 入口 | URL / 初始模型 | 管线与请求策略 |
| --- | --- | --- |
| 硅基流动 | 默认沿用 `https://api.siliconflow.cn/v1`；`FunAudioLLM/SenseVoiceSmall` | multipart 转写；只发文档确认的 file / model；提供 TeleSpeechASR 与自定义模型入口 |
| OpenAI | `https://api.openai.com/v1`；首版选择 `whisper-1` | multipart 转写、JSON结果；语言与 prompt 按该模型能力发送；其他模型通过明确能力映射增加 |
| 阿里云 DashScope | 沿用现有 WSS URL 与 `paraformer-realtime-v2` | 复用现有实时会话，不混入 HTTP multipart；保留其真实录音时验证的语义 |
| 自定义 OpenAI 兼容 | URL / 模型 ID 由用户填写 | 最小 file / model / JSON 协议；可选语言、prompt 默认不发，由高级设置显式打开 |

厂商身份使用稳定 ID，不再通过域名子串判断。协议与模型能力来自目录，
不能根据“OpenAI兼容”就发送所有 OpenAI 可选字段。目录是后续适配扩展点；
不兼容的其他厂商原生协议需要新适配器，不能仅改厂商名称就宣称支持。

OpenAI 首版模型是本设计的选型，尚未在当前会话验证账户可用性；其官方文档
抓取被403拒绝。实现先复用已存在的最小兼容HTTP合同（file/model/JSON），不借此
添加未经复核的模型/高级字段；在线文档复核与真实账户识别留在验收清单，不能
把本地契约测试当作已完成在线验证。若官方合同不符，修订能力项后再验收。

## 配置与交互

“添加云端服务商”按厂商列出入口；创建时填默认 URL / 模型，Key 使用 SecureField。
用户可改 URL、换预设或填自定义模型 ID；默认路径不需要理解协议枚举。
厂商不变时编辑 URL 不重置模型或 Key。已有 profile 的 UUID / 启用状态 / Key
关联保持，升级不覆盖已有模型和 URL；未知旧厂商映射为兼容自定义并保留原名。

一次会话使用录音开始时的配置快照。编辑、删除、切换 active profile 只影响
下一次会话；连接测试结果按 profile 与配置版本匹配，旧测试不能为新配置打勾。
点击保存不发音频、不测服务。配置有误时 readiness 给出具体修复入口。

HTTP 输入接受 Base URL 或以 `/audio/transcriptions` 结尾的完整地址，去除多余
末尾斜杠后只拼接一次。HTTPS、无 userinfo / fragment / query；非法输入保留在
编辑器并给解释，不静默丢弃 URL 部分后发送。WSS 单独验证沿用既有路径合同。
向已配置目标发送 Bearer Key；跨源重定向不携带 Key、不自动跟随发送音频。

## 请求、验证与错误

批量 HTTP 使用现有 PCM→WAV→multipart→ASRResult 管线，提取厂商能力与请求构造
边界；不另建第二套录音/交付流程。成功必须符合该适配器的返回格式，HTML 或
未知 JSON 不能当作转写。自定义兼容允许的返回形式在适配器中固定，不猜测。

“检查配置”只做本地 URL、Key、模型和协议校验，显示“配置有效，尚未连接”。
批量服务另提供“测试识别”，按钮旁说明会发送短合成测试音频、可能计费；
成功只表示该配置在该时刻完成一次真实识别，不表示弱网/长录音全部通过。
DashScope 保留现有配置验证与真实录音验证边界，本轮不另建假装测试成功的路径。

错误分为配置、鉴权、模型不可用、限流、服务错误、网络/超时、响应不兼容；
保留适合恢复的动作与HTTP状态，不输出 Key、请求音频、上下文、原始响应正文或
带敏感参数的地址。取消继续是取消，不污染云端健康或触发迟到交付。
厂商不支持上下文/语言时显示该能力限制，不偷偷改变用户全局上下文设置。

## 验收

用注入 URLSession/传输和合成音频覆盖各厂商 multipart 字段、Base/完整URL、
重复后缀、400/401/403/404/429/5xx、HTML/异常JSON、跨源跳转、脱敏、取消、
切换profile/模型/Key后的旧测试返回，以及旧配置解码和UUID/密钥关联保留。
沿用现有路由快照和实时回退回归；不在测试中读取实际配置、Key或调用付费服务。

真实厂商验收记录到主线V1：硅基流动与OpenAI分别真实短句、弱网/断网、取消、
本地回退与唯一落字；没有相应凭据或未执行的服务变体标为Pending。
离线契约测试通过不能替代实际厂商可用性。检查与构建按总设计顺序执行。

## 本轮来源与限制

- 已获取：[SiliconFlow 转写官方文档](https://docs.siliconflow.com/en/api-reference/audio/create-audio-transcriptions)。
  公开示例为 `/v1/audio/transcriptions`、Bearer、file / model 和 JSON text，列出
  `FunAudioLLM/SenseVoiceSmall`、`TeleAI/TeleSpeechASR`。英文页面使用 `.com` 服务域，
  本产品原有 `.cn` 地址保留且可编辑；未据此宣称两区域Key通用。
- 获取失败：[OpenAI speech-to-text](https://developers.openai.com/api/docs/guides/speech-to-text)
  及 platform.openai.com 对应页面均HTTP403；当前未对官方合同做成功在线复核。
- 源码依据：CloudASRProvider、CloudASRProviderList、Configuration、
  ASRRouter、DashScopeRealtimeASR。未执行真实云端请求。
