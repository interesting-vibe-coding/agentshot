#!/usr/bin/env python3
"""MME-RealWorld (high-res real-world MCQ) compression before/after comparison.

Data source resolution (per task spec):
  1) yifanzhang114/MME-RealWorld-Lite  -> /rows generation FAILS (pyarrow Mask error)
  2) yifanzhang114/MME-RealWorld       -> /rows generation FAILS (webdataset KeyError 'jpg')
  3) lmms-lab/MMStar                   -> gated / not accessible
  Fallback used: Lin-Chen/MMStar (canonical MMStar, same schema as lmms-lab/MMStar:
     fields index/question/image/answer/category, options inline in question text).
"""
import os, io, sys, json, re, time, base64, random
import urllib.request
from PIL import Image

RESULTS_PATH = os.path.join(os.path.dirname(__file__), "results", "mme.json")
os.makedirs(os.path.dirname(RESULTS_PATH), exist_ok=True)

OPENROUTER_API_KEY = os.environ["OPENROUTER_API_KEY"]
MODELS = ["anthropic/claude-sonnet-4.6", "openai/gpt-5.5"]
HF = "https://datasets-server.huggingface.co"

# -------------------- data resolution --------------------
def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "agentshot-bench"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())

def rows_ok(dataset, config, split):
    try:
        d = http_json(f"{HF}/rows?dataset={dataset}&config={config}&split={split}&offset=0&length=1")
        return "rows" in d and len(d["rows"]) > 0
    except Exception:
        return False

def resolve_source():
    candidates = [
        ("yifanzhang114/MME-RealWorld-Lite", "MME-RealWorld-Lite"),
        ("yifanzhang114/MME-RealWorld", "MME-RealWorld"),
        ("lmms-lab/MMStar", "MMStar"),
        ("Lin-Chen/MMStar", "MMStar"),
    ]
    for ds, name in candidates:
        try:
            sp = http_json(f"{HF}/splits?dataset={ds}")
            splits = sp.get("splits", [])
        except Exception as e:
            print(f"[probe] {ds}: splits error {e}")
            continue
        if not splits:
            print(f"[probe] {ds}: no splits")
            continue
        chosen = None
        for pref in ("val", "test", "validation", "train"):
            for s in splits:
                if s["split"] == pref:
                    chosen = s; break
            if chosen: break
        chosen = chosen or splits[0]
        cfg, split = chosen["config"], chosen["split"]
        if rows_ok(ds, cfg, split):
            print(f"[probe] USING {ds} config={cfg} split={split} ({name})")
            return ds, cfg, split, name
        else:
            print(f"[probe] {ds} config={cfg} split={split}: /rows unavailable")
    return None

# -------------------- image helpers --------------------
def fetch_image(url):
    req = urllib.request.Request(url, headers={"User-Agent": "agentshot-bench"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()

def to_png(img_bytes):
    im = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    buf = io.BytesIO(); im.save(buf, format="PNG")
    return buf.getvalue(), im.size  # (w,h)

def compress(img_bytes, long_edge=1568, quality=82, max_kb=1000):
    im = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    w, h = im.size
    scale = long_edge / max(w, h)
    if scale < 1:
        im = im.resize((max(1, int(w*scale)), max(1, int(h*scale))), Image.LANCZOS)
    q = quality
    while True:
        buf = io.BytesIO(); im.save(buf, format="JPEG", quality=q)
        data = buf.getvalue()
        if len(data) <= max_kb*1024 or q <= 30:
            break
        q -= 6
    return data, im.size

# -------------------- OpenRouter --------------------
def ask(model, prompt, img_bytes, mime):
    b64 = base64.b64encode(img_bytes).decode()
    body = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
            ],
        }],
        "max_tokens": 4000,
    }
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {OPENROUTER_API_KEY}",
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=240) as r:
        d = json.loads(r.read())
    msg = d["choices"][0]["message"]
    text = msg.get("content") or msg.get("reasoning") or ""
    ptoks = d.get("usage", {}).get("prompt_tokens", 0)
    return text, ptoks

def ask_retry(model, prompt, img_bytes, mime):
    for attempt in range(2):
        try:
            return ask(model, prompt, img_bytes, mime)
        except Exception as e:
            if attempt == 1:
                raise
            time.sleep(3)

