# AgentShot

The screenshot tool built for AI agents. Snip a region and it's auto-compressed to the vision model's optimal size, then copied to your clipboard — up to 81% fewer image tokens, with no loss in reading accuracy.

[中文](README.zh.md)

<img src="assets/before-after.png" width="100%">

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/interesting-vibe-coding/agentshot/main/install.sh | bash
```

Installs to `/Applications` and launches. The first capture asks for Screen Recording permission — allow it, then reopen AgentShot.

## Usage

Press `⌘⇧2` and drag to select a region. A preview appears:

- `C` / `↩` — copy the compressed image
- `⇧C` — copy the original (uncompressed)
- `Esc` — cancel

Then paste into your agent. Shortcut, quality tier, and launch-at-login live in the menubar (📸).

## Why it works

For vision models, image tokens depend on pixel dimensions, not file size: `tokens ≈ width × height / 750`. AgentShot caps the long edge at 1568px — the point beyond which Claude downscales anyway — so you stop paying for pixels the model never uses. Real measurement (gpt-5.5, DocVQA): reading accuracy unchanged, image tokens cut ~50%; a full-screen 4K grab drops ~81%.

---

Homepage & benchmarks: **https://interesting-vibe-coding.github.io/agentshot-site/** · MIT License · part of [interesting-vibe-coding](https://github.com/interesting-vibe-coding)
