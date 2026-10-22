# M0 证据：模型下载 `Invalid metadata` 根因

- 日期：2026-10-22（采集窗口 UTC 13:10–13:25；逐条时间戳见 §6.1 与 §10 时间线）
- 范围：自动下载 `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 失败，错误为
  `failedToDownload("aufklarer/Qwen3-ASR-1.7B-MLX-4bit: Invalid metadata: File metadata must have been retrieved from server")`
- 结论：**根因确认为 H2** —— `swift-transformers` 1.3.2 在 Apple 平台只跟随**相对**重定向，而镜像对**应用所用的 CFNetwork 栈**会在 `resolve` 路径返回**绝对**重定向（308 → `https://huggingface.co/...`），该重定向响应本身不含 `X-Repo-Commit` / `ETag` / `Content-Length`。一旦收到这种响应，被拒跳后它被原样返回，metadata 守卫必然失败。
  该现象已可稳定复现（§6.1，2026-10-22T13:24:14Z 同秒对照：CFNetwork 308/无元数据，curl 307/元数据齐全），且**与本机系统代理无关**——绕过代理后 CFNetwork 仍 6/6 拿到 308。
- 已**观测到**的事实（本文件第 6 节）：应用自己的 URL 缓存 `~/Library/Caches/com.flowtype.app/Cache.db` 中存在 5 条 `308 Permanent Redirect` 条目，时间戳与首次失败窗口吻合。
- 由上述事实推出的**推断**（未直接验证，见 §8.2）：默认缓存策略会复用这些无头 308，从而使失败在 12:53–12:56 的连续重试中保持确定性。本文件凡属此推断均已标注「推断」，不作为已证事实陈述。

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

结论（**curl 视角**）：镜像的 307 路径**没有缺头**；LFS 文件走绝对 302，但其首跳**仍带** `x-repo-commit` / `x-linked-etag` / `x-linked-size`，单独不会触发守卫失败。

> 重要限定：上表是 curl 看到的行为，**不代表应用**。用与应用相同的 CFNetwork 栈发同一批 HEAD 时，`config.json` 与 `model.safetensors` 都得到 `308 server=Caddy` + 绝对 Location 到 `huggingface.co` + 无任何元数据（§6.1）。所以「curl 检查一切正常」并不能证明应用侧正常——这正是本问题最容易被误判的地方。

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

- **观测（事实）**：这 5 条缓存条目的时间戳正好落在**首次失败窗口**（日志 10:37–10:38），响应体为 `308PermRedirect`。
- **观测（事实）**：缓存条目里**没有** `x-repo-commit` / `etag` / `content-length`，也没有可用的 `Location`。
- **推断（未直接验证）**：308 属永久重定向、默认可缓存；`HubApi.httpHead` 使用 `URLSessionConfiguration.default`（`HubApi.swift:1418-1419`），默认走 `URLCache.shared` 与 protocol cache policy，因此命中后不再回源，`httpHead` 会反复拿到这条无头 308 → 守卫反复失败。
  该推断**只有缓存条目这一间接证据**：应用不记录 HEAD 的响应状态码，无法从日志区分「缓存命中」与「再次从网络收到 308」。详见 §8.2。
- **推断**：若上述缓存复现成立，即可解释「镜像现在用 curl 看是正常的（307 + 全头），应用却仍然每次都失败」这一表面矛盾。该解释未获直接验证，同见 §8.2。

### 6.1 可直接复现的 308 观测

观测时间均为 UTC。探针源码（33 行，未进入仓库，可原样重建；已用文档中的这段源码原样编译验证，见 §10）：

