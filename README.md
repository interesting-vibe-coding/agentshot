# AgentShot

The screenshot tool built for Codex and GPT vision agents. Snip a region and it's auto-compressed to the vision model's optimal size, then copied to your clipboard.

**Why it matters for Codex:** OpenAI bills vision input by the image's pixel dimensions, tiled. A full-screen Retina grab burns thousands of tokens before the model reads a thing. AgentShot caps the long edge at 1568px and JPEG-encodes it, so you stop paying for pixels the model never uses.

**Measured, not theoretical** — same screenshot, real OpenRouter API calls (`bench/run_openrouter_tokens.py`):

| Model | Original (757 KB, 3024×1964) | AgentShot (174 KB, 1568×1018) | Saved |
|-------|------|------|------|
| **GPT-5.5** | 7083 input tokens | 1896 input tokens | **−73%** |

[中文](README.zh.md)

<img src="assets/before-after.png" width="100%">

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/interesting-vibe-coding/agentshot/main/install.sh | bash
```

Installs to `/Applications` and launches. Grant Accessibility once in onboarding. The first capture asks for Screen Recording — allow it, then reopen AgentShot.

## Usage

Press `⌘⇧2` to start. Click once for full screen, or drag to select a region. A preview appears:

- `C` / `↩` — copy the compressed image (label shows `original KB → compressed KB`)
- `⇧C` — copy the original
- `Esc` — cancel

Paste into Codex or any model billed by image resolution. Shortcut, quality tier, and launch-at-login live in the menubar (📸).

## How it works

OpenAI bills vision by pixel area (tiled). AgentShot's pipeline: downscale to ≤1568px long edge → JPEG q0.82 → enforce ≤⅓ the original size → hard cap at 1000 KB. Reading accuracy is unaffected — only token count drops ([benchmarks](bench/RESULTS.md)).

> **Note on Claude:** Anthropic normalizes images server-side before billing, so for Claude the token cost is already fixed regardless of what you send — AgentShot saves no tokens there. The win is real on resolution-billed models (GPT/Codex).

---

Homepage & benchmarks: **https://interesting-vibe-coding.github.io/agentshot-site/** · MIT License · part of [interesting-vibe-coding](https://github.com/interesting-vibe-coding)
