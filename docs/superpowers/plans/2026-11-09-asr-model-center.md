# ASR Model Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可更换云端、本机服务与原生离线 ASR 的完整模型中心，含 HF 获取、可靠安装、验证、切换与发行验收。

**Architecture:** 保留公共录音/处理/交付链路，以稳定 backend ID 和捕获 binding 接入模型。HF resolver、下载事务、原生激活、原生界面各自独立；外部服务由用户管理。

**Tech Stack:** macOS 15+ / Apple Silicon、Swift 6.2、SwiftUI、Foundation URLSession、CryptoKit、现有锁定 ASR 依赖与 self-test/verification 工具。

**Spec:** [总设计](../specs/2026-11-09-asr-model-center-design.md)；[A 后端](../specs/2026-11-09-asr-backends-design.md)；[B 安装](../specs/2026-11-09-hf-model-installation-design.md)；[C 体验](../specs/2026-11-09-model-center-experience-design.md)。[调研依据](../research/2026-11-09-asr-model-center-research.md)。

## Global Constraints

- 平台为 macOS 15+、Apple Silicon、Swift 6.2；保留 macOS 原生 SwiftUI 客户端。
- 保持 speech-swift 0.0.15、WhisperKit 0.18.0、swift-transformers 1.1.9 锁定基线；新增依赖或升级必须单独说明依据。
- 核心音频契约为 16kHz、单声道 Float32；协议适配器负责 wire 编码；一次录音只交付一次终稿。
- 原生推理严格离线；下载是显式独立操作；外部模型服务由用户自行安装、启动和更新。
- 下载、检查、加载、试识别、选中分别建模；失败或取消不替换已有可用选择，不删除用户自有模型。
- 录音开始捕获不可变后端、模型、能力与凭据快照；迟到回调不能改变新会话或新配置。
- 自动化使用隔离临时根、合成文件与注入 transport；不读写用户真实配置、密钥、模型、权限或剪贴板。
- 各任务顺序运行 swift build 与 self-test；最终运行现有 code/artifact/release 门禁；Pending 不等于 Pass。

## Review Focus

1. HTTP 路径兼容不等于响应/字段兼容：MLX 默认 NDJSON、whisper.cpp 无必填 model（A3）。
2. HF 多变体与缺失 tokenizer 不能导致整仓下载、错误语言或推理时补网（B2/B5）。
3. Range 被忽略、签名 URL 过期、进程中断不能拼出损坏安装（B3/B4）。
4. 切换/取消/删除与在途会话交错，旧 lease、凭据和目标身份仍有效（A4/B5/B6/C4）。
5. 新页面通过不能覆盖 CI 失败、原 41 项 Pending 与正式分发缺口（D1–D4）。

## 拆分与顺序

这是一个版本的交付，拆成四个可独立审查的子项目。每项任务的文件、接口、RED/GREEN、提交与交付标准在对应计划，不在本索引重复。

| 顺序 | 计划 | 独立交付 |
| --- | --- | --- |
| 1 | [D1：先恢复 CI 基线](2026-11-09-asr-model-center-d-release-acceptance.md#task-d1-恢复远端-ci-基线) | 对 timer 失败有证据解释与本地回归；远端复核纳入 D3 |
| 2 | [A：后端与服务协议](2026-11-09-asr-model-center-a-backends.md) | 公共链路可通过 fixture 调用 native/cloud/loopback，保存真实身份与快照 |
| 3 | [B：HF 获取与安装](2026-11-09-asr-model-center-b-hf-installation.md) | 精确版本安装、持久恢复、离线验证与托管文件生命周期 |
| 4 | [C：原生模型中心](2026-11-09-asr-model-center-c-native-experience.md) | 五种入口、统一选择与状态、原生恢复/试用闭环 |
| 5 | [D2–D4：完整验收与发行](2026-11-09-asr-model-center-d-release-acceptance.md) | 新旧真机矩阵、独立代码审查、候选技术门禁与正式分发证据 |

- [ ] 用户评审书面设计与本计划，确认本版目标与边界。
- [x] D1 本地基线后已按 A1–A6 → B1–B6 → C1–C4 完成实现、聚焦回归与顺序审查；最终修复提交 `d43a603`。
- [ ] D2–D4 收口；真实凭据/设备/签名条件缺失的项保留 Pending，不能报告发布完成。

## 当前交付状态（2026-11-10）

[最终证据归档](../../evidence/2026-11-10-asr-model-center/README.md) 与 [研究→owner→证据覆盖](../../evidence/2026-11-10-asr-model-center/coverage.md) 记录本轮结果。D1 本地 timer 修复、A1–A6、B1–B6、C1–C4、D2/D4 工具均已实现并审查；最终整体审查 I1/M1 经一次修复与 fresh scoped rereview 关闭。代码候选 `d43a603` 的 code gate 28,335/0；ad-hoc artifact 22/22 phase、10/10 smoke Pass；release 复用同一 App，24/24 技术 phase Pass，整体 exit 2 / Pending。D2/D4 对真实技术候选也均 exit 2 / Pending。

原 41 项 + 新 30 项真机均 Pending；远端 CI 未运行，历史 run 41672136709 failure 不变；Developer ID/公证/最终 DMG/干净机器验收 Pending。因此 D2–D4 的代码工具完成不等于正式发行验收完成。证据归档仅改文档，归档 commit 与二进制候选 commit 分别记录，不将旧报告重标为文档 HEAD。所有 52 条 controller Ruling 及成本原文见 [rulings](../../evidence/2026-11-10-asr-model-center/rulings.md)。

## 执行约定

每个 task 是一次独立可拒绝的交付：先失败回归，再实现，再聚焦验证，再提交和 fresh review。子智能体读取父设计、对应 spec、当前 task 与前置 Interfaces；不只读取本索引。审查发现影响邻接接口时更新文档并通知后续任务，不通过复制类型各自解决。

代码开发使用隔离 worktree，执行时按 using-git-worktrees 选择位置；不要在计划阶段创建。自动化不安装真实服务或下载大模型；真机矩阵是单独的显式操作。阶段完成后才运行一次全量 code；没有新失败不重复跑全量。源码/候选需要干净且身份固定才进入 artifact/release。

本组文档最初为研究与计划交付；2026-11-10 已完成实现与技术候选验证，真实发行验收仍为 Pending。现有 CI 失败不是本次文档造成的；不通过更改报告将它标为 Pass。未经本轮后续发布指令不 push、合并或发布分发包。

## 计划自检与覆盖

2026-11-09自检：20个任务均有文件、Interfaces与可检查步骤；实现任务包含失败回归、实现和验证，人工验收任务明确证据与审查要求。11份文档/来源快照的相对链接与JSON语法已检查。共享接口检查修正了下载源恢复、credential generation、模型ID/安装ID区分、原生引擎注册和正式候选重建问题。

| 设计要求 | 所属任务 |
| --- | --- |
| 原生/云端/服务身份、旧配置与凭据迁移 | A1/A2 |
| 厂商协议、模型能力、发现与试识别 | A3/A5 |
| 会话快照、实际后端、隐私与回退预算 | A4/A6 |
| HF版本/变体/分词器/引擎注册与精确配方 | B1/B2 |
| 续传/摘要/持久恢复/安装事务 | B3/B4 |
| 原生试识别、资源准入、占用与删除保护 | B5/B6 |
| 五入口、统一状态、原生布局与恢复 | C1–C4 |
| CI、原41项+新30项、候选身份与公证分发 | D1–D4 |

调研只验证接口与源码事实，未运行新功能或真机矩阵；推荐模型/服务的实际可用性仍由D3结果决定。