```swift
// save as /tmp/ft_hubprobe/main.swift
import Foundation
// Replicates HubApi.httpHead + getFileMetadata decision (swift-transformers 1.3.2).
final class RelativeOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard (300...399).contains(r.statusCode),
              let loc = r.value(forHTTPHeaderField: "Location"),
              let u = URL(string: loc), u.host == nil,
              let orig = task.originalRequest?.url,
              var c = URLComponents(url: orig, resolvingAgainstBaseURL: true)
        else { completionHandler(nil); return }          // absolute redirect => refuse, like HubApi
        c.path = u.path; c.query = u.query
        completionHandler(c.url.map { URLRequest(url: $0) })
    }
}
let url = URL(string: CommandLine.arguments[1])!          // arg2: "HEAD"(默认) 或 "GET"
var req = URLRequest(url: url)
req.httpMethod = CommandLine.arguments.contains("GET") ? "GET" : "HEAD"
req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
let cfg = URLSessionConfiguration.default
if CommandLine.arguments.contains("bypass") { cfg.connectionProxyDictionary = [:] }  // 绕过系统代理
let s = URLSession(configuration: cfg, delegate: RelativeOnly(), delegateQueue: nil)
let (_, resp) = try await s.data(for: req)
let h = resp as! HTTPURLResponse
let commit = h.value(forHTTPHeaderField: "X-Repo-Commit")
let etag = h.value(forHTTPHeaderField: "X-Linked-Etag") ?? h.value(forHTTPHeaderField: "ETag")
let size = h.value(forHTTPHeaderField: "X-Linked-Size") ?? h.value(forHTTPHeaderField: "Content-Length") ?? ""
let loc = h.statusCode == 302 ? (h.value(forHTTPHeaderField: "Location") ?? "") : (h.url?.absoluteString ?? "")
let pass = commit != nil && etag != nil && Int(size) != nil && !loc.isEmpty
print("\(ISO8601DateFormatter().string(from: Date())) status=\(h.statusCode) server=\(h.value(forHTTPHeaderField: "Server") ?? "-") commit=\(commit ?? "MISSING") etag=\(etag ?? "MISSING") size=\(size.isEmpty ? "MISSING" : size) guard=\(pass ? "PASS" : "FAIL")")
print("    finalURL=\(h.url?.absoluteString ?? "nil")")
print("    Location=\(h.value(forHTTPHeaderField: "Location") ?? "-")")
```

```console
$ swiftc -O -o /tmp/ft_hubprobe/probe /tmp/ft_hubprobe/main.swift
$ U="https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json"
$ /tmp/ft_hubprobe/probe "$U" HEAD
```

**观测到的 308（UTC 2026-10-22T13:21:45Z–13:21:46Z，连续 6 次全部相同）**：

```text
2026-10-22T13:21:45Z status=308 server=Caddy commit=MISSING etag=MISSING size=MISSING guard=FAIL
    finalURL=https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json
    Location=https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json
（另外 5 次同形，时间戳 13:21:45Z–13:21:46Z）
```

**同一时刻的对照**：

```console
$ # curl 直连（无 http_proxy 环境变量，见下方环境说明）
2026-10-22T13:21:46Z HTTP/2 307  server: hf-mirror
2026-10-22T13:21:46Z HTTP/2 307  server: hf-mirror
2026-10-22T13:21:46Z HTTP/2 307  server: hf-mirror
```

**同一探针在不同时刻的结论（308 并非始终出现）**：

```text
13:21:45Z–13:21:46Z  探针（URLSession，默认配置）              6/6 → 308  server=Caddy      guard=FAIL
13:21:55Z–13:21:57Z  探针（默认配置，走系统代理）               2/3 → 308，1/3 → 200
13:21:57Z–13:21:59Z  探针（connectionProxyDictionary=[] 直连）  3/3 → 200  server=cloudflare  guard=PASS
13:22:0xZ            探针（默认配置）×10 /（直连）×10          20/20 → 200 server=cloudflare
13:22:58Z            探针（默认配置）                           3/3 → 308  server=Caddy      guard=FAIL
13:23:03Z–13:23:08Z  代理 / 直连 / curl 交错 ×4 轮              代理 4/4 → 200；直连 4/4 → 200；curl 4/4 → 307
13:23:42Z            文档内联探针（§6.1 源码原样编译）           3/3 → 308  server=Caddy      guard=FAIL
13:23:54Z–13:23:59Z  代理 / 直连 交错 ×6 轮                     两者 6/6 → 308  ← 代理已被排除
13:24:14Z            同一秒三方对照（见下）                     CFNetwork 代理 308 / CFNetwork 直连 308 / curl 307
```

