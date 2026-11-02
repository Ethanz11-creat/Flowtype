# Whole-M4 final fix wave — single consolidated wave

Working directory /Users/yiheng/pycode/flowtype-local. BASE24f2e517bc137769af07b77622ad0eed358b25b0; latest product sourcec292110. No uncommitted source. Read `final-review.md` in this same directory FIRST: Important I1 and Minor M1 are the complete authoritative finding list, including exact triggers, source lines and requested behavior. Read linked design for authority and current controller/test interfaces. Do not reread all prior task reports unless a specific interface needs it.

## Work

1. Reproduce I1 using actual SessionController and InjectionStage, synthetic event/target/recording boundaries only. One-shot `.injecting` subscriber cancels A/starts B. B marks ready and waits with observable task-cancellation cleanup. Stopping/cancelling B must cancel its actual task exactly once; A must produce no event/copy/history. Do not fake controller task bookkeeping or merely test fixture logic. Add `.preparing` synchronous cancellation: final stateidle, last windoweffecthide, no stage starts. Cover the related readiness→recording transition/timer continuation (callback cancellation/new session must not let older timer/cleanup replace the newer one), either focused observable timer behavior or justify precise static guard with existing coverage. Bounded asynchronous waits; release gates on failure to avoid hanging.
2. Run focused RED and preserve meaningful output. Fix caller ownership/generation continuation after synchronous transition/effect/publication boundaries which still have lifecycle work. At minimum guard before old Injection task creation/storage, before trailing preparing showWindow and before readiness timer continuation. Keep same private controller/context lifecycle; no new coordinator/state machine, no broad pipeline rewrite. Inspect the changed caller paths for same-session presentation-generation replacement as well as new IDs. Do not weaken current action/audio/route/event gates.
3. Resolve M1's two introduced test Sendable mutable-capture warnings using small MainActor fixture holder(s); preserve exact real Combine trigger tests and all assertions. Accurately supersede prior report warning accounting: those two were introduced, not preexisting. Do not modify raw historical logs.
4. Focused GREEN `--m4-recovery-only`, then sequential swift build and full self-test ONCE source stable; full justified by shared orchestration continuation changes. Keep prior23855/0 as old evidence, not current result. Runtime commands prefixed with env CFFIXED_USER_HOME=<owned SDD>/final-fix-runtime-home, mkdir beforehand; no HOME override. No Python, dependency installs, model/cache/key/config/real network/hardware/permissions. No benchmark or swift test.
5. Self-review scoped diff and commit only source files owned by this wave. Expected files Core/PipelineOrchestrator.swift and Testing/M4RecoveryControllerSelfTests.swift; extend only if concrete fix requires and report why. Parent docs remain untouched.

## Report / process

No subagents or helper reviewers. Ask root on genuine interface ambiguity; do not ask user permission. Write `final-fix-report.md` beside this brief with each finding, exact fix, covering testfiles, RED/GREEN/full commands+outputs+counts/rawlog paths, warnings accounting and source commit. Raw logs use final-fix-*.log here. Return only status, commit, one-line test summary, concerns, report path. Final whole-review allows ONE fix wave + ONE scoped rereview; include entire findings list, do not park a known load-bearing issue silently.

## Binding Global Constraints (from plan)

- Swift 6.2、macOS15+；不新增/升级依赖，不运行 Python/转换，不下载模型，不访问真实配置、密钥、录音或模型缓存。
- 单一 SessionController/SessionContext 生命周期；旧 session、旧恢复卡、旧异步完成不能发起请求、复制、改设置或覆盖当前 UI/历史/摘要。
- 保留 M3 event/effect latch、一次 deliveryAttempt、逐键对目标复检、完整剪贴板/changeCount/用户新复制保护和150ms settle；任何 uncertain/cancel 均无重发动作。
- 原始 PCM、saved route、captured local lease、显式 ASR retry 的完整样本/新实时 handle/新20s预算保持；设置修复需要新录音，不偷偷改捕获路由。
- 可选 polish 失败继续完整 processed fallback；静音/空录音保持 notice，不走 provider/preview/health/交付/历史；非法音频不重试原 PCM。
- 用户界面和新增诊断只用稳定安全文案/枚举；不展示或记录 provider message、HTTP body、URL/query、NSError userInfo、原始文本或密钥。
- 自动化仅用合成数据、假系统/网络/剪贴板与隔离配置。验证顺序 swift build → swift run FlowType --self-test；不运行 swift test，不重复未变全套或30分钟 benchmark。
- Task2 起每个 self-test 进程设置 `CFFIXED_USER_HOME` 为本计划 scratch 下独立 task-N-runtime-home（mkdir 后以 env 前缀启动），不改 HOME；注入空 ASR 词典，避免全局词典读取。Task1/历史 full 的用户目录读取和日志写入隔离限制单独记账，不虚记全隔离。
- 分支/worktree保留，不push、不merge；源码审查、固定产物与真机矩阵分别记账，未执行为 Pending。

