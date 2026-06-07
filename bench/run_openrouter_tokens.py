#!/usr/bin/env python3
"""
Measure REAL image input tokens via OpenRouter, comparing an original
screenshot vs the AgentShot-compressed version, across multiple models.

Reads OPENROUTER_API_KEY from the environment (never hard-code keys).

Usage:
    OPENROUTER_API_KEY=sk-or-... python3 bench/run_openrouter_tokens.py [image.png]
"""
import base64, io, json, os, sys, pathlib
from openai import OpenAI
from PIL import Image

MODELS = [
    "anthropic/claude-sonnet-4.6",
    "openai/gpt-5.5",
]
LONG_EDGE = 1568
JPEG_Q = 82

def compress(src_path: str) -> bytes:
    img = Image.open(src_path).convert("RGB")
    w, h = img.size
    r = LONG_EDGE / max(w, h)
    if r < 1.0:
        img = img.resize((int(w * r), int(h * r)), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=JPEG_Q)
    return buf.getvalue()

def input_tokens(client, model, data: bytes, mime: str) -> int:
    b64 = base64.b64encode(data).decode()
    r = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
            {"type": "text", "text": "Describe this screenshot in one short sentence."},
        ]}],
        max_tokens=16,
    )
    return r.usage.prompt_tokens

def main():
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        sys.exit("OPENROUTER_API_KEY not set")
    src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fullscreen_test.png"
    client = OpenAI(base_url="https://openrouter.ai/api/v1", api_key=key)

    orig = pathlib.Path(src).read_bytes()
    comp = compress(src)
    w, h = Image.open(src).size
    cw, ch = Image.open(io.BytesIO(comp)).size

    print(f"src:  {len(orig)//1024:>5} KB  {w}×{h}")
    print(f"comp: {len(comp)//1024:>5} KB  {cw}×{ch}  (long edge ≤{LONG_EDGE}, JPEG q{JPEG_Q})")
    print()

    results = {"source": src, "src_bytes": len(orig), "comp_bytes": len(comp),
               "src_dim": [w, h], "comp_dim": [cw, ch], "models": {}}

    for m in MODELS:
        try:
            t_orig = input_tokens(client, m, orig, "image/png")
            t_comp = input_tokens(client, m, comp, "image/jpeg")
            saved = t_orig - t_comp
            pct = round(saved * 100 / t_orig) if t_orig else 0
            results["models"][m] = {"orig": t_orig, "comp": t_comp, "saved": saved, "pct": pct}
            print(f"{m:<32} {t_orig:>5} → {t_comp:>5} tok   saved {pct:>3}%")
        except Exception as e:
            results["models"][m] = {"error": str(e)}
            print(f"{m:<32} ERROR: {e}")

    out = pathlib.Path(__file__).parent / "results" / "openrouter_tokens.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(results, indent=2))
    print(f"\n→ {out}")

if __name__ == "__main__":
    main()