同一秒的三方对照（13:24:14Z，同一 URL）：

```text
CFNetwork 走系统代理   → status=308 server=Caddy     commit=MISSING
CFNetwork 绕过代理直连 → status=308 server=Caddy     commit=MISSING   （remote=160.16.86.14:443）
curl 直连              → HTTP/2 307 server=hf-mirror  location=/api/resolve-cache/...  元数据齐全
```

- **代理不是原因**：13:23:54Z–13:23:59Z 的 6 轮交错中，走代理与绕过代理**同样** 6/6 拿到 308；13:24:14Z 同秒对照也显示两者一致。此前 13:21:55Z–13:23:08Z 观察到的「代理 308、直连 200」是短暂波动，不能作为因果证据。
- **区分因素是 HTTP 客户端栈**：同一秒、同一目标 IP，CFNetwork（即应用所用栈）拿到 `308 server=Caddy` + 绝对 Location 到 `huggingface.co`，curl 拿到 `307 server=hf-mirror` + 相对 Location + 完整元数据。镜像侧按客户端特征分流到不同后端，这属于外部环境。
- 该 308 并非始终出现：13:22:0xZ 曾有 20/20 返回 200；但 13:23:42Z 起连续观测（13:23:42Z、13:23:46Z、13:23:54Z–59Z、13:24:14Z、13:25:43Z–44Z）对 CFNetwork **再无一次 200**。应用一次下载尝试只需命中一次 308 即可失败。
- LFS 文件同样受影响：`model.safetensors` 对 CFNetwork 返回 `308 server=Caddy commit=MISSING`（curl 直连则为 302 → `cas-bridge.xethub.hf.co`，带 `x-linked-size`）。
- 与 HTTP 方法无关：13:25:44Z 用 `GET`（而非 HEAD）发同一请求，CFNetwork 仍得到 `308 server=Caddy commit=MISSING`，说明镜像对这条链路整体返回 308，而不是只对 HEAD 特殊处理。

环境（复现所需）：

```console
$ scutil --proxy
  HTTPEnable : 1   HTTPPort : 15732   HTTPProxy : 127.0.0.1
  HTTPSEnable : 1  HTTPSPort : 15732  HTTPSProxy : 127.0.0.1
$ echo "http_proxy=${http_proxy:-none} https_proxy=${https_proxy:-none}"
http_proxy=none https_proxy=none
```

URLSession 默认读取系统代理（task metrics：`remote=127.0.0.1:15732`），curl 在没有 `*_proxy` 环境变量时直连。但 13:23:54Z 起的交错复测证明**代理不是决定因素**：把 `connectionProxyDictionary` 置空后，URLSession 直连（`remote=160.16.86.14:443`）仍 6/6 拿到 308。真正稳定的差别是 **CFNetwork 与 curl 这两套客户端栈**（见 §7 H2）。

## 7. 假设逐条判定

### H1：镜像 HEAD 响应缺少 `X-Repo-Commit` / `ETag` / `Content-Length` —— **部分成立（仅限 308 变体）**

- 正常的 307 路径：4 个必需字段**全部存在**（第 3.2、3.3 节）。就「镜像普遍不回这些头」而言，**不成立**。
- 308 变体（`server: Caddy`，对 CFNetwork 栈稳定出现）：只有 `Location`，四个字段**全部缺失**（§6.1）。此时 H1 的描述成立，但它只是 H2 的表现，不是独立原因——头之所以缺，是因为返回的是那条绝对跳转响应，而不是镜像「普遍不回头」。

### H2：Apple 平台只允许相对重定向，`resolve` 的绝对跳转导致元数据丢失 —— **确认**

