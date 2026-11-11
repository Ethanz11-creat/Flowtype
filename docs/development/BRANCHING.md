# 分支管理约定

整理日期：2026-11-11。当前活动分支收敛为三条，各自承担一个明确用途。

| 分支 | 用途 | 使用方式 |
| --- | --- | --- |
| `main` | 历史发布基线，当前不是最新产品开发代码 | 发布整合时明确检查，不自动与开发线互相覆盖 |
| `flowtype-local` | macOS 原生客户端的产品开发主线 | 日常产品修复和功能联调在这里推进 |
| `feat/iflytek-interview` | 科大讯飞面试准备 | 数据调研、评测工具、实验结果、面试材料与演示原型 |

面试分支从产品提交 `fce500f647ade0ac1e25593ffb950be412358d30` 建立。分支整理时将此前未提交的面试材料做成本地检查点；后续提交继续留在面试分支，产品发布时不自动带入实验数据。

## 日常规则

1. 开始工作先检查 `git status --short --branch` 和 `git worktree list`，优先使用已有对应分支，不因换工具、换会话或换智能体再建长期分支。
2. 仅为明确独立的目标建立临时 `feat/<goal>` 或 `fix/<issue>`；普通的同一任务续做复用原分支。
3. 切换任务前把已确认的工作做成有意义的本地提交。未跟踪文件属于工作区，单纯切换分支不能把它们隔离到某个分支。
4. 收尾时检查目标分支是否已包含全部提交。已合并的临时分支可删除；尚有独有提交的历史线先建可验证的归档标签，再退出活动分支列表。
5. 工作区登记只在路径确实失效时清理；不顺带删除其他目录中的未提交文件。当前保留主仓库 `main` 工作区和面试工作区。
6. 推送、合并或删除远端分支按具体任务执行；不把本地整理等同于远端发布。

整理时 `flowtype-local` 比 `origin/flowtype-local` 领先45个本地提交。面试分支继承这些产品提交；以后建立PR时先明确产品基线的同步策略，不能把继承的产品改动描述成面试新增内容。

## 历史分支归档

这些分支来自此前不同阶段的实现，没有因为名字旧就丢弃提交。独有提交数按“不在保留的 `flowtype-local` 或 `main` 中”统计，不代表其中所有功能都适合合入当前产品。

| 原分支 | 未包含的提交数 | 归档标签 | 内容线索 |
| --- | ---: | --- | --- |
| `flowtype-dev` | 27 | `archive/2026-11-11/flowtype-dev` | 早期设置/翻译、Python服务、VAD分段和文本累积实现 |
| `flowtype-trae` | 4 | `archive/2026-11-11/flowtype-trae` | 早期云ASR与模型管理配置方案 |
| `codex/local-first-core` | 14 | `archive/2026-11-11/codex/local-first-core` | shared core、localhost后端和网页客户端试验 |

原分支已移出活动分支列表，提交由归档标签保留；本地另有已验证的完整 Git bundle。精确提交、恢复命令、备份hash见[归档记录](branch-archive-2026-11-11.json)。没有合并这些历史分支，也没有修改 GitHub 分支。

只读查看历史内容：

```sh
git log archive/2026-11-11/flowtype-dev --oneline
git ls-tree -r --name-only archive/2026-11-11/flowtype-dev
git show archive/2026-11-11/codex/local-first-core:path/to/file
```

需要继续历史开发时，在工作区干净后恢复分支：

```sh
git switch -c flowtype-dev archive/2026-11-11/flowtype-dev
```

这只重建分支引用，不要求恢复旧的失效工作区。Git bundle 位于 ignored `build/branch-management/2026-11-11/before-cleanup.bundle`，它是本机额外备份；归档标签本身保留在本地 Git 仓库中，目前尚未推送。

## 面试任务的历史参考

归档检查发现 `flowtype-dev` 曾实现过 VAD 驱动分段、`StableTextAccumulator`、Silero `/vad` 服务和相关设计。后续执行面试计划时应先通过归档标签读取这些代码，评估可复用部分；不能直接将旧实现视为当前分支已具备或已完成真实评测。
