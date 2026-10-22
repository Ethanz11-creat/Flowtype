# M0 证据：模型下载 `Invalid metadata` 根因

- 日期：2026-10-22（采集时间 UTC 13:16）
- 范围：自动下载 `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 失败，错误为
  `failedToDownload("aufklarer/Qwen3-ASR-1.7B-MLX-4bit: Invalid metadata: File metadata must have been retrieved from server")`
- 结论：**根因确认为 H2** —— `swift-transformers` 1.3.2 在 Apple 平台只跟随**相对**重定向，而镜像在这台机器上会针对 `resolve` 路径返回**绝对**重定向（308 → `https://huggingface.co/...`），该重定向响应本身不含 `X-Repo-Commit` / `ETag` / `Content-Length`，于是被拒跳后原样返回，metadata 守卫必然失败。
- 关键放大因素（新发现，本文件第 6 节）：CFNetwork 把这 5 个 `308 Permanent Redirect` **写进了应用自己的 URL 缓存**（`~/Library/Caches/com.flowtype.app/Cache.db`），因此后续每次重试都直接复用这条无头的 308，失败变成确定性、即时、可无限复现。

> 说明：本任务只做诊断，未改动任何产品代码、下载逻辑、配置或模型目录；未删除任何文件。

## 1. 版本与代码路径

```console
$ python3 -c "...pins..."
swift-transformers {'revision': '349a7ce54ccb8ebe4bc10c2022e9806f01adb7c6', 'version': '1.3.2'}
speech-swift      {'revision': '10bcb4648932a8a8d8caa7ee6ef9d866abd95ff8', 'version': '0.0.15'}
```

调用链：

```text
ModelDownloader.downloadPreset
  → QwenASRProvider.loadModel(cacheDir: preset.localDirectory())
  → speech-swift HuggingFaceDownloader.downloadWeights
  → HubApi.snapshot(from:matching:["config.json","*.safetensors","model.safetensors.index.json"])
  → HubApi.httpHead(for:)               // HubApi.swift:478
  → HubApi.getFileMetadata(url:)        // HubApi.swift:1058
  → HubFileDownloader.download           // HubApi.swift:793-799 抛出
```

`sources/flowtype/.../ModelDownloader.swift:58-63` 在下载前 `setenv("HF_ENDPOINT", ...)`；speech-swift 的 `makeHubApi` 用 `HubApi(downloadBase:useOfflineMode:)`（endpoint 传 nil）构造，因此实际主机来自 `HF_ENDPOINT=https://hf-mirror.com`，与日志一致。

守卫（`HubApi.swift:793-799`，swift-transformers 1.3.2）：

```swift
guard let remoteCommitHash = remoteMetadata.commitHash,
    let remoteEtag = remoteMetadata.etag,
    let remoteSize = remoteMetadata.size,
    remoteMetadata.location != ""
else {
    throw EnvironmentError.invalidMetadataError("File metadata must have been retrieved from server")
}
```

`getFileMetadata` 的取值来源（`HubApi.swift:1058-1071`）：`commitHash ← X-Repo-Commit`，`etag ← X-Linked-Etag ?? ETag`，`size ← X-Linked-Size ?? Content-Length`。

Apple 专用重定向策略（`HubApi.swift:1357-1400`，`RedirectDelegate`）：

```swift
// Only allow relative redirects and reject others
if locationUrl.host == nil { /* 重写 path/query 后继续 */ }
...
// For all other cases (non-redirects or absolute redirects), prevent redirect
completionHandler(nil)
```

`completionHandler(nil)` 时 URLSession **不跟随**，把 3xx 响应原样交回，`httpHead` 又允许 `200..<400` 通过，于是这个无头 3xx 直接进入上面的守卫。

## 2. Step 1：模型目录现状

```console
$ MODEL_ROOT="$HOME/Library/Application Support/Flowtype/models/aufklarer"
$ find "$MODEL_ROOT" -maxdepth 3 -type f -print -exec ls -lh {} \;
（无输出）

$ du -sh "$MODEL_ROOT"/*
  0B	/Users/yiheng/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit
```

完整树（含隐藏文件、任意深度）：

```console
$ find "$MODEL_ROOT" -print0 | xargs -0 ls -ldh
drwxr-xr-x@ 3 yiheng  staff    96B Oct 16 00:59 .../Flowtype/models/aufklarer
drwxr-xr-x@ 2 yiheng  staff    64B Oct 16 00:59 .../Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit

$ find "$MODEL_ROOT" -type f
（无输出，文件数 0）
```

