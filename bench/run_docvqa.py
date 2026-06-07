#!/usr/bin/env python3
"""DocVQA: compare vision models on original vs compressed document images.

Outputs bench/results/docvqa.json
"""
import urllib.request, json, os, base64, ssl, io, random, time
from PIL import Image

ctx = ssl.create_default_context()
HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
os.makedirs(RESULTS, exist_ok=True)

MODELS = ["anthropic/claude-sonnet-4.6", "openai/gpt-5.5"]
PROMPT_PREFIX = ("Answer the question based on the document image. "
                 "Reply with ONLY the answer, no explanation.\nQuestion: ")


def compress(img_bytes, max_edge=1568, byte_limit=1000 * 1024):
    im = Image.open(io.BytesIO(img_bytes)).convert('RGB')
    w, h = im.size
    s = min(1.0, max_edge / max(w, h))
    if s < 1.0:
        im = im.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    for q in [82, 72, 62, 52, 42, 34]:
        buf = io.BytesIO()
        im.save(buf, 'JPEG', quality=q)
        if buf.tell() <= byte_limit or q == 34:
            break
    return buf.getvalue(), im.size, q


def ask(model, img_bytes, mime, prompt):
    b64 = base64.b64encode(img_bytes).decode()
    body = json.dumps({
        'model': model,
        'messages': [{'role': 'user', 'content': [
            {'type': 'text', 'text': prompt},
            {'type': 'image_url', 'image_url': {'url': f'data:{mime};base64,{b64}'}}
        ]}],
        'max_tokens': 100
    }).encode()
    req = urllib.request.Request(
        'https://openrouter.ai/api/v1/chat/completions',
        data=body,
        headers={'Authorization': 'Bearer ' + os.environ['OPENROUTER_API_KEY'],
                 'Content-Type': 'application/json'})
    d = json.load(urllib.request.urlopen(req, timeout=120, context=ctx))
    return d['choices'][0]['message']['content'], d.get('usage', {})


def ask_retry(model, img_bytes, mime, prompt):
    try:
        return ask(model, img_bytes, mime, prompt)
    except Exception as e:
        print(f"  retry after error: {e}")
        time.sleep(2)
        return ask(model, img_bytes, mime, prompt)


def levenshtein(a, b):
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def anls_score(pred, answers):
    pred = pred.lower().strip()
    best = 0.0
    for gt in answers:
        gt = gt.lower().strip()
        m = max(len(pred), len(gt))
        nl = 0.0 if m == 0 else levenshtein(pred, gt) / m
        s = 1 - nl
        if s > best:
            best = s
    return best if best >= 0.5 else 0.0


def fetch_rows():
    url = ("https://datasets-server.huggingface.co/rows?dataset=lmms-lab/DocVQA"
           "&config=DocVQA&split=validation&offset=0&length=60")
    req = urllib.request.Request(url)
    d = json.load(urllib.request.urlopen(req, timeout=120, context=ctx))
    return d['rows']


def download(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    return urllib.request.urlopen(req, timeout=120, context=ctx).read()


def detect_mime(img_bytes):
    fmt = Image.open(io.BytesIO(img_bytes)).format
    return {'JPEG': 'image/jpeg', 'PNG': 'image/png',
            'GIF': 'image/gif', 'WEBP': 'image/webp'}.get(fmt, 'image/jpeg')


def main():
    rows = fetch_rows()
    print(f"fetched {len(rows)} rows")
    random.seed(42)
    picked = random.sample(rows, 10)

    stats = {m: {'anls_orig': [], 'anls_comp': [],
                 'img_tokens_orig': 0, 'img_tokens_comp': 0} for m in MODELS}
    dims_orig = []
    dims_comp = []
    errors = 0

    for idx, item in enumerate(picked):
        row = item['row']
        question = row['question']
        answers = row['answers']
        img_url = row['image']['src']
        print(f"\n[{idx+1}/10] Q: {question}")
        try:
            orig_bytes = download(img_url)
            comp_bytes, comp_size, q = compress(orig_bytes)
            ow, oh = Image.open(io.BytesIO(orig_bytes)).size
            orig_mime = detect_mime(orig_bytes)
        except Exception as e:
            print(f"  image error, skip: {e}")
            errors += 1
            continue

        prompt = PROMPT_PREFIX + question
        sample_failed = False
        sample_results = {}
        for model in MODELS:
            try:
                p_orig, u_orig = ask_retry(model, orig_bytes, orig_mime, prompt)
                p_comp, u_comp = ask_retry(model, comp_bytes, 'image/jpeg', prompt)
            except Exception as e:
                print(f"  model {model} failed, skip sample: {e}")
                sample_failed = True
                break
            sample_results[model] = (p_orig, u_orig, p_comp, u_comp)

        if sample_failed:
            errors += 1
            continue

        dims_orig.append((ow, oh))
        dims_comp.append(comp_size)
        for model in MODELS:
            p_orig, u_orig, p_comp, u_comp = sample_results[model]
            so = anls_score(p_orig, answers)
            sc = anls_score(p_comp, answers)
            stats[model]['anls_orig'].append(so)
            stats[model]['anls_comp'].append(sc)
            stats[model]['img_tokens_orig'] += u_orig.get('prompt_tokens', 0)
            stats[model]['img_tokens_comp'] += u_comp.get('prompt_tokens', 0)
            print(f"  {model}: orig='{p_orig.strip()[:40]}'(anls {so:.2f}) "
                  f"comp='{p_comp.strip()[:40]}'(anls {sc:.2f})")

    n = len(dims_orig)
    out = {
        "benchmark": "DocVQA",
        "task": "OCR文档问答(ANLS)",
        "n": n,
        "models": {},
        "errors": errors,
    }
    for model in MODELS:
        ao = stats[model]['anls_orig']
        ac = stats[model]['anls_comp']
        out["models"][model] = {
            "anls_orig": round(sum(ao) / len(ao), 4) if ao else None,
            "anls_comp": round(sum(ac) / len(ac), 4) if ac else None,
            "img_tokens_orig": stats[model]['img_tokens_orig'],
            "img_tokens_comp": stats[model]['img_tokens_comp'],
        }
    if n:
        out["avg_dims_orig"] = [round(sum(d[0] for d in dims_orig) / n),
                                round(sum(d[1] for d in dims_orig) / n)]
        out["avg_dims_comp"] = [round(sum(d[0] for d in dims_comp) / n),
                                round(sum(d[1] for d in dims_comp) / n)]
    else:
        out["avg_dims_orig"] = None
        out["avg_dims_comp"] = None

    path = os.path.join(RESULTS, "docvqa.json")
    with open(path, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("\n=== docvqa.json ===")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
