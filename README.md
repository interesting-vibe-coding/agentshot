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

> 这里的 token 数是「按发送像素估算」（`w·h/750`）。它直接反映**文件字节**节省，以及**按发送分辨率计费的模型**（GPT 等）的 token 节省。Claude 会在服务端自动降采样后再计费，所以 Claude 的计费 token 节省接近 0——详见下方 Benchmark 实测。

## Benchmark：压缩前后模型理解 & 省钱

「压完会不会让 AI 看不清？省多少 token？」小样本实测（各 10 随机样本 seed=42，两模型经 OpenRouter，压缩参数 1568/q82/<1000KB）。

**① 读懂/理解类任务 —— DocVQA**（文字最密、最考验压缩，原图平均长边 2081px → 压到 1519px）：

| DocVQA (ANLS) | 准确率 原图→压缩 | 图像 token 原图→压缩 |
|---|---|---|
| claude-sonnet-4.6 | 0.863 → 0.885（不降反升） | 15488 → 15488（**没变**） |
| gpt-5.5 | 1.000 → 1.000（满分持平） | 37929 → 19082（**省 49.7%**） |

**② 像素级 UI 定位 —— ScreenSpot-Pro**（专业软件 3840×1080 高分屏，要求输出精确点击坐标，n=10）：

| ScreenSpot-Pro (命中率) | 准确率 原图→压缩 | 图像 token 原图→压缩 |
|---|---|---|
| claude-sonnet-4.6 | 0.0 → 0.4（原生 grounding 差，n=10 噪声大） | 960 → 959（**没变**） |
| gpt-5.5 | 0.9 → 0.4（**精确定位被降采样压坏**） | 4601 → 878（**省 81%**） |

三条结论：

- **读懂/理解截图（绝大多数 agent 场景）→ 压缩几乎免费**：DocVQA 上两模型准确率都没掉。
- **像素级精确定位 + 超高分屏 → 压缩有真实代价**：gpt-5.5 把 3840×1080 压到 1568×441 后，UI 点击命中率从 0.9 掉到 0.4（token 却省了 81%）。这种小众场景请用高保真档（`maxLongEdge=2560`）或不压。
- **「省 token」分模型，别被笼统说法误导**：
  - **按发送分辨率计费的模型（GPT 等）** → 真实节省，实测 DocVQA 省 49.7%、ScreenSpot 省 81%。按 OpenRouter 单价 $5/Mtok，DocVQA ≈ **每 1000 张省 $9.42**。
  - **Claude** → 计费 token **几乎不变**（两个 bench 实测 orig≈comp）。因为 Anthropic 服务端会把 >1568px 的图自动降采样后再计费（相当于它已替你压了）。本工具在 Claude 上省的是**上传字节/带宽**、绕过请求 32MB / 单请求图片数限制——不是 token 费用。

> 局限：n=10 为小样本演示，非严格评测；MME-RealWorld 在 HF 上不可用、回退的 MMStar 图太小不触发压缩，故不列入结论。完整方法/单价/局限见 **[bench/RESULTS.md](bench/RESULTS.md)**。

## 那到底哪些场景真省 token？（按 harness 区分）

省不省 token，关键看**你的 harness/客户端在把截图发给模型之前有没有替你降采样**。AgentShot 的价值正在那些「不替你压」的链路上：

| 链路 | 会不会自动降采样 | 用 AgentShot 的收益 |
|---|---|---|
| **Anthropic API / Claude Code** | 会（>1568px 服务端降采样后计费） | token 中性；省的是上传字节/带宽 + 绕过大小限制 |
| **Kiro** | 否（已知大截图会直接**读图报错**） | **真省 token + 避免报错**（先压再喂，直接解决可用性问题） |
| **Codex 等其它 harness** | 多数不替你压 | 按发送分辨率计费时**真省 token**（参考上面 GPT 实测 50%~81%） |
| **OpenRouter / 自建 / 开源 VLM** | 一般原样转发你发的分辨率 | **真省 token**，比例随原图越大越可观 |

一句话：**对会自动降采样的 Claude 链路，AgentShot 省的是带宽与可控性；对 Kiro / Codex / 大多数不预处理的链路，省的是实打实的 token 和钱，还能避开大图报错。** 这正是工具存在的意义——把「该不该压、压多少」从各家黑盒里拿回到你手上，统一一个标准（<1000KB、长边 1568）。

## 安装 / 构建

```bash
./build.sh          # clang 编译 ObjC 版 + 组装 dist/AgentShot.app
open dist/AgentShot.app

# 验证压缩管线（不弹窗，直接对一张图跑全流程并写入剪贴板）
./dist/AgentShot.app/Contents/MacOS/AgentShot --selftest 某张截图.png
```

首次运行 macOS 会请求**屏幕录制**权限（截图需要）；按提示在 系统设置 → 隐私与安全性 → 屏幕录制 里勾选 AgentShot。

> **两份等价实现**：主构建用 **Objective-C**（`Sources/AgentShot/AgentShot.m`，clang 编译，依赖少且不受 Swift 工具链版本问题影响）；另有功能等价的 **Swift** 版 `Sources/AgentShot/main.swift`，`USE_SWIFT=1 ./build.sh` 可改用它（需 swiftc 与 SDK 版本匹配；若报 `this SDK is not supported by the compiler`，`softwareupdate` 更新 Command Line Tools 即可）。

## 用法

- 启动后菜单栏出现 📷 图标，**无 Dock 图标**（`LSUIElement`，后台常驻）。
- 默认快捷键 **⌘⇧2** → 框选区域 → 自动压缩 → 已在剪贴板，直接 ⌘V 粘给 agent。
- 菜单栏图标会闪一下结果，如 `✓ 176KB · 省73% 像素`。
- 按 Esc 取消框选。

> **关于剪贴板与「<1000KB」**：工具只写入一个 **JPEG 表示**（实测一张 3024×1964 截图 → 176KB，<1000KB）。但 macOS 会按需为图片**额外合成一个未压缩的 TIFF 表示**（同样是降采样后的 1568px 像素，只是字节大）。关键点：**所有表示的像素尺寸都被压到 ≤1568px，所以 token/费用一定是降下来的**（token 只按像素算，与字节无关），无论目标 app 读取哪个表示。字节层面，读 JPEG 的 app 拿到 <1000KB；个别偏好原始 TIFF 的 app 会拿到较大字节，但像素/ token 不变。

## 配置

改 `Sources/AgentShot/AgentShot.m` 顶部的常量（Swift 版同名字段在 `main.swift` 的 `Config`）：

```objc
static const NSInteger kMaxLongEdge = 1568;        // 长边上限（Claude 甜点；Opus 4.7+ 可设 2560）
static const CGFloat   kStartQ      = 0.82;        // JPEG 起始质量
static const NSInteger kByteLimit   = 1000 * 1024; // 硬上限 < 1000KB
```

快捷键改 `applicationDidFinishLaunching` 里的 `kVK_ANSI_2` / `cmdKey | shiftKey`。

## 技术栈

- **Objective-C**（单文件 `AgentShot.m`，clang 编译）+ 功能等价的 **Swift** 版 `main.swift`
- ImageIO — 降采样（`CGImageSourceCreateThumbnailAtIndex`）+ JPEG 编码
- Carbon `RegisterEventHotKey` — 全局快捷键（无需辅助功能权限）
- AppKit `NSStatusItem` / `NSPasteboard` — 菜单栏 + 剪贴板
- 系统 `/usr/sbin/screencapture -i` — 复用 macOS 原生框选交互

零第三方依赖。

## License

MIT