- 1.7B 目录存在但**完全为空**：0 个文件、0 字节，**不存在 `.metadata`**。
- `Qwen3-ASR-0.6B-MLX-4bit` 在 `Application Support` 下**不存在**；旧缓存根 `~/Library/Caches/qwen3-speech/models/aufklarer/` 也**已不存在**（历史日志里的 offline 加载路径已失效）。
- 该空目录由 `ModelDownloader.swift:66` 的 `createDirectory` 在下载前创建，是**结果**而非原因。

## 3. Step 2：官方 vs 镜像的 HEAD 预检

### 3.1 `huggingface.co`：不可达

```console
$ curl -sSIL --max-time 20 https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json
curl: (28) Connection timed out after 20004 milliseconds

$ curl -sSIL --max-time 20 https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit/resolve/main/config.json
curl: (28) Connection timed out after 20006 milliseconds
```

两个仓库均 20s 超时，无任何响应头。官方源在这台机器上不可用。

### 3.2 `hf-mirror.com`：`config.json` 所需头齐全

```console
$ curl -sSIL --max-time 20 https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json
HTTP/2 307
location: /api/resolve-cache/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6/config.json?...
x-linked-etag: "1d6061abf64da4f302b8c1024a68fb1537852a5c"
x-repo-commit: d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6
content-length: 270
HTTP/2 200
etag: "1d6061abf64da4f302b8c1024a68fb1537852a5c"
x-repo-commit: d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6
content-length: 560
```

（0.6B 同形：307 → `/api/resolve-cache/.../bc441bd1.../config.json`，`x-linked-etag: "049989ad..."`，200 时 `content-length: 7187`。）

### 3.3 逐文件 HEAD（1.7B，镜像）

`snapshot` 的 glob 为 `config.json`、`*.safetensors`、`model.safetensors.index.json`，仓库实际 7 个文件：

```text
.gitattributes  README.md  config.json  merges.txt  model.safetensors  tokenizer_config.json  vocab.json
```

| 文件 | 首跳 | 首跳 Location | `X-Repo-Commit` | `X-Linked-Etag`/`ETag` | `X-Linked-Size`/`Content-Length` |
|---|---|---|---|---|---|
| `config.json` | 307 | **相对** `/api/resolve-cache/...` | 有 | 有 | 有（270） |
| `merges.txt` | 307 | 相对 | 有 | 有 | 有（268） |
| `vocab.json` | 307 | 相对 | 有 | 有 | 有（268） |
| `tokenizer_config.json` | 307 | 相对 | 有 | 有 | 有（290） |
| `model.safetensors` | **302** | **绝对** `https://cas-bridge.xethub.hf.co/...` | 有 | 有 | 有（`x-linked-size: 2225411512`） |
| `model.safetensors.index.json` | 404 | — | 有 | `x-error-code: EntryNotFound` | 15 |

结论（curl 视角）：镜像的 307 路径**没有缺头**；LFS 文件走绝对 302，但其首跳**仍带** `x-repo-commit` / `x-linked-etag` / `x-linked-size`，单独不会触发守卫失败。

## 4. Step 3：revision 列表端点

```console
$ for host in https://huggingface.co https://hf-mirror.com; do
    curl -sS --max-time 20 -o /dev/null -w '%{http_code}\n' \
      "$host/api/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/revision/main"
  done
https://huggingface.co   → curl: (28) Connection timed out after 20002 ms → 000
https://hf-mirror.com    → 200
```

镜像返回的 JSON 含 `sha = d4f9fa3bb45489219f0fcbec671c92d9c1a68fb6` 与 7 个 `siblings`，仓库存在且可枚举。

## 5. Step 4：应用侧日志

```console
$ rg -n "ModelProvision|HF_ENDPOINT|metadata" ~/Library/Logs/flowtype/diagnostic.log | tail -n 24
[2026-10-22T10:38:13] [ModelProvision] HF_ENDPOINT=https://hf-mirror.com
[2026-10-22T10:38:13] [QwenASR] Loading model: aufklarer/Qwen3-ASR-1.7B-MLX-4bit offline=false cacheDir=/Users/yiheng/Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit
[2026-10-22T10:38:36] [ModelProvision] Download attempt 1 failed: failedToDownload("aufklarer/Qwen3-ASR-1.7B-MLX-4bit: Invalid metadata: File metadata must have been retrieved from server")
[2026-10-22T12:53:43] [ModelProvision] Download attempt 1 failed: ...
[2026-10-22T12:54:16] [ModelProvision] Download attempt 2 failed: ...
[2026-10-22T12:54:57] [ModelProvision] Download attempt 3 failed: ...
[2026-10-22T12:55:30] [ModelProvision] Download attempt 1 failed: ...
[2026-10-22T12:56:03] [ModelProvision] Download attempt 2 failed: ...
[2026-10-22T12:56:45] [ModelProvision] Download attempt 3 failed: ...
```

