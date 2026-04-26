# ASR 评测数据集

## 使用说明

### 1. 生成合成样本（快速验证框架）

```bash
cd tools/eval_data
python generate_samples.py
```

这会使用 macOS `say` 命令生成 25 条合成中文语音。注意：
- 需要 macOS 系统
- 需要安装中文语音（Ting-Ting、Mei-Jia 等）
- 合成语音质量有限，主要用于验证评测框架能跑通

### 2. 使用真实录音（推荐）

用 langstream 应用或其他录音工具录制真实语音样本：
1. 录音格式：16kHz, mono, 16-bit PCM WAV
2. 将录音文件放入 `samples/` 目录
3. 在 `manifest.json` 中添加对应条目：
   ```json
   {"id": "my_01", "audio": "samples/my_01.wav", "ground_truth": "你的参考文本"}
   ```

### 3. 运行评测

```bash
cd tools
pip install requests python-Levenshtein
python evaluate_asr.py
```

评测脚本会：
1. 读取 `eval_data/manifest.json`
2. 对每条样本调用 TeleSpeech 和 SenseVoice
3. 计算 CER（字符错误率）
4. 生成 JSON 结果和 Markdown 报告到 `eval_output/`

### 4. 评测覆盖场景

当前 25 条样本覆盖：
- 普通中文短句（01-03）
- 长句（04-05）
- 口语化表达（06-07）
- 含 filler 词（08-09）
- AI coding 指令（10-11）
- 英文技术词混合（12-13）
- 中英混合（14-15）
- 专业术语（16-19）
- 代码词（20-22）
- 专业词（23-25）

### 5. 查看结果

评测完成后，查看 `eval_output/report_YYYYMMDD_HHMMSS.md`：
- 总体 CER 对比
- 每条样本的识别结果和错误类型
- 错误模式统计（截断、漏字、术语错误、filler 残留等）
