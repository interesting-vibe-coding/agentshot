#!/usr/bin/env python3
"""
ScreenSpot-Pro compression A/B for AgentShot.

Task: high-resolution professional-software screenshot UI grounding (point-in-bbox).
Compare model click-localization accuracy on ORIGINAL vs COMPRESSED screenshots.

Dataset note:
  The requested `Voxel51/ScreenSpot-Pro` is only an imagefolder (feature = `image`),
  with NO instruction / bbox annotations -> unusable for grounding scoring.
  We therefore use the fully-annotated `lmms-lab/ScreenSpot-Pro`
  (features: image, bbox, instruction, img_size, ...), the canonical ScreenSpot-Pro.

Compression (same as docvqa stage): long edge -> 1568, JPEG q82, keep < 1000 KB.
Models: anthropic/claude-sonnet-4.6, openai/gpt-5.5 (via OpenRouter).
"""
import os, io, re, json, time, random, base64, urllib.request, urllib.error

HF_DATASET = "lmms-lab/ScreenSpot-Pro"   # annotated ScreenSpot-Pro (Voxel51 mirror lacks labels)
HF_CONFIG = "default"
HF_SPLIT = "train"
PROBE_LEN = 80
N = 10
SEED = 42
MODELS = ["anthropic/claude-sonnet-4.6", "openai/gpt-5.5"]
OPENROUTER_KEY = os.environ["OPENROUTER_API_KEY"]
OUT_PATH = os.path.join(os.path.dirname(__file__), "results", "screenspot.json")
MAX_BYTES = 1000 * 1024
LONG_EDGE = 1568

from PIL import Image


def http_get(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": "agentshot-bench"})
    return urllib.request.urlopen(req, timeout=timeout).read()


def fetch_rows(offset, length):
    url = (f"https://datasets-server.huggingface.co/rows?dataset={HF_DATASET}"
           f"&config={HF_CONFIG}&split={HF_SPLIT}&offset={offset}&length={length}")
    return json.loads(http_get(url))


def compress_image(im):
    """long edge -> LONG_EDGE (downscale only), JPEG q82, < MAX_BYTES."""
    im = im.convert("RGB")
    w, h = im.size
    scale = LONG_EDGE / max(w, h)
    if scale < 1.0:
        im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    q = 82
    while True:
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=q)
        data = buf.getvalue()
        if len(data) <= MAX_BYTES or q <= 30:
            return im, data
        q -= 8


def encode_jpeg(im, quality=95):
    buf = io.BytesIO()
    im.convert("RGB").save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def ask(model, img_bytes, width, height, instruction):
    """Ask model for click coords on an image of size width x height. Returns (text, prompt_tokens)."""
    b64 = base64.b64encode(img_bytes).decode()
    prompt = (f'You are given a screenshot of size {width}x{height} pixels. '
              f'Identify where to click to fulfill the instruction. '
              f'Reply with ONLY JSON {{"x":int,"y":int}} in pixel coordinates of THIS image.\n'
              f'Instruction: ' + instruction)
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            ],
        }],
        "temperature": 0,
        "max_tokens": 4000,
    }
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {OPENROUTER_KEY}",
                 "Content-Type": "application/json"},
        method="POST",
    )
    resp = json.loads(urllib.request.urlopen(req, timeout=180).read())
    text = resp["choices"][0]["message"]["content"]
    if not text:
        raise ValueError("empty content from model")
    ptoks = resp.get("usage", {}).get("prompt_tokens")
    return text, ptoks


def ask_retry(model, img_bytes, width, height, instruction):
    last = None
    for attempt in range(4):
        try:
            r = ask(model, img_bytes, width, height, instruction)
            time.sleep(1.0)
            return r
        except Exception as e:
            last = e
            time.sleep(4 * (attempt + 1))
    raise last


XY_RE = re.compile(r'"?x"?\s*[:=]\s*(-?\d+(?:\.\d+)?).*?"?y"?\s*[:=]\s*(-?\d+(?:\.\d+)?)',
                   re.IGNORECASE | re.DOTALL)
NUM_RE = re.compile(r'-?\d+(?:\.\d+)?')


def parse_xy(text):
    """Robustly extract (x, y) from model output."""
    m = XY_RE.search(text)
    if m:
        return float(m.group(1)), float(m.group(2))
    nums = NUM_RE.findall(text)
    if len(nums) >= 2:
        return float(nums[0]), float(nums[1])
    return None


def in_bbox(x, y, bbox):
    x1, y1, x2, y2 = bbox
    return (min(x1, x2) <= x <= max(x1, x2)) and (min(y1, y2) <= y <= max(y1, y2))