- 6 次应用层尝试 × 每次 speech-swift 内部 3 次 snapshot 重试（间隔 0/5/15s）**全部**失败。
- 每次失败耗时约 21–22s，等于内部 sleep 之和（5+15）加**亚秒级**的失败，说明 HEAD 很快返回了坏响应，**不是网络超时**。
- 失败发生在 `config.json` 阶段之前或之上（`model.safetensors` 从未落盘），与 0B 目录一致。

## 6. 关键发现：应用 URL 缓存里被写入了 5 条 `308 Permanent Redirect`

应用用 `URLSession(configuration: .default)` 发 HEAD（`HubApi.swift:1418-1419`），默认走 `URLCache.shared`。只读拷贝 `Cache.db` 后查询：

```console
$ sqlite3 Cache.db "SELECT request_key, time_stamp FROM cfurl_cache_response WHERE request_key LIKE '%hf-mirror%resolve%'"
.../resolve/main/tokenizer_config.json | 2026-10-22 10:37:16
.../resolve/main/model.safetensors    | 2026-10-22 10:38:15
.../resolve/main/vocab.json           | 2026-10-22 10:38:36
.../resolve/main/config.json          | 2026-10-22 10:38:47
.../resolve/main/merges.txt           | 2026-10-22 10:38:53

$ sqlite3 Cache.db "SELECT receiver_data FROM ..."   # 每条都是
308PermRedirect
```

- 这 5 条缓存条目的时间戳正好落在**首次失败窗口**（日志 10:37–10:38），响应体为 `308PermRedirect`。
- 缓存条目里**没有** `x-repo-commit` / `etag` / `content-length`，也没有可用的 `Location`。
- 308 属永久重定向、默认可缓存；CFNetwork 命中后不再回源，于是 `httpHead` 每次拿到的都是这条无头 308 → 守卫每次失败。
- 这解释了「镜像现在用 curl 看是正常的（307 + 全头），应用却仍然每次都失败」这一表面矛盾。

对照实测（同一台机器、同一 URL、同一 URLSession 栈）：

```text
curl（不经系统代理）      → HTTP/2 307，首跳相对 Location，元数据齐全
URLSession（走系统代理）  → HTTP/2 308，绝对 Location https://huggingface.co/...，无任何元数据
```

复现脚本（`/tmp` 中临时诊断程序，未进入仓库）按 `HubApi.httpHead` 的语义实现后，多次得到：

```text
status = 308
final url = https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json
  X-Repo-Commit = <MISSING>
  ETag          = <MISSING>
  X-Linked-Etag = <MISSING>
  Content-Length= <MISSING>
  X-Linked-Size = <MISSING>
  Location      = https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json
  => guard would FAIL
```

（同环境下也观察到 307 → 200 的成功序列，说明镜像/链路在 307 与 308 之间不稳定。）

## 7. 假设逐条判定

### H1：镜像 HEAD 响应缺少 `X-Repo-Commit` / `ETag` / `Content-Length` —— **部分成立（仅限 308 变体）**

- 正常的 307 路径：4 个必需字段**全部存在**（第 3.2、3.3 节）。就「镜像普遍不回这些头」而言，**不成立**。
- 308 变体（应来自镜像的 Caddy 回源分支）：只有 `Location`，四个字段**全部缺失**（第 6 节）。此时 H1 的描述成立，但它只是 H2 的表现，不是独立原因。

### H2：Apple 平台只允许相对重定向，`resolve` 的绝对跳转导致元数据丢失 —— **确认**

- 代码侧确认：`RedirectDelegate` 对 `locationUrl.host != nil` 一律 `completionHandler(nil)`，绝对跳转被拒（`HubApi.swift:1357-1400`）。
- 服务侧确认：`resolve` 确实会给出**绝对** Location —— 308 → `https://huggingface.co/...`（第 6 节），LFS 302 → `https://cas-bridge.xethub.hf.co/...`（第 3.3 节）。
- 失败链路确认：拒跳后 3xx 原样返回且无元数据 → `getFileMetadata` 的 `commitHash/etag/size` 为 nil → `HubApi.swift:793-799` 抛出与日志完全一致的文案。
- 注意：LFS 的绝对 302 **不**单独致命（其首跳带 `x-linked-etag`/`x-linked-size`/`x-repo-commit`，且 `getFileMetadata` 对 302 专门读 `Location`）。真正致命的是 **308 → huggingface.co**，且它在本机还是死路（`huggingface.co` 20s 超时）。