def first_letter(text):
    m = re.search(r"[A-E]", text.upper())
    return m.group(0) if m else None

# -------------------- main --------------------
def main():
    src = resolve_source()
    if src is None:
        out = {"benchmark": "MME-RealWorld", "status": "unavailable",
               "reason": "MME-RealWorld-Lite & MME-RealWorld /rows generation failed on HF "
                         "datasets-server; lmms-lab/MMStar gated; no usable choice-question source."}
        with open(RESULTS_PATH, "w") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return

    dataset, cfg, split, bench_name = src
    data = http_json(f"{HF}/rows?dataset={dataset}&config={cfg}&split={split}&offset=0&length=60")
    rows = [r["row"] for r in data["rows"]]
    print("FIRST ROW KEYS:", list(rows[0].keys()))
    print("FIRST QUESTION:", repr(rows[0]["question"])[:300])
    print("FIRST ANSWER:", rows[0]["answer"])
    print("FIRST IMAGE SRC:", rows[0]["image"]["src"][:120])

    random.seed(42)
    sample = random.sample(rows, 10)

    results = {m: {"correct_orig": 0, "correct_comp": 0,
                   "img_tokens_orig": [], "img_tokens_comp": []} for m in MODELS}
    dims_orig, dims_comp = [], []
    errors = []

    for i, row in enumerate(sample):
        q = row["question"].strip()
        gt = row["answer"].strip().upper()[:1]
        prompt = (q + "\n\nAnswer with ONLY the letter of the correct option "
                  "(A, B, C, D, or E).")
        try:
            raw = fetch_image(row["image"]["src"])
            png_bytes, odim = to_png(raw)
            jpg_bytes, cdim = compress(raw)
        except Exception as e:
            errors.append({"idx": i, "stage": "image", "error": str(e)})
            continue
        dims_orig.append(odim); dims_comp.append(cdim)
        print(f"[{i}] gt={gt} odim={odim} comp={cdim} "
              f"png={len(png_bytes)//1024}KB jpg={len(jpg_bytes)//1024}KB")

        for m in MODELS:
            try:
                txt, pt = ask_retry(m, prompt, png_bytes, "image/png")
                pred = first_letter(txt)
                if pred == gt: results[m]["correct_orig"] += 1
                results[m]["img_tokens_orig"].append(pt)
            except Exception as e:
                errors.append({"idx": i, "model": m, "stage": "orig", "error": str(e)})
            try:
                txt, pt = ask_retry(m, prompt, jpg_bytes, "image/jpeg")
                pred = first_letter(txt)
                if pred == gt: results[m]["correct_comp"] += 1
                results[m]["img_tokens_comp"].append(pt)
            except Exception as e:
                errors.append({"idx": i, "model": m, "stage": "comp", "error": str(e)})

    n = len(dims_orig)
    def avg(lst): return round(sum(lst)/len(lst), 1) if lst else 0
    models_out = {}
    for m in MODELS:
        r = results[m]
        models_out[m] = {
            "acc_orig": round(r["correct_orig"]/n, 3) if n else 0,
            "acc_comp": round(r["correct_comp"]/n, 3) if n else 0,
            "img_tokens_orig": avg(r["img_tokens_orig"]),
            "img_tokens_comp": avg(r["img_tokens_comp"]),
        }
    avg_dims_orig = [round(avg([d[0] for d in dims_orig])), round(avg([d[1] for d in dims_orig]))] if dims_orig else [0,0]
    avg_dims_comp = [round(avg([d[0] for d in dims_comp])), round(avg([d[1] for d in dims_comp]))] if dims_comp else [0,0]

    out = {
        "benchmark": bench_name,
        "task": "高分辨率真实场景选择题",
        "n": n,
        "models": models_out,
        "avg_dims_orig": avg_dims_orig,
        "avg_dims_comp": avg_dims_comp,
    }
    if dataset != "yifanzhang114/MME-RealWorld-Lite":
        out["note"] = ("MME-RealWorld(-Lite) /rows generation failed on HF datasets-server "
                       "and lmms-lab/MMStar is gated; used Lin-Chen/MMStar (canonical MMStar) "
                       "as the choice-question fallback.")
    if errors:
        out["errors"] = errors

    with open(RESULTS_PATH, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(json.dumps(out, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
