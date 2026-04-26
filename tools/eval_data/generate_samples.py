#!/usr/bin/env python3
"""
Generate synthetic Chinese audio samples using macOS `say` command.
Quality is limited; replace with real recordings for serious evaluation.

Requires macOS with Chinese voices installed (Ting-Ting, Mei-Jia, etc.).
Run `say -v '?' | grep zh` to see available Chinese voices.
"""

import subprocess
import json
from pathlib import Path

SAMPLES = [
    {"id": "01_short", "text": "打开设置页面", "voice": "Ting-Ting"},
    {"id": "02_short", "text": "保存当前文件", "voice": "Ting-Ting"},
    {"id": "03_short", "text": "运行单元测试", "voice": "Ting-Ting"},
    {"id": "04_long", "text": "请帮我检查一下这个函数里面是不是有空指针异常的风险", "voice": "Ting-Ting"},
    {"id": "05_long", "text": "我想在这个页面添加一个下拉刷新功能，用 SwiftUI 实现", "voice": "Ting-Ting"},
    {"id": "06_colloquial", "text": "那个帮我看看这个报错是什么意思啊", "voice": "Ting-Ting"},
    {"id": "07_colloquial", "text": "就是我想改一下这里的样式，然后那个按钮颜色也改一下", "voice": "Ting-Ting"},
    {"id": "08_filler", "text": "嗯那个帮我写一个 RAG 的检索模块", "voice": "Ting-Ting"},
    {"id": "09_filler", "text": "然后然后我想用 LangGraph 实现一个 Agent 工作流", "voice": "Ting-Ting"},
    {"id": "10_coding", "text": "定义一个泛型函数，输入数组返回最大值", "voice": "Ting-Ting"},
    {"id": "11_coding", "text": "帮我写一个 Docker Compose 配置文件，包含 Redis 和 PostgreSQL", "voice": "Ting-Ting"},
    {"id": "12_english_tech", "text": "配置一下 Kubernetes 的 Deployment 和 Service", "voice": "Ting-Ting"},
    {"id": "13_english_tech", "text": "用 Tailwind CSS 写一个响应式导航栏", "voice": "Ting-Ting"},
    {"id": "14_mixed", "text": "把这个 Notion 页面的内容同步到 GitHub 仓库", "voice": "Ting-Ting"},
    {"id": "15_mixed", "text": "用 DeepSeek 模型做一个 Prompt 优化工具", "voice": "Ting-Ting"},
    {"id": "16_term", "text": "实现一个 SwiftUI 的 List 组件，支持下拉刷新", "voice": "Ting-Ting"},
    {"id": "17_term", "text": "配置 FastAPI 的 CORS 和路由", "voice": "Ting-Ting"},
    {"id": "18_term", "text": "用 LangChain 连接 OpenAI 的 GPT 接口", "voice": "Ting-Ting"},
    {"id": "19_term", "text": "把 ChatGPT 的回复转成 Claude 的 Prompt 格式", "voice": "Ting-Ting"},
    {"id": "20_code", "text": "创建一个 TypeScript 接口定义用户数据", "voice": "Ting-Ting"},
    {"id": "21_code", "text": "用 Node.js 写一个 Express 中间件", "voice": "Ting-Ting"},
    {"id": "22_code", "text": "写一个 React Hook 处理表单验证", "voice": "Ting-Ting"},
    {"id": "23_professional", "text": "TeleSpeech 和 SenseVoice 的识别准确率对比测试", "voice": "Ting-Ting"},
    {"id": "24_professional", "text": "用 Gradio 和 Streamlit 搭建一个 RAG 演示界面", "voice": "Ting-Ting"},
    {"id": "25_professional", "text": "Agent 和 Prompt Engineering 的最佳实践总结", "voice": "Ting-Ting"},
]


def generate():
    out_dir = Path(__file__).parent / "samples"
    out_dir.mkdir(exist_ok=True)

    manifest = []
    for s in SAMPLES:
        wav_path = out_dir / f"{s['id']}.wav"
        if wav_path.exists():
            print(f"Skipping existing {wav_path}")
            manifest.append({
                "id": s["id"],
                "audio": str(wav_path.relative_to(Path(__file__).parent)),
                "ground_truth": s["text"]
            })
            continue

        aiff_path = out_dir / f"{s['id']}.aiff"
        try:
            subprocess.run(
                ["say", "-v", s["voice"], "-o", str(aiff_path), s["text"]],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            print(f"Failed to generate {s['id']}: {e}")
            print(f"stderr: {e.stderr.decode()}")
            continue

        # Convert to 16kHz mono WAV
        try:
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(aiff_path), str(wav_path)],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            print(f"Failed to convert {s['id']}: {e}")
            continue
        finally:
            if aiff_path.exists():
                aiff_path.unlink()

        manifest.append({
            "id": s["id"],
            "audio": str(wav_path.relative_to(Path(__file__).parent)),
            "ground_truth": s["text"]
        })
        print(f"Generated {wav_path}")

    manifest_path = Path(__file__).parent / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f"Manifest saved to {manifest_path}")


if __name__ == "__main__":
    generate()