def main():
    print(f"# Using annotated dataset {HF_DATASET} (Voxel51 mirror has no labels)\n")
    data = fetch_rows(0, PROBE_LEN)
    rows = [r["row"] for r in data["rows"]]

    # ---- probe: print first row keys + values ----
    print("=== PROBE: first row ===")
    r0 = rows[0]
    print("KEYS:", list(r0.keys()))
    for k, v in r0.items():
        print(f"  {k} => {str(v)[:200]}")
    print()

    random.seed(SEED)
    idxs = random.sample(range(len(rows)), N)
    print("Selected indices:", idxs, "\n")

    results = {m: {"hits_orig": 0, "hits_comp": 0,
                   "ptoks_orig": [], "ptoks_comp": [],
                   "n_orig": 0, "n_comp": 0} for m in MODELS}
    errors = []
    dims_orig, dims_comp = [], []

    for n, i in enumerate(idxs):
        row = rows[i]
        instruction = row["instruction"]
        bbox = row["bbox"]                      # [x1,y1,x2,y2] in original px
        meta_w, meta_h = row["img_size"]

        # download original full-res screenshot
        try:
            raw = http_get(row["image"]["src"])
            im = Image.open(io.BytesIO(raw)).convert("RGB")
        except Exception as e:
            errors.append({"idx": i, "stage": "download", "err": str(e)})
            continue
        ow, oh = im.size

        # if the served image differs from annotation img_size, scale bbox to served space
        if (ow, oh) != (meta_w, meta_h):
            sx, sy = ow / meta_w, oh / meta_h
            bbox = [bbox[0] * sx, bbox[1] * sy, bbox[2] * sx, bbox[3] * sy]

        orig_bytes = encode_jpeg(im, quality=95)
        comp_im, comp_bytes = compress_image(im)
        cw, ch = comp_im.size
        dims_orig.append((ow, oh))
        dims_comp.append((cw, ch))

        print(f"[{n+1}/{N}] id={row['id']} orig={ow}x{oh} comp={cw}x{ch} "
              f"({len(comp_bytes)//1024}KB) instr={instruction!r}")

        for model in MODELS:
            # ---- ORIGINAL ----
            try:
                text, pt = ask_retry(model, orig_bytes, ow, oh, instruction)
                xy = parse_xy(text)
                if xy is None:
                    errors.append({"idx": i, "model": model, "cond": "orig",
                                   "err": "parse_fail", "text": text[:120]})
                else:
                    hit = in_bbox(xy[0], xy[1], bbox)
                    results[model]["hits_orig"] += int(hit)
                    results[model]["n_orig"] += 1
                    if pt is not None:
                        results[model]["ptoks_orig"].append(pt)
                    print(f"    {model} ORIG -> {xy} hit={hit}")
            except Exception as e:
                errors.append({"idx": i, "model": model, "cond": "orig", "err": str(e)[:160]})

            # ---- COMPRESSED ----
            try:
                text, pt = ask_retry(model, comp_bytes, cw, ch, instruction)
                xy = parse_xy(text)
                if xy is None:
                    errors.append({"idx": i, "model": model, "cond": "comp",
                                   "err": "parse_fail", "text": text[:120]})
                else:
                    # restore to original pixel space
                    rx, ry = xy[0] * (ow / cw), xy[1] * (oh / ch)
                    hit = in_bbox(rx, ry, bbox)
                    results[model]["hits_comp"] += int(hit)
                    results[model]["n_comp"] += 1
                    if pt is not None:
                        results[model]["ptoks_comp"].append(pt)
                    print(f"    {model} COMP -> raw{xy} restored=({rx:.0f},{ry:.0f}) hit={hit}")
            except Exception as e:
                errors.append({"idx": i, "model": model, "cond": "comp", "err": str(e)[:160]})

    def avg(lst):
        return round(sum(lst) / len(lst), 1) if lst else None

    out = {
        "benchmark": "ScreenSpot-Pro",
        "task": "高分辨率截图UI定位(point-in-bbox)",
        "n": N,
        "dataset_used": HF_DATASET,
        "dataset_note": "Voxel51/ScreenSpot-Pro is an imagefolder with no instruction/bbox; used annotated lmms-lab/ScreenSpot-Pro instead.",
        "models": {},
        "avg_dims_orig": [round(sum(w for w, _ in dims_orig) / len(dims_orig)),
                          round(sum(h for _, h in dims_orig) / len(dims_orig))] if dims_orig else None,
        "avg_dims_comp": [round(sum(w for w, _ in dims_comp) / len(dims_comp)),
                          round(sum(h for _, h in dims_comp) / len(dims_comp))] if dims_comp else None,
        "errors": errors,
    }
    for m in MODELS:
        r = results[m]
        out["models"][m] = {
            "acc_orig": round(r["hits_orig"] / r["n_orig"], 3) if r["n_orig"] else None,
            "acc_comp": round(r["hits_comp"] / r["n_comp"], 3) if r["n_comp"] else None,
            "img_tokens_orig": avg(r["ptoks_orig"]),
            "img_tokens_comp": avg(r["ptoks_comp"]),
            "n_orig": r["n_orig"],
            "n_comp": r["n_comp"],
        }

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print("\n=== RESULT ===")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
