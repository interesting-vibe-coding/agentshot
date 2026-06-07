# AgentShot

> 极致轻量的 macOS 截图工具，专为「喂给 AI agent」设计 —— 框选即压缩，任何图都 < 1000KB，自动省 70%+ token，直接进剪贴板。

像 Snipaste 一样按快捷键框选截图，但每张图在落到剪贴板前都会被自动压到 AI 视觉模型的「最优尺寸」。粘给 Claude / GPT / 任意 agent 时，token 消耗大幅下降，识别效果几乎无损。

纯 macOS 原生（Swift + ImageIO + Carbon），单文件、零第三方依赖、menubar 后台常驻。

---

## 为什么要压（一个反直觉的点）

很多人以为「截图文件大 → 消耗 token 多」。其实对 Claude / GPT 而言：

- **Token 数只取决于像素尺寸，跟文件字节大小无关。** Claude 官方公式：`tokens ≈ 宽 × 高 / 750`。一张 5MB 的 PNG 和一张 200KB 的 JPEG，只要像素一样，token 完全相同。
- **省 token 的真正杠杆是「降分辨率」，不是「降画质」。**

AgentShot 同时拧两个杠杆：

| 杠杆 | 做法 | 影响 | 依据 |
|------|------|------|------|
| 分辨率 | 长边压到 **≤ 1568px** | 直接砍 token | Claude 超过 1568px（1.15MP）会自动降采样，多发的像素纯属浪费 |
| 画质 | **JPEG q82** 起步，超 1000KB 才继续降 | 只砍字节，不砍 token | ViT 在 q80 下识别准确率仅掉 ≤1.3pp，q85 仍 >98% |

> 想要更高保真？Claude Opus 4.7+ 把上限提到了 2576px / 3.75MP；改 `Config.maxLongEdge` 即可。

## 压缩策略（默认方案）

```
框选 → ImageIO 直接以降低分辨率解码（长边 ≤ 1568px）
     → JPEG 编码，质量从 0.82 起
     → 若 > 1000KB：逐级降质量 [0.82→0.34]，必要时再降分辨率 [1568→832]
     → 直到 < 1000KB（硬标准，任何图都满足）
     → 原始 JPEG 字节直写剪贴板 public.jpeg
```

关键实现细节：
- 用 `CGImageSourceCreateThumbnailAtIndex` 直接以目标分辨率解码，**不先解全图再缩**，硬件加速，单张毫秒级。
- 剪贴板写入**原始 JPEG 字节**，绝不经 `NSImage`（那会在剪贴板上重编码成巨大的无压缩 TIFF，前功尽弃）。

## 实测效果

真实 Retina 全屏截图：

| | 尺寸 | 文件 | token (w·h/750) |
|---|---|---|---|
| 原图 PNG | 3024×1964 | 698 KB | ~7918 |
| AgentShot 后 | 1568×1018 | **171 KB** | **~2128** |
| | | | **省 73%** |

## 安装 / 构建

```bash
./build.sh          # 编译 + 组装 dist/AgentShot.app
open dist/AgentShot.app
```

首次运行 macOS 会请求**屏幕录制**权限（截图需要）；按提示在 系统设置 → 隐私与安全性 → 屏幕录制 里勾选 AgentShot。

> 需要 Xcode Command Line Tools，且编译器与 SDK 版本匹配。若 `swiftc` 报
> `this SDK is not supported by the compiler`，运行 `softwareupdate --list`
> 安装最新的 Command Line Tools 即可。

## 用法

- 启动后菜单栏出现 📷 图标，**无 Dock 图标**（`LSUIElement`，后台常驻）。
- 默认快捷键 **⌘⇧2** → 框选区域 → 自动压缩 → 已在剪贴板，直接 ⌘V 粘给 agent。
- 菜单栏图标会闪一下结果，如 `✓ 171KB · 省73% token`。
- 按 Esc 取消框选。

## 配置

改 `Sources/AgentShot/main.swift` 里的 `Config`：

```swift
enum Config {
    static let maxLongEdge = 1568        // 长边上限（Claude 甜点；Opus 4.7+ 可设 2576）
    static let startQuality: CGFloat = 0.82
    static let byteLimit = 1000 * 1024   // 硬上限 < 1000KB
}
```

快捷键改 `AppDelegate` 里 `kVK_ANSI_2` / `cmdKey | shiftKey`。

## 技术栈

- Swift（单文件 `main.swift`）
- ImageIO — 降采样 + JPEG 编码
- Carbon `RegisterEventHotKey` — 全局快捷键（无需辅助功能权限）
- AppKit `NSStatusItem` / `NSPasteboard` — 菜单栏 + 剪贴板
- 系统 `/usr/sbin/screencapture -i` — 复用 macOS 原生框选交互

零第三方依赖。

## License

MIT
