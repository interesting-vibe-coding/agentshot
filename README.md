<h1 align="center">AgentShot 📸</h1>

<p align="center">
  <b>The screenshot tool built for AI agents.</b><br>
  Snip → auto-compress to vision's sweet spot → on your clipboard. Paste into any agent with <b>up to 81% fewer image tokens</b> and <b>no loss in comprehension</b>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-111111">
  <img src="https://img.shields.io/badge/built%20with-Objective--C%20%2F%20Swift-c2693c">
  <img src="https://img.shields.io/badge/deps-zero-2e8b57">
  <img src="https://img.shields.io/badge/license-MIT-2e7ea8">
  <img src="https://img.shields.io/github/stars/interesting-vibe-coding/agentshot?style=social">
</p>

<p align="center"><a href="README.zh.md">🇨🇳 中文文档</a></p>

---

Screenshots pasted into AI agents are needlessly huge. A Retina grab is millions of pixels — and for vision models, **tokens scale with pixels, not file size**. AgentShot caps every screenshot at the model's optimal resolution before it hits your clipboard, so you stop paying for pixels the model never uses.

- ⚡ **One hotkey** (`⌘⇧2`) → native region select → compressed → clipboard. Paste anywhere.
- 🎯 **Smart cap**: long edge ≤ 1568px (Claude's sweet spot) + JPEG q82, hard-capped **< 1000KB**.
- 🪶 **Featherweight**: menubar-only, no Dock icon, **zero third-party dependencies**, pure native macOS.
- 🔬 **Benchmarked**: compression doesn't hurt how models read screenshots — we measured it.

## Why compress? (the counter-intuitive part)

For Claude / GPT, **image tokens depend on pixel dimensions, not bytes** — `tokens ≈ width × height / 750`. A 5 MB PNG and a 200 KB JPEG of the same size cost the *same* tokens. So the real lever for saving tokens is **downscaling resolution**, and 1568px is where Claude stops charging extra (it downscales bigger images anyway).

## Benchmark

Does compression hurt how a model reads a screenshot? We measured it: real A/B on **original vs AgentShot-compressed** images, `claude-sonnet-4.6` + `gpt-5.5` via OpenRouter, on DocVQA (text-dense document screenshots — the case most sensitive to compression). All numbers from real API calls — full method in [`bench/RESULTS.md`](bench/RESULTS.md).

<p align="center">
  <img src="assets/accuracy.svg" width="48%">
  <img src="assets/tokens.svg" width="51%">
</p>

- ✅ **Reading accuracy unchanged** — both models score the same on compressed screenshots.
- 💸 **Up to 81% fewer image tokens** on models billed by sent resolution (gpt-5.5: −50% on documents, −81% on a full-screen 4K grab).

## When does it actually save tokens? (depends on your harness)

The win depends on whether your client downscales *before* sending to the model:

| Harness / path | Auto-downscales? | What AgentShot saves |
|---|---|---|
| **Anthropic API / Claude Code** | Yes (server-side >1568px) | Bandwidth + request-size limits |
| **Kiro** | No — large screenshots can even **error out** | **Real tokens + fixes the error** |
| **Codex & most others** | Usually not | **Real tokens** (−50%…−81% above) |
| **OpenRouter / self-hosted / OSS VLMs** | Forward your resolution as-is | **Real tokens**, bigger original = bigger win |

> On Claude you save bandwidth & control; on Kiro / Codex / anything that doesn't pre-process, you save real tokens and money — and dodge large-image errors.

## Install

```bash
git clone https://github.com/interesting-vibe-coding/agentshot
cd agentshot
./build.sh                 # clang builds dist/AgentShot.app (zero deps)
open dist/AgentShot.app

# verify the pipeline without the GUI:
./dist/AgentShot.app/Contents/MacOS/AgentShot --selftest your-screenshot.png
```

First launch prompts for **Screen Recording** permission (needed to capture). A Swift implementation is also included — build it with `USE_SWIFT=1 ./build.sh`.

## Usage

- A 📸 icon appears in the menubar (no Dock icon — it's a background `LSUIElement`).
- Press **`⌘⇧2`** → drag to select → it's compressed and on your clipboard. Just `⌘V` into your agent.
- The icon flashes the result, e.g. `✓ 176KB · -73% pixels`. `Esc` cancels.

## How it works

`screencapture -i` (native region select) → ImageIO `CGImageSourceCreateThumbnailAtIndex` decodes straight at ≤1568px (fast, no full decode) → JPEG with quality back-off until < 1000KB → raw JPEG bytes written to `NSPasteboard` as `public.jpeg` (never via `NSImage`, which would balloon into an uncompressed TIFF).

> Clipboard note: macOS may also expose an uncompressed TIFF representation. It's the **same 1568px pixels**, so token/cost savings hold regardless of which representation an app reads; only raw-byte size differs.

## Config

Edit the constants at the top of `Sources/AgentShot/AgentShot.m`:

```objc
static const NSInteger kMaxLongEdge = 1568;        // long-edge cap (Claude sweet spot; 2560 for Opus 4.7+)
static const CGFloat   kStartQ      = 0.82;        // starting JPEG quality
static const NSInteger kByteLimit   = 1000 * 1024; // hard cap: < 1000KB
```

Change the hotkey via `kVK_ANSI_2` / `cmdKey | shiftKey` in `applicationDidFinishLaunching`.

## Stack

Objective-C single file (`AgentShot.m`, clang) + equivalent Swift (`main.swift`) · ImageIO · Carbon global hotkey (no Accessibility permission) · AppKit menubar & pasteboard · system `screencapture`. Zero third-party dependencies.

## License

MIT
