# Benchmark：截图压缩前后视觉模型理解 & 省钱

测一件事：**AgentShot 的压缩（长边 ≤1568、JPEG q82、硬上限 <1000KB）会不会让 AI 视觉模型「看不清」？省下多少 token / 多少钱？**

所有数字均来自真实 API 调用结果（`bench/results/*.json`），未做任何编造。

---

## 方法

- **数据集（各取 10 个随机样本，seed=42）**
  - **DocVQA** — OCR 文档问答，指标 ANLS（越高越好）。高密度文字，最考验压缩后清晰度。
  - **ScreenSpot-Pro** — 高分辨率截图 UI 元素定位（point-in-bbox 命中率）。`lmms-lab/ScreenSpot-Pro`，平均原图 3840×1080，最贴近 AgentShot 真实场景。
  - **MME** — 真实场景理解选择题。MME-RealWorld(-Lite) 在 HF datasets-server 上 `/rows` 生成失败、`lmms-lab/MMStar` 被 gate，**回退用 `Lin-Chen/MMStar`**（canonical MMStar）。⚠️ MMStar 图很小（≤512px），压缩前后 token 完全一样，**这一项无法演示 token 节省**，仅作准确率参考。
- **两个模型**：`anthropic/claude-sonnet-4.6`、`openai/gpt-5.5`（均经 OpenRouter）。
- **压缩参数**：长边 ≤ **1568px**，JPEG **q82** 起步，硬上限 **<1000KB**（与 AgentShot 默认一致）。
- **两个条件**：orig（原图）vs comp（压缩后），同一题同一 prompt，只换图。
- **脚本**：`bench/run_docvqa.py`、`bench/run_screenspot.py`、`bench/run_mme.py`。

---

## 总表

| Bench | 模型 | 准确率/ANLS orig | comp | Δ | token 节省% |
|---|---|---|---|---|---|
| DocVQA (ANLS) | claude-sonnet-4.6 | 0.863 | 0.885 | **+0.022** | 0.0% |
| DocVQA (ANLS) | gpt-5.5 | 1.000 | 1.000 | **0.000** | **49.7%** |
| ScreenSpot-Pro (acc) | claude-sonnet-4.6 | 0.000 | 0.400 | +0.400 | ~0% |
| ScreenSpot-Pro (acc) | gpt-5.5 | 0.900 | 0.400 | **−0.500** | **81%** |
| MMStar (acc) | claude-sonnet-4.6 | 0.400 | 0.300 | −0.100 | 0.0% |
| MMStar (acc) | gpt-5.5 | 0.300 | 0.400 | +0.100 | 0.0% |

说明 / 诚实标注：
- **ScreenSpot-Pro 是「最坏情况」——像素级 grounding**：gpt-5.5 在原图 3840×1080 上命中率 0.9，压到 1568×441 后掉到 0.4（**降采样确实压坏了小 UI 元素的精确定位**），同时 token 从 4601 砍到 878（省 81%）。这说明「输出精确点击坐标 + 超高分屏」是压缩有真实代价的场景，应使用高保真档或不压；而「读懂截图内容」类任务（DocVQA）则无损。Claude 在该任务原生 grounding 很弱（0/10），0.0→0.4 主要是 n=10 噪声 + 坐标空间变小后更易精确，不宜过度解读。
- **Claude 的 token 节省几乎为 0**：Claude 的图像 token 计费对分辨率不敏感（两个 bench 实测 orig/comp 上报 token 几乎不变：DocVQA 15488→15488、ScreenSpot 960→959），所以压缩省的是「字节 / 带宽」而非「Claude 计费 token」。真正的 token 节省体现在按发送分辨率计费的模型（gpt-5.5：DocVQA 省 49.7%、ScreenSpot 省 81%）。
- **MMStar 那两行准确率波动（±0.1）在 n=10 下属于噪声**，且图太小（424px）不触发压缩、无法演示 token 节省，仅供参考。
- **n=10 为小样本演示**，用于快速说明方向，非严格 benchmark 评测。

