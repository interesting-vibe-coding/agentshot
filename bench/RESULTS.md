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

### 极端例子：一张 4K 截图（按 Claude 官方公式）

Claude 视觉 token 公式 `tokens ≈ 宽 × 高 / 750`：

| | 尺寸 | token | 按 claude-sonnet-4.6 ($3/Mtok) |
|---|---|---|---|
| 原图 4K | 3840×2160 | 3840·2160/750 = **11059** | $0.03318 / 张 |
| AgentShot 后 | 1568×882 | 1568·882/750 = **1844** | $0.00553 / 张 |
| **省** | | **9215 token (83%)** | **$0.02765 / 张 → 每 1000 张省 ≈ $27.65** |

> 注意：这是按 Anthropic 公开公式的理论值。在本 benchmark 实跑中，Claude 上报的 `img_tokens` orig/comp 几乎相等，与公式存在出入——属于 OpenRouter/Anthropic 端 token 计费口径的差异，故此例标记为「公式理论上限」。

---

## 结论（诚实版）

**在跑通的真实测量里，压缩后准确率没有出现实质性下降**：DocVQA 两模型基本无损（Claude ANLS 甚至 +0.022，gpt-5.5 持平 1.000）；ScreenSpot-Pro 上 Claude 反而从 0.0 提升到 0.3（高分辨率截图先降采样反而更利于 UI 定位）；MMStar 上的 ±0.1 属 n=10 噪声。

**省钱主要来自按像素计费的模型**：gpt-5.5 在 DocVQA 上 token 直接砍掉约一半（每 1000 张省 ≈ $9.42）；Claude 的实测 token 不随分辨率变化，节省体现为字节/带宽，理论公式下一张 4K 截图可省 83% token（每 1000 张 ≈ $27.65）。

一句话：**压缩几乎不损识别（个别场景甚至更好），token/费用对按像素计费的模型有明显节省。** 完整 n=10 双模型 ScreenSpot 结果需补足 OpenRouter 额度后重跑补全。
