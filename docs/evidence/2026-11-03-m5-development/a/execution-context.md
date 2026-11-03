# Binding execution context

Spec: docs/superpowers/specs/2026-11-03-m5-release-guardrails-design.md


- Swift6.2+、macOS15+、Apple Silicon；不新增或升级外部依赖/Package.resolved，不运行Python、不下载ASR模型或自动安装shader/toolchain。
- 用户本轮仅要求计划；产品源码、现有构建产物与系统配置保持原状。不把规划写成已实施或验收通过。
- 后续开发使用合成数据、假服务/剪贴板/输入事件和独立运行目录；不读取真实配置/词典/DB/Keychain/模型缓存，不触发授权弹窗、录音、热键输入或外部ASR/LLM请求。
- 普通app仍使用原用户配置/目录/启动行为；验证模式必须在任何shared/logger/AppKit初始化前确定，初始化失败退出，禁止回退到生产路径。
- 保留M1–M4 readiness降级、captured route/lease、原音频重试、新20s预算、新实时句柄、单次交付、剪贴板与取消/回调所有权保护；不借M5改写这些合同。
- 构建/运行报告只含身份、阶段、闭合枚举/计数/状态；不输出密钥、请求正文、转写、用户文档、原始配置、URL/query或任意NSError.userInfo。自动上传仅显式白名单的合成验证产物。
- 验证按focused→顺序swift build/full self-test；不运行swift test或重复未变全套/声学benchmark。M4的23872/0仅作历史基线，不重复一次未变baseline。
- 保留分支和worktree，不push、不merge、不安装到/Applications、不替换正在运行的app。V1–V5/真实模型/声学校准/GUI未执行均Pending。


The prior planning-only bullet is superseded by the latest user authorization to develop M5. All safety/data/external-side-effect constraints remain. One reused implementer only; no nested agents. Controller performs reviews and owns bookkeeping. Do not edit plan checkboxes or the ledger; controller owns those. No full self-test before A2 isolation. Do not construct production shared objects in RED. Stay within one assigned task.
