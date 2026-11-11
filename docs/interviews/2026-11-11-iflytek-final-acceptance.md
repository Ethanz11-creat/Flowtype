# 面试前最后三项真人验收

自动实验已经完成。本页用于完成尚缺的人工事实，不追加模型、数据或云端纠错请求。当前三项仍为 `manual_pending`。

## 1. 麦克风 → TextEdit（约 3 分钟）

打开空白 TextEdit 文档，使用当前 FlowType 的既有录音快捷键，逐次口述、停止并核对实际文字。无需切换长期模型设置。

| 类型 | 建议口述 | 实际文字与记录 |
|---|---|---|
| short | 今天下午三点开会。 | 操作后填写，不提前写“通过” |
| mixed | 这个 API 的 timeout 设成三十秒，不要自动 retry。 | 检查语言、数字、否定词是否保留 |
| technical | 我用 PyTorch 加载 Qwen 模型，然后检查 Hugging Face 的配置文件。 | 保留真实错误，不靠手工改字掩盖 |

复制 `tools/interview_bench/configs/manual-demonstrations.template.json` 到 `build/interview-bench/manual-demonstrations.json`。每条实际完成后记录观察者、带时区时间、说出文本和 TextEdit 中实际文字，并填写 `confirmed_inserted`。这个字段确认“真的落字”，不表示识别零错误；误识别照样写进实际文字。三条都实际完成后才把 microphone.status 设为 confirmed。只有发送事件或胶囊提示不能代替落字观察。

## 2. 36 条音频试听

打开本机 `build/interview-bench/replay-prepared/annotate.html`。每条音频实际听完后，填写全部语音区间（秒）、标注者并勾选确认；未听的保持 pending。包含轻声、短词和句中停顿，不把拼接静音当真实语音边界。

导出 JSON 后执行：

```sh
build/interview-bench/.venv/bin/python -m tools.interview_bench replay \
  --root build/interview-bench --import-annotations /absolute/path/annotations.json
```

导入后需新建回放批次，旧批次的标注和端点字段保持冻结。先检查标注与来源对应，再决定新回放；本页不自动启动 ASR。本轮 full 需要36条，compact只需要eval的24条来源，不能用compact包装full验收。

## 3. 60–90 秒真实回放录制

打开 [新版 eval 回放目录](../evidence/iflytek-interview/2026-11-11-four-modules/replay-player/eval/index.html)。音频从本机 ignored build 读取；其他机器需先按工具 README 准备原始音频。

只录制浏览器演示区域，建议约75秒：

| 时间 | 操作与讲述 |
|---|---|
| 0–15秒 | 展示目录，说明是固定公开音频与实际事件回放，非麦克风实时落字、非token streaming |
| 15–40秒 | 播放一条vad600会话，展示文字按已记录的返回时间出现；暂停后文字不再推进 |
| 40–60秒 | 拖回开头重播，或展示倍速；音频结束后可单独暂停/继续等待结果 |
| 60–75秒 | 展示整段与分段的准确率取舍，主动说明人工边界和产品演示的完成状态 |

保存真实媒体文件，计算SHA256，并在人工记录的 replay_recording 中填写路径、观察者和哈希。实际看过录制、确认内容与长度后才设为 confirmed。截图、合成幻灯片、CLI事件和浏览器自动化检查均不能冒充真人录屏。

## 最后核验

```sh
build/interview-bench/.venv/bin/python -m tools.interview_bench verify \
  --root build/interview-bench --profile full
```

音频边界、媒体和落字记录必须对应真实操作；还有缺项时继续保留 partial。已有真实识别错误和纠错退化不需要为“过关”刷模型或提示。
