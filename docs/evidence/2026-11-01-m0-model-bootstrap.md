# M0 续接：本地模型补齐与基线准备

- 日期：2026-11-01；时间统一使用 UTC。
- 分支 / 核验代码：`flowtype-local` / `e22721b`。
- 目的：解决 Task 3 的引擎缺失，继续既有 M0/M1 计划。
- 本记录不代替真实麦克风 → 识别 → 交付基线；M1 仍须等待 Task 3 通过。

## 续接时的状态

- 推荐的 1.7B 模型目录没有模型文件；FlowType 应用未运行。
- 已安装配置的路由仍为 `localOnly`，没有修改路由或 API Key。
- `/Applications/FlowType.app` 可执行文件修改时间为 2026-10-22 18:37:09（本机时区）；签名为 adhoc，Identifier 为 `com.flowtype.app`，CDHash 为 `de4d96988b5dcf15a896a38592ef3074cb53ee58`。
- 本次仅运行 SPM 构建 / 自测，没有重新打包或替换已安装应用。

## 手动补齐模型

镜像 revision API 返回仓库 `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 的 revision：
`d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6`。

先尝试 `hf download`（关闭隐式 token），在 HEAD 元数据阶段失败：
`FileMetadataError: Distant resource does not seem to be on huggingface.co`。
这属于本次 Python CLI 的错误；不能直接等同于此前 CFNetwork 的 308 根因。

随后使用 curl 按固定 revision 下载五个运行时文件：`config.json`、
`merges.txt`、`model.safetensors`、`tokenizer_config.json`、`vocab.json`。
下载到同目录下的 `.m0-partial` 文件，通过验证后才更名，不覆盖已有文件。
JSON 文件额外执行 JSON 解析验证。

权重首跳响应：HTTP 302，`X-Repo-Commit` 与固定 revision 一致；
`X-Linked-Size = 2225411512`；`X-Linked-Etag` 为：
`6d3ded9f339df22308f57f3287b32940a7297c4ffc597debcfbeff41ca0ff8bd`。
完成后对权重校验字节数及 SHA-256；此校验用于验证下载完整性，预期值来源于镜像响应。

可复核命令（不含凭据）：

```bash
curl -fsSL --max-time 25 \
  https://hf-mirror.com/api/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/revision/main
curl -fsSI --connect-timeout 15 --max-time 30 \
  https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6/model.safetensors \
  | rg -i '^(HTTP/|x-repo-commit:|x-linked-size:|x-linked-etag:)'
```

下载完成，五个文件验证通过。权重实测为 `2225411512` 字节，实测 SHA-256
与上述 `X-Linked-Etag` 一致。下载过程未删除模型目录或应用 URL 缓存。

## 已安装应用的离线加载

通过原有 `/Applications/FlowType.app` 启动（PID 89106）。以下为
`~/Library/Logs/flowtype/diagnostic.log` 中本次启动的节选：

```text
[2026-11-01T07:05:13] [EventTap] CGEvent tap created and enabled successfully
[2026-11-01T07:05:13] [AppDelegate] Flowtype launched successfully
[2026-11-01T07:05:13] [QwenASR] Loading model: aufklarer/Qwen3-ASR-1.7B-MLX-4bit offline=true cacheDir=/Users/yiheng/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit
[2026-11-01T07:05:15] [QwenASR] Model loaded successfully
[2026-11-01T07:05:15] [ModelProvision] Loaded offline from /Users/yiheng/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit (modelId=aufklarer/Qwen3-ASR-1.7B-MLX-4bit)
```

采集命令为 `pgrep -fl '/Applications/FlowType.app'` 与按上述组件筛选日志末尾。
同次启动在 `07:05:13` 还记录过 `[AppDelegate] Qwen3-ASR model loading failed`，
随后 `07:05:15` 的 provider / provision 两行确认实际离线加载成功；
不以这条较早的 AppDelegate 文案单独判定最终状态。

结论：**模型缺失的环境阻塞已解除，event tap 本次创建成功**。
这不证明麦克风授权有效、真实 ASR 成功或文本已交付。

## 代码检查

- `swift build`：exit 0，`Build complete! (28.34s)`。
- `swift run FlowType --self-test`：exit 0，`1093 passed, 0 failed`。
- 自测与真实会话分开核验；自测中的模拟 cloud / session 日志不作为真实听写证据。

## 真实基线

- 目标：TextEdit 1.20 的新建空白文稿。
- 尚未开始真实听写；停止 → 最终文本、停止 → 交付、字面量保留和单次交付均未验证。
- 下一步：Owner 在 TextEdit 正文使用现有热键（双击 Command 开始、单击停止）朗读计划的参考句；随后核验实际引擎、目标落点、重复交付及延迟。
