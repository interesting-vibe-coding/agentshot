# AgentShot

The screenshot tool built for AI coding agents. Snip a region and it's auto-compressed to the vision model's optimal size, then copied to your clipboard.

**Why it matters for Claude Code and Codex:** Neither tool resizes images before sending them to the model. A full-screen grab goes straight to the API at full resolution — every pixel costs tokens. AgentShot caps the long edge at 1568px, compresses to JPEG, and ensures output is ≤ ⅓ the original size. For a typical 3024×1964 Retina screenshot: **7918 → 2128 image tokens (−73%)**, per Claude's formula `tokens = width × height / 750`.

[中文](README.zh.md)

<img src="assets/before-after.png" width="100%">

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/interesting-vibe-coding/agentshot/main/install.sh | bash
```

Installs to `/Applications` and launches. Grant Accessibility permission once in the onboarding screen. The first capture asks for Screen Recording — allow it, then reopen AgentShot.

## Usage

Press `⌘⇧2` to start. Click once for full screen, or drag to select a region. A preview appears:

- `C` / `↩` — copy the compressed image (label shows `original KB → compressed KB`)
- `⇧C` — copy the original
- `Esc` — cancel

Paste into Claude Code, Codex, or any vision-capable agent. Shortcut, quality tier, and launch-at-login live in the menubar (📸).

## How it works

`tokens ≈ width × height / 750` (Anthropic's formula). Claude Code and Codex send images at full resolution — AgentShot intercepts before they reach the clipboard. The pipeline: downscale to ≤1568px long edge → JPEG encode at q0.82 → enforce ≤⅓ original size → hard cap at 1000 KB. Reading accuracy is unaffected (see [benchmarks](bench/RESULTS.md)).

---

Homepage & benchmarks: **https://interesting-vibe-coding.github.io/agentshot-site/** · MIT License · part of [interesting-vibe-coding](https://github.com/interesting-vibe-coding)
