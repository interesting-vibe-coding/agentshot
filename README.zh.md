# AgentShot

为 Codex 和 GPT 视觉 Agent 打造的截图工具。框选区域，自动压缩到视觉模型最优尺寸，写入剪贴板。

**为什么对 Codex 有用：** OpenAI 按图片像素尺寸分块计费，一张全屏 Retina 截图还没被模型看就烧掉几千 token。AgentShot 把长边压到 1568px 并 JPEG 编码，让你不再为模型用不到的像素付费。

**实测，非理论** —— 同一张截图，真实 OpenRouter API 调用（`bench/run_openrouter_tokens.py`）：

| 模型 | 原图 (757 KB, 3024×1964) | AgentShot (174 KB, 1568×1018) | 节省 |
|------|------|------|------|
| **GPT-5.5** | 7083 input tokens | 1896 input tokens | **−73%** |

[English](README.md)

<img src="assets/before-after.png" width="100%">

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/interesting-vibe-coding/agentshot/main/install.sh | bash
```

安装到 `/Applications` 并启动。引导界面授权辅助功能一次。首次截图时系统要求屏幕录制权限，允许后重新打开即可。

## 使用

按 `⌘⇧2` 启动。单击截全屏，或拖拽选区。预览窗出现后：

- `C` / `↩` — 复制压缩图（标注显示 `原始 KB → 压缩 KB`）
- `⇧C` — 复制原图
- `Esc` — 取消

粘贴到 Codex 或任何按图片分辨率计费的模型。快捷键、质量档位、开机自启在菜单栏（📸）设置。

## 原理

OpenAI 按像素面积（分块）计费。AgentShot 流程：长边降采样到 ≤1568px → JPEG q0.82 → 确保输出 ≤ 原图 ⅓ → 硬上限 1000KB。阅读精度不受影响，只降 token 数（[benchmark](bench/RESULTS.md)）。

> **关于 Claude：** Anthropic 在服务端归一化图片后再计费，所以无论你发多大的图，Claude 的 token 成本都是固定的——AgentShot 在 Claude 上省不了 token。真正有效的是按分辨率计费的模型（GPT/Codex）。

---

主页与 benchmark：**https://interesting-vibe-coding.github.io/agentshot-site/** · MIT License · [interesting-vibe-coding](https://github.com/interesting-vibe-coding)
