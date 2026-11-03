# M5 归档来源与选择策略

日期2026-11-03。controller在源码和实际技术门禁独立审查后授权仅做文档/证据归档。被测SHA为 `4cdfaf42cbea1bd04a63a4803a8d103a23e0178f`；本次归档提交不参与该运行的源码身份。当前仓库内脚本 `build/m5-archive-evidence.rb` 为忽略的本次操作工具，不是新增产品依赖。

## 允许输入

- A/B：只从controller准备的 `build/m5-evidence-staging/a` 与 `b` 复制其安全文本；不访问A/B原scratch。
- C：只从 `.superpowers/sdd/2026-11-03-m5-c-verification-and-acceptance/` 取明确列出的context、brief/report/review、progress、三份任务diff、公开CI来源快照及限定名称的RED/GREEN/compile/实际运行原始流。排除plan-path及重复全M5 diff。
- 历史code run `16D28FC9-F86F-4188-93B2-392D61E071AF` 与最终release run `3683D6F7-2BD5-4F54-A3EF-5F80A38020D0`：先核对schema/runID，仅接受报告中的固定 `children/<UUID>/{stdout,stderr,process-result.json}` 或 `internal-<UUID>/<UUID>.{stdout,stderr}` 引用；只复制已存在的明确文件。
- 诊断：只取各child唯一 `validation-<UUID>/Logs/diagnostic-{selftest,smoke}.log` 及最多三个轮转；artifact-check只取固定check-result/artifact流、UUID命令流和固定validation-root中的同名诊断日志。
- 最终manifest与两个由artifact-build时间区间确认归属的build目录：`packaging-B750A71B-E026-4072-A5A6-DBB8DEF72A58`、`recovery-4833EDF2-662A-4A06-A5D0-98DA2D4FDF05`；只取UUID.stdout/.stderr。

选择性复制共493个文件。A/B当前staging和C最终ledger在提交前同步，更新只反映完成状态，B3历史产物报告不改写。原始C实际运行报告保留当时“归档待调度”的历史结尾，当前完成状态以本索引和ledger末尾为准。

## 路径与完整性

复制前对仓库内每个字面路径组件作lstat/realpath核对，拒绝链接、`.`/`..`/空组件、非目录祖先、非普通输入文件和逃逸。输入以NOFOLLOW打开并确认普通文件；新目标使用独占创建及NOFOLLOW，目录逐组件检查。没有按任意报告路径递归复制整个run根。

[archive-selection.json](archive-selection.json)记录每个被选文件的相对path、bytes、sha256和sourceKind；在所有最终ledger拷贝后重算。新写的README、策略、裁决和选择清单另由[SHA256SUMS](SHA256SUMS)覆盖；SHA清单只排除自身，生成及验证均检查每个路径组件、普通文件和链接。SHA256用于完整性比对，不声明签名认证。

## 排除项与限制

不复制普通app/二进制/shader、模型或缓存、音频、真实配置/词典/DB/Keychain、defaults、生产日志；不读取其他计划scratch、不下载/安装/改依赖/联网、不启动普通app或修改权限/录音/输入/剪贴板/服务配置。没有构建、full、artifact、smoke或fixture重跑。复制的patch和日志只来自已授权的合成验证与controller安全staging；原始日志并非普适脱敏工具。

归档检查仅包括JSON摘要、候选/报告关联、清单路径/字节/hash、Markdown相对链接与scoped diff。它不补足真实验收或远端执行；41项人工及远端CI仍Pending。
