#!/usr/bin/env python3
"""Render a privacy-safe mock 'screenshot', compress it with AgentShot's pipeline,
and compose a before/after figure showing: looks identical, far fewer tokens."""
import io, os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "assets"))
os.makedirs(OUT, exist_ok=True)

def font(paths, size):
    for p in paths:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()

SANS  = ["/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf"]
SANSB = ["/System/Library/Fonts/Supplemental/Arial Bold.ttf"]
SERIF = ["/System/Library/Fonts/Supplemental/Georgia.ttf"]
MONO  = ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Courier.ttc"]

# ---------- 1) render a high-res mock app window (looks like a real screenshot) ----------
W, H = 2560, 1600
img = Image.new("RGB", (W, H), (232, 228, 222))
d = ImageDraw.Draw(img)

# window
m = 90
wx0, wy0, wx1, wy1 = m, m, W - m, H - m
d.rounded_rectangle([wx0, wy0, wx1, wy1], radius=28, fill=(255, 255, 255))
# title bar
d.rounded_rectangle([wx0, wy0, wx1, wy0 + 96], radius=28, fill=(245, 245, 247))
d.rectangle([wx0, wy0 + 60, wx1, wy0 + 96], fill=(245, 245, 247))
for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
    cx = wx0 + 56 + i * 46
    d.ellipse([cx, wy0 + 36, cx + 26, wy0 + 62], fill=c)
d.text((W // 2 - 150, wy0 + 34), "report.md — Editor", font=font(SANS, 30), fill=(120, 120, 125))

cx0 = wx0 + 80
y = wy0 + 170
d.text((cx0, y), "Quarterly Engineering Review", font=font(SERIF, 64), fill=(28, 28, 30))
y += 110
para = ["Across the quarter the team shipped twelve features and cut median build",
        "time by 38%. Vision pipelines now downscale every screenshot before it",
        "reaches the model — token spend on image inputs dropped by more than half",
        "with no measurable loss in reading accuracy on internal evals."]
fp = font(SANS, 34)
for line in para:
    d.text((cx0, y), line, font=fp, fill=(60, 60, 66)); y += 50
y += 30

# code block
cb = [cx0, y, wx1 - 80, y + 360]
d.rounded_rectangle(cb, radius=16, fill=(30, 32, 40))
fm = font(MONO, 30)
code = [("def ", (197,134,192)), ("compress", (130,170,255)), ("(img, max_edge=", (212,212,212)),
        ("1568", (181,206,168)), ("):", (212,212,212))]
cyl = y + 34
d.text((cx0 + 30, cyl), "def compress(img, max_edge=1568):", font=fm, fill=(156, 220, 254))
cyl += 46
d.text((cx0 + 30, cyl), "    s = max_edge / max(img.size)", font=fm, fill=(206, 145, 120)); cyl += 46
d.text((cx0 + 30, cyl), "    if s < 1: img = img.resize(...)", font=fm, fill=(220, 220, 220)); cyl += 46
d.text((cx0 + 30, cyl), "    return to_jpeg(img, q=82)  # < 1000KB", font=fm, fill=(106, 153, 85)); cyl += 46
d.text((cx0 + 30, cyl), "    # tokens approx  w * h / 750", font=fm, fill=(106, 153, 85))

# little bar chart
bx, by = wx1 - 520, wy1 - 360
vals = [120, 200, 150, 260, 180]
for i, v in enumerate(vals):
    d.rectangle([bx + i*86, by + (260 - v), bx + i*86 + 56, by + 260], fill=(194, 105, 60))
d.text((bx, by + 280), "tokens / screenshot", font=font(SANS, 26), fill=(120,120,125))

# ---------- 2) original + compressed via AgentShot pipeline ----------
buf_o = io.BytesIO(); img.save(buf_o, "PNG"); bytes_o = buf_o.tell()
tok_o = W * H // 750

s = 1568 / max(W, H)
comp = img.resize((round(W*s), round(H*s)), Image.LANCZOS)
buf_c = io.BytesIO(); comp.save(buf_c, "JPEG", quality=82); bytes_c = buf_c.tell()
cw, ch = comp.size
tok_c = cw * ch // 750
saved = round(100 * (1 - tok_c / tok_o))
print(f"orig {W}x{H} {bytes_o//1024}KB ~{tok_o}tok | comp {cw}x{ch} {bytes_c//1024}KB ~{tok_c}tok | -{saved}%")

# ---------- 3) compose before/after figure (dark luxury) ----------
PANEL_W = 760
def panel(src):
    r = PANEL_W / src.size[0]
    return src.resize((PANEL_W, round(src.size[1]*r)), Image.LANCZOS)
po = panel(img); pc = panel(Image.open(io.BytesIO(buf_c.getvalue())))
ph = po.size[1]

FW, gut, top, capH = 1760, 60, 230, 150
fig = Image.new("RGB", (FW, top + ph + capH + 60), (22, 16, 9))
fd = ImageDraw.Draw(fig)
# headline
fd.text((70, 70), "Same to the model. ", font=font(SERIF, 60), fill=(244, 238, 230))
hw = fd.textlength("Same to the model. ", font=font(SERIF, 60))
fd.text((70 + hw, 74), f"-{saved}% tokens.", font=font(SERIF, 60), fill=(205, 168, 106))
fd.text((72, 156), "Compression you can't see — but your agent stops paying for it.",
        font=font(SANS, 30), fill=(168, 158, 146))

x0 = (FW - (PANEL_W*2 + gut)) // 2
for i, (p, title, sub, col) in enumerate([
    (po, "BEFORE", f"{W}×{H}  ·  ~{tok_o:,} image tokens", (194,105,60)),
    (pc, "AFTER — AgentShot", f"{cw}×{ch}  ·  ~{tok_c:,} image tokens", (46,126,168))]):
    px = x0 + i*(PANEL_W+gut)
    fig.paste(p, (px, top))
    fd.rectangle([px, top, px+PANEL_W, top+ph], outline=(70,60,48), width=2)
    fd.text((px, top+ph+18), title, font=font(SANSB, 30), fill=col)
    fd.text((px, top+ph+60), sub, font=font(SANS, 26), fill=(190,182,172))

fig.save(os.path.join(OUT, "before-after.png"), "PNG")
print("wrote assets/before-after.png", fig.size)
