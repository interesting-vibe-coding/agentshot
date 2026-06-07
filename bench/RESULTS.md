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
| ScreenSpot-Pro (acc) | claude-sonnet-4.6 | 0.000 | 0.300 | **+0.300** | 0.1% |
| ScreenSpot-Pro (acc) | gpt-5.5 | 1.000 (n=4) | N/A | N/A | N/A |
| MMStar (acc) | claude-sonnet-4.6 | 0.400 | 0.300 | −0.100 | 0.0% |
| MMStar (acc) | gpt-5.5 | 0.300 | 0.400 | +0.100 | 0.0% |

说明 / 诚实标注：
- **ScreenSpot-Pro · gpt-5.5 = N/A**：OpenRouter key 的 $30 spend cap 在跑到这里时耗尽（`limit_remaining=0`，硬 403），gpt-5.5 只完成 4 个原图调用、压缩条件一次都没跑，**不构成完整 n=10 测量**，故标 N/A。补足额度后重跑 `python3 bench/run_screenspot.py` 即可补全。
- **Claude 的 token 节省几乎为 0**：Claude 的图像 token 计费对分辨率不敏感（benchmark 里 orig/comp 上报 token 几乎不变），所以压缩省的是「字节 / 带宽」而非「Claude 计费 token」。真正的 token 节省体现在按像素分块计费的模型（gpt-5.5）和 Claude 的理论公式上（见下「极端例子」）。
- **MMStar 那两行准确率波动（±0.1）在 n=10 下属于噪声**，且图太小无法演示 token 节省，仅供参考。

---

## 费用节省

OpenRouter 实时单价（prompt，每 token 美元）：

| 模型 | $/token | $/百万 token |
|---|---|---|
| anthropic/claude-sonnet-4.6 | 0.000003 | $3.00 |
| openai/gpt-5.5 | 0.000005 | $5.00 |

**唯一一项跑通且确有 token 节省的真实测量 —— DocVQA · gpt-5.5：**

- 每张图 token：orig 3792.9 → comp 1908.2，**省 1884.7 token/张**（约 49.7%）
- 每张省钱：1884.7 × $0.000005 = **$0.00942 / 张**
- 外推 **每 1000 张截图省 ≈ $9.42**

其余真实测量（Claude DocVQA、两模型 MMStar）token 几乎不变，按上述单价省钱 ≈ $0；ScreenSpot · gpt-5.5 因额度耗尽无法给出。

### 极端例子：一张 4K 截图（仅适用于「按发送分辨率计费」的模型）

按 `tokens ≈ 宽 × 高 / 750` 估算发送像素对应的 token：

| | 尺寸 | token |
|---|---|---|
| 原图 4K | 3840×2160 | 3840·2160/750 = **11059** |
| AgentShot 后 | 1568×882 | 1568·882/750 = **1844** |
| **省** | | **9215 token (83%)** |

> ⚠️ 这个 83% **不适用于 Claude**。本 benchmark 实测显示 Claude 上报的 `img_tokens` 在 orig/comp 间几乎不变（DocVQA: 15488→15488，ScreenSpot: 960.4→959.4）——因为 Anthropic 会先把 >1568px 的图自动降采样再计费，4K 截图在 Claude 上本就按 ~1844 token 计，而非 11059。所以**对 Claude 而言这张图的 token 费用节省 ≈ 0**，省的是上传字节/带宽与请求大小限制。该 83% 仅对「按你发送的分辨率计费」的模型（如本测中 gpt-5.5 在 DocVQA 实测省 49.7%）成立。

---

## 结论（诚实版）

**1. 压缩不损识别。** 在跑通的真实测量里，压缩后准确率没有实质性下降：DocVQA 两模型基本无损（Claude ANLS 0.863→0.885，gpt-5.5 持平 1.000）。这是最难的文字密集任务，能过关说明截图场景更安全。

**2. 「省 token」分模型，不能笼统宣称。**
- **按发送分辨率计费的模型（GPT 等）**：真实节省。gpt-5.5 在 DocVQA token 砍约一半（每 1000 张省 ≈ $9.42）。
- **Claude**：实测计费 token 不随分辨率变化（Anthropic 服务端先降采样再计费），token 费用节省 ≈ 0；本工具的价值在于减少上传字节/带宽、绕过 32MB 请求与单请求图片数限制，以及让你**自己掌控**压缩质量而非交给服务端黑盒。

**3. 本次局限（不回避）：** ScreenSpot-Pro 因 OpenRouter 额度中途耗尽仅部分跑通、且 grounding 在 n=10 下噪声大，不作结论；MMStar 图太小不触发压缩、准确率 ±0.1 属噪声，亦不作结论。需补足额度并换用真正高分辨率的截图 QA 数据集重跑，才能给出 ScreenSpot/真实场景的可信数字。

一句话：**压缩几乎不损识别；token/费用节省对「按像素计费」的模型确实可观，对 Claude 则主要是带宽与可控性而非 token 费用。**