- 代码侧确认：`RedirectDelegate` 对 `locationUrl.host != nil` 一律 `completionHandler(nil)`，绝对跳转被拒（`HubApi.swift:1357-1400`）。
- 服务侧确认（关键）：对**应用所用的 CFNetwork 栈**，`resolve` 的 HEAD 会返回 `308` + **绝对** `Location: https://huggingface.co/...` + **零元数据**（§6.1，13:24:14Z 同秒对照，走代理与直连皆然）。同一秒的 curl 则得到 307 + 相对 Location + 完整元数据。
- 失败链路确认：拒跳后 3xx 原样返回且无元数据 → `getFileMetadata` 的 `commitHash/etag/size` 为 nil → `HubApi.swift:793-799` 抛出与日志完全一致的文案。探针按该逻辑判定 `guard=FAIL`，与日志文案一一对应。
- 补充：LFS 的绝对 302（curl 视角）**不**单独致命，因为其首跳仍带 `x-linked-etag`/`x-linked-size`/`x-repo-commit`，且 `getFileMetadata` 对 302 专门读 `Location`。但对 CFNetwork 栈，LFS 文件同样拿到 308 而非 302，因此同样致命。
- 即：**这是可稳定触发的客户端相关问题，不是罕见的网络抖动。** 复现方法与源码见 §6.1。

### H3：目标目录有 0B / 半成品文件或过期 `.metadata` —— **不成立（就模型目录而言）**

- `models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 是**全空目录**，无半成品、无 `.metadata`，不存在「本地与远端 commit 不一致」的对象。
- 目录为空是下载从未成功的**结果**，不是失败原因。
- **但存在同类的本地脏状态**，位置不是模型目录而是 HTTP 缓存：`~/Library/Caches/com.flowtype.app/Cache.db` 内**已观测到** 5 条 308 条目（第 6 节）。这是本任务新增的发现，H3 的原始表述未覆盖；其是否真正导致后续重试失败仍属推断（§8.2）。
- 注意区分：模型目录**无需**清理；需要评估清理的是 HTTP 缓存，二者不是一回事。
- 需要清理的确切对象（**本任务未删除**）：`~/Library/Caches/com.flowtype.app/Cache.db`（及其 `-wal` / `-shm`）。模型目录本身无需清理。

### H4：1.7B 的 repoId 或目标目录与真实仓库不符 —— **不成立**

- `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` 在镜像上存在：revision 端点 200，`sha=d4f9fa3b...`，7 个 siblings（第 4 节）；`config.json` 200（560 B）。
- 目标目录与 Hub 布局一致：`ModelPreset.localDirectory()` → `<AppSupport>/Flowtype/models/<org>/<model>`；speech-swift 由该路径反推 `downloadBase=<AppSupport>/Flowtype/models`，再拼出 `models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit`，与实际路径吻合。
- 日志中的 repoId 与目录与仓库真实值完全对应，无拼写/大小写偏差。

## 8. 仍未确定的部分

1. **308 的上游成因未定论，但已排除本机代理与「偶发网络抖动」。** 已确认：同一秒内 CFNetwork（走代理或直连皆然）稳定拿到 308，而 curl 稳定拿到 307，说明分流发生在服务端、按客户端特征（TLS/HTTP 指纹等）选择后端，属外部环境。仍未确定的是：这 308 由镜像的哪一层产生、为何时有时无（13:22:0xZ 曾 20/20 返回 200）。本任务无法从客户端侧进一步隔离。
2. **缓存复现是推断，不是观测。** 已观测到的只有事实：`Cache.db` 内存在 5 条 `308PermRedirect`，时间戳落在首次失败窗口，且不含任何元数据头。由此推断默认缓存策略会让后续 `httpHead` 复用它们——但应用不记录 HEAD 的响应状态码，无法从日志区分 12:53–12:56 的连续失败中有多少次是缓存命中、多少次是再次从网络收到 308。因此「失败是确定性的」这一说法**只在推断层面成立**，未被直接验证。
3. **`huggingface.co` 不可达是代理策略还是本地网络。** 本任务只确认 20s 超时，未追查原因。
4. **本次观测与历史失败时刻的关系未知。** 本次 308 观测（13:21Z–13:24Z）远晚于应用失败时刻（10:38Z、12:53–12:56Z），无法证明失败当时也处于同一状态。因此「当时就是网络 308」与「当时 308 被缓存后复现」两种解释都仍有可能；§6 的缓存部分按推断处理。

## 9. 对 M2 的直接含义（不在本任务实施）

- 预检必须用**与应用相同的 CFNetwork 栈**发请求，不能以 curl 的结果作为「端点健康」的判据。本次已证明同一秒内两者结论相反（§6.1）。
- 预检需要校验四个元数据字段，并把「3xx + 绝对 Location」判为失败——当前实现只看 HTTP 层可达性（`httpHead` 放行 `200..<400`）。
- 预检应显式**忽略 URL 缓存**（或不复用 `URLCache.shared`），否则预检结果取决于缓存里存的是哪一条历史响应。
- 任何「清缓存后重试」的修复都应评估 `~/Library/Caches/com.flowtype.app/Cache.db`：只清模型目录不会触及第 6 节观测到的 5 条 308 条目。该改动的有效性依赖 §8.2 的推断，实施前宜先做一次「清缓存后复测」验证。
- 镜像的绝对重定向是结构性问题：即使缓存问题解决，只要 CFNetwork 仍拿到 308 → `huggingface.co`（本机不可达），下载就会失败。预检需把这种情况判为「端点不可用」，而不是可自动重试。

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

# 308 观测复现：把 §6.1 的源码存为 /tmp/ft_hubprobe/main.swift
swiftc -O -o /tmp/ft_hubprobe/probe /tmp/ft_hubprobe/main.swift
U="https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-4bit/resolve/main/config.json"
for i in $(seq 6); do /tmp/ft_hubprobe/probe "$U" HEAD; done         # 默认：走系统代理
for i in $(seq 6); do /tmp/ft_hubprobe/probe "$U" HEAD bypass; done  # 绕过系统代理

# 同秒三方对照：CFNetwork(代理) / CFNetwork(直连) / curl(直连)
printf 'cfnetwork proxy : '; /tmp/ft_hubprobe/probe "$U" HEAD | head -1
printf 'cfnetwork direct: '; /tmp/ft_hubprobe/probe "$U" HEAD bypass | head -1
printf 'curl direct     : '; curl -sS -I --max-time 15 --noproxy '*' "$U" | rg -i '^(HTTP/|server:)' | tr '\n' ' '; echo
scutil --proxy   # 说明 URLSession 默认会用到 127.0.0.1:15732
```