### H3：目标目录有 0B / 半成品文件或过期 `.metadata` —— **不成立（就模型目录而言）**

- `models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 是**全空目录**，无半成品、无 `.metadata`，不存在「本地与远端 commit 不一致」的对象。
- 目录为空是下载从未成功的**结果**，不是失败原因。
- **但存在同类的本地脏状态**，位置不是模型目录而是 HTTP 缓存：`~/Library/Caches/com.flowtype.app/Cache.db` 内的 5 条 308 条目（第 6 节）。这是本任务新增的结论，H3 的原始表述未覆盖。
- 需要清理的确切对象（**本任务未删除**）：`~/Library/Caches/com.flowtype.app/Cache.db`（及其 `-wal` / `-shm`）。模型目录本身无需清理。

### H4：1.7B 的 repoId 或目标目录与真实仓库不符 —— **不成立**

- `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 在镜像上存在：revision 端点 200，`sha=d4f9fa3b...`，7 个 siblings（第 4 节）；`config.json` 200（560 B）。
- 目标目录与 Hub 布局一致：`ModelPreset.localDirectory()` → `<AppSupport>/Flowtype/models/<org>/<model>`；speech-swift 由该路径反推 `downloadBase=<AppSupport>/Flowtype/models`，再拼出 `models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit`，与实际路径吻合。
- 日志中的 repoId 与目录与仓库真实值完全对应，无拼写/大小写偏差。

## 8. 仍未确定的部分

1. **镜像何时给 307、何时给 308 未能隔离。** 同一 URL、同一客户端栈、相隔数秒，既观察到 307+相对跳转，也观察到 308+绝对跳转；curl（不走系统代理）稳定拿到 307，URLSession（走系统代理）曾稳定拿到 308。本机存在系统级 HTTP/HTTPS 代理 `127.0.0.1:15732`，URLSession 明确经它出网（task metrics `remote=127.0.0.1:15732`），curl 在无 `http_proxy` 环境变量时直连。究竟是代理线路选择、CDN 节点差异还是镜像自身的回源策略，属于外部环境，未能在本次诊断内定论。
2. **308 是「一次性污染 + 缓存固化」还是「持续回源」。** 缓存时间戳证明首次失败窗口内确实写入过 308；但无法从现有日志区分 12:53–12:56 的连续失败中有多少次是缓存命中、多少次是再次拿到 308（应用未记录响应状态码）。
3. **`huggingface.co` 不可达是代理策略还是本地网络。** 本任务只确认 20s 超时，未追查原因。

## 9. 对 M2 的直接含义（不在本任务实施）

- 预检不能只看「端点可达」。需要校验 `resolve` 的 HEAD **最终**状态与四个元数据字段，且必须区分「相对跳转」与「绝对跳转」——当前实现只看 HTTP 层可达性。
- 预检应显式**忽略 URL 缓存**（或直接不复用 `URLCache.shared`），否则一条历史 308 会让预检永远失败或永远通过，取决于缓存里存的是哪一条。
- 任何「清缓存后重试」的修复都必须同时处理 `~/Library/Caches/com.flowtype.app/Cache.db`，只清模型目录无效。
- 镜像的绝对重定向是结构性问题：即使修好缓存，`resolve` 一旦再次给出 308 → `huggingface.co`，而官方域在本机不可达，下载仍会失败。

## 10. 复现命令汇总

```bash
# 本地目录
find "$HOME/Library/Application Support/Flowtype/models/aufklarer" -type f -print -exec ls -lh {} \;

# 端点预检
curl -sSIL --max-time 20 "https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json"
curl -sS  -o /dev/null -w '%{http_code}\n' --max-time 20 \
  "https://hf-mirror.com/api/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/revision/main"

# 只读检查应用 URL 缓存（先拷贝，勿直接改原库）
cp ~/Library/Caches/com.flowtype.app/Cache.db /tmp/Cache.db
sqlite3 /tmp/Cache.db "SELECT request_key, time_stamp FROM cfurl_cache_response \
  WHERE request_key LIKE '%hf-mirror%resolve%';"
```