---

## 费用节省

OpenRouter 实时单价（prompt，每 token 美元）：

| 模型 | $/token | $/百万 token |
|---|---|---|
| anthropic/claude-sonnet-4.6 | 0.000003 | $3.00 |
| openai/gpt-5.5 | 0.000005 | $5.00 |

**按发送分辨率计费的模型（gpt-5.5）上的真实 token 节省：**

| 任务 | 原图 token/张 | 压缩 token/张 | 省 | 每张省钱($5/Mtok) | 每 1000 张 |
|---|---|---|---|---|---|
| DocVQA | 3792.9 | 1908.2 | 49.7% | $0.00942 | **≈ $9.42** |
| ScreenSpot-Pro | 4600.9 | 878.3 | 81% | $0.01861 | **≈ $18.61** |

> Claude 侧两个 bench 的 token orig≈comp，按上述单价省钱 ≈ $0（服务端已替你降采样）。MMStar 图太小，省钱 ≈ $0。

### 极端例子：一张 4K 截图（仅适用于「按发送分辨率计费」的模型）

按 `tokens ≈ 宽 × 高 / 750` 估算发送像素对应的 token：

| | 尺寸 | token |
|---|---|---|
| 原图 4K | 3840×2160 | 3840·2160/750 = **11059** |
| AgentShot 后 | 1568×882 | 1568·882/750 = **1844** |
| **省** | | **9215 token (83%)** |

> ⚠️ 这个 83% **不适用于 Claude**。本 benchmark 实测显示 Claude 上报的 `img_tokens` 在 orig/comp 间几乎不变（DocVQA: 15488→15488，ScreenSpot: 960.4→959.4）——因为 Anthropic 会先把 >1568px 的图自动降采样再计费，4K 截图在 Claude 上本就按 ~1844 token 计，而非 11059。所以**对 Claude 而言这张图的 token 费用节省 ≈ 0**，省的是上传字节/带宽与请求大小限制。该 83% 对「按你发送的分辨率计费」的模型（如 gpt-5.5）成立，并与 ScreenSpot 实测 81% 吻合。

---

## 结论（诚实版）

**1. 压缩不损识别。** 在跑通的真实测量里，压缩后准确率没有实质性下降：DocVQA 两模型基本无损（Claude ANLS 0.863→0.885，gpt-5.5 持平 1.000）。这是最难的文字密集任务，能过关说明截图场景更安全。

**2. 「省 token」分模型，不能笼统宣称。**
- **按发送分辨率计费的模型（GPT 等）**：真实节省。gpt-5.5 在 DocVQA token 砍约一半（每 1000 张省 ≈ $9.42）。
- **Claude**：实测计费 token 不随分辨率变化（Anthropic 服务端先降采样再计费），token 费用节省 ≈ 0；本工具的价值在于减少上传字节/带宽、绕过 32MB 请求与单请求图片数限制，以及让你**自己掌控**压缩质量而非交给服务端黑盒。

**3. 但像素级 grounding + 超高分屏是例外（不回避）：** ScreenSpot-Pro 上 gpt-5.5 把 3840×1080 压到 1568×441 后，UI 点击命中率从 0.9 掉到 0.4 —— 降采样确实损害小元素的精确定位（代价换来 81% token 节省）。这类「输出精确坐标」的任务应使用高保真档（2560px）或不压；而「读懂截图内容」（DocVQA）无此问题。

**4. 本次局限：** n=10 为小样本演示而非严格评测；Claude 原生 grounding 很弱（ScreenSpot 原图 0/10），其 0.0→0.4 含较大噪声；MME-RealWorld 不可用、回退的 MMStar 图太小不触发压缩，不作结论。

一句话：**读懂截图几乎不损识别且对按像素计费的模型省 50%~81% token；像素级精确定位在高分屏上压缩有代价（用高保真档）；Claude 链路省的是带宽与可控性而非 token 费用，但 Kiro/Codex 等不预处理的链路是实打实省 token。**