观测时间线（UTC）：

| 时间 | 动作 | 结果 |
|---|---|---|
| 10:37:16–10:38:53 | 应用下载（首次失败） | 失败；Cache.db 写入 5 条 308 |
| 12:53:22–12:56:45 | 应用重试 ×2 轮 | 全部失败 |
| 13:16:17 | Step 2/3 端点预检 | 镜像 307 + 全头；官方超时 |
| 13:21:45–13:21:46 | 探针 HEAD ×6 | **6/6** `308 server=Caddy` guard=FAIL |
| 13:21:46 | curl 直连 ×3 | 3/3 `307 server=hf-mirror` |
| 13:21:55–13:21:59 | 探针 代理 ×3 / 直连 ×3 | 308,308,200 / 200,200,200 |
| 13:22:0x | 探针 代理 ×10 / 直连 ×10 | 20/20 `200 server=cloudflare` |
| 13:22:58 | 探针 HEAD ×3 | **3/3** `308 server=Caddy` guard=FAIL |
| 13:23:03–13:23:08 | 代理/直连/curl 交错 ×4 | 代理 4/4 200、直连 4/4 200、curl 4/4 307 |
| 13:23:42 | 文档内联源码原样编译运行 ×3 | **3/3** `308 server=Caddy` guard=FAIL |
| 13:23:54–13:23:59 | 代理/直连 交错 ×6 | 两者 6/6 `308 server=Caddy`（代理被排除） |
| 13:24:14 | 同秒三方对照 | CFNetwork 代理 308 / CFNetwork 直连 308 / curl 307 |
| 13:24:14 | `model.safetensors` | CFNetwork 308 无元数据；curl 302 + `x-linked-size` |
| 13:25:43–13:25:44 | 内联源码 default / bypass / GET | default 308、bypass 308、GET 308（均 guard=FAIL）；curl 307 |
| 13:22:58 后缓存复查 | `Cache.db` 只读拷贝 | 仍为 5 条 308，时间戳未变 |
