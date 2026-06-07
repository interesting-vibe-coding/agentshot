# AgentShot

AI 编码 Agent 专用截图工具。框选区域，自动压缩到视觉模型最优尺寸，写入剪贴板。

**为什么对 Claude Code 和 Codex 有用：** 两款工具在发送图片给模型前都不做 resize，全屏截图会按原始分辨率计 token。AgentShot 将长边压到 1568px 并确保输出大小 ≤ 原图 ⅓。以典型 3024×1964 Retina 截图为例：**7918 → 2128 图片 token（节省 73%）**，依据 Claude 官方公式 `token = 宽 × 高 / 750`。

[English](README.md)

<img src="assets/before-after.png" width="100%">

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/interesting-vibe-coding/agentshot/main/install.sh | bash
```

安装到 `/Applications` 并启动。在引导界面授权辅助功能一次。首次截图时系统会要求屏幕录制权限，允许后重新打开 AgentShot 即可。

## 使用

按 `⌘⇧2` 启动。单击截全屏，或拖拽选择区域。预览窗出现后：

- `C` / `↩` — 复制压缩图（标注显示 `原始 KB → 压缩 KB`）
- `⇧C` — 复制原图
- `Esc` — 取消

粘贴到 Claude Code、Codex 或任何支持视觉的 Agent。快捷键、质量档位、开机自启在菜单栏（📸）设置。

## 原理

`token ≈ 宽 × 高 / 750`（Anthropic 官方公式）。Claude Code 和 Codex 以原始分辨率发送图片——AgentShot 在写入剪贴板前完成压缩。流程：长边降采样到 ≤1568px → JPEG q0.82 编码 → 确保输出 ≤ 原图 ⅓ → 硬上限 1000KB。阅读精度不受影响（详见 [benchmark 结果](bench/RESULTS.md)）。

---

主页与 benchmark：**https://interesting-vibe-coding.github.io/agentshot-site/** · MIT License · [interesting-vibe-coding](https://github.com/interesting-vibe-coding)
