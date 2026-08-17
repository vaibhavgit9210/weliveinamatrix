#!/usr/bin/env python3
"""
Renders the app icon for xcode/SimulationCam.

Nothing is hand-placed except the reticle. The scatter of labels comes from the
same tracker code the app runs -- the same mulberry32, the same kind mix, the
same sizes, ttls and teal chance -- driven by a synthetic subject walking across
frame, so the icon is literally a frame of this overlay, framed for a square.

    python3 tools/make_icon.py

Writes every size the asset catalog asks for, as opaque RGB (iOS rejects app
icons with an alpha channel).
"""

import json
import math
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "xcode", "SimulationCam", "Assets.xcassets", "AppIcon.appiconset")

SIZE = 1024
SS = 2                      # supersample, then box-filter down
N = SIZE * SS

FONT = "/System/Library/Fonts/Supplemental/Arial Narrow.ttf"
BG = (6, 10, 19)            # the same #060a13 the web build's favicon uses
TEAL = (127, 216, 216)
WHITE = (255, 255, 255)

# ---------------------------------------------------------------- randomness

M32 = 0xFFFFFFFF


class Rng:
    """mulberry32, matching index.html and TrackerSim.swift."""

    def __init__(self, seed):
        self.a = seed & M32

    def next(self):
        self.a = (self.a + 0x6D2B79F5) & M32
        a = self.a
        t = ((a ^ (a >> 15)) * (a | 1)) & M32
        t = ((t + (((t ^ (t >> 7)) * (t | 61)) & M32)) & M32) ^ t
        return ((t ^ (t >> 14)) & M32) / 4294967296.0


# ---------------------------------------------------------------- the trackers
#
# A cut-down TrackerSim: same constants, same draw order, no motion grid. The
# subject walks left to right and labels spawn near it, which is what the real
# grid ends up doing anyway.

GRID = 176.0                # cells across, as in the app
CELL = N / GRID
H_OVER_W = 1.0              # the icon is square, so the grid is too


def cloud(seed, frames=120, keep=15):
    """The cloud, then thinned to the clearest `keep` labels: two hundred of them
    is what a real frame looks like, and it is mud at forty pixels."""
    rng = Rng(seed)
    next_id = 300 + int(rng.next() * 30000)
    trackers, links = [], []
    for f in range(frames):
        # the subject: a blob drifting across the middle of frame
        cx = (0.44 + 0.13 * f / frames) * GRID
        cy = 0.53 * GRID * (H_OVER_W)
        for _ in range(1):
            r = rng.next()
            ang = rng.next() * math.tau
            rad = 33 * math.sqrt(rng.next())
            t = {
                "x": (cx + math.cos(ang) * rad) * CELL,
                "y": (cy + math.sin(ang) * rad * 1.25) * CELL,
                "id": next_id,
                "age": 0.0,
                "ttl": 40 + rng.next() * 150,
                "size": 9 + rng.next() * 4,
                "kind": "tag" if r < 0.78 else "box" if r < 0.96 else "fill",
                "w": 14 + rng.next() * 60,
                "h": 8 + rng.next() * 40,
                "teal": rng.next() < 0.05,
            }
            next_id += 1
            trackers.append(t)
            if len(links) < 46 and len(trackers) > 4 and rng.next() < 0.12:
                links.append((t, trackers[int(rng.next() * (len(trackers) - 1))]))
        for t in trackers:
            t["age"] += 1 + 3 * (rng.next() < 0.6)
        trackers = [t for t in trackers if t["age"] < t["ttl"]]
        links = [(a, b) for a, b in links if a["age"] < a["ttl"] and b["age"] < b["ttl"]]
    trackers.sort(key=lambda t: -min(1.0, (t["ttl"] - t["age"]) / 20.0, t["age"] / 6.0))
    trackers = trackers[:keep]
    alive = {id(t) for t in trackers}
    links = [(a, b) for a, b in links if id(a) in alive and id(b) in alive]
    return trackers, links


# ---------------------------------------------------------------- drawing

img = Image.new("RGB", (N, N), BG)
draw = ImageDraw.Draw(img, "RGBA")

# a very faint suggestion of the motion grid, so the field is not flat black
step = N / 22
for i in range(1, 22):
    v = int(i * step)
    draw.line([(v, 0), (v, N)], fill=(255, 255, 255, 7), width=max(1, int(N / 900)))
    draw.line([(0, v), (N, v)], fill=(255, 255, 255, 7), width=max(1, int(N / 900)))

U = N / 1024.0                      # everything below is in 1024-space
FS = 3.0                            # labels are bigger than in the app; an icon
                                    # is looked at from further away


def font(px):
    return ImageFont.truetype(FONT, max(6, int(px)))


def label(t, alpha=1.0):
    x, y = t["x"], t["y"]
    colour = TEAL if t["teal"] else WHITE
    px = t["size"] * FS * U
    f = font(px)
    lw = max(1, int(1.1 * FS * U))
    text = str(t["id"])
    if t["kind"] == "fill":
        h = t["h"] * 0.35 * FS * U
        w = t["w"] * 0.8 * FS * U
        draw.rectangle([x, y - h, x + w, y], fill=colour + (int(215 * alpha),))
        draw.text((x + 3 * FS * U, y - 2 * FS * U), text, font=f,
                  fill=(0, 0, 0, int(205 * alpha)), anchor="ls")
        return
    if t["kind"] == "box":
        w, h = t["w"] * FS * U, t["h"] * FS * U
        draw.rectangle([x - w / 2, y + 2 * FS * U, x + w / 2, y + 2 * FS * U + h],
                       outline=colour + (int(190 * alpha),), width=lw)
    # the little corner tick, then the number
    k = 2 * FS * U
    draw.line([(x - k, y + 1.5 * k), (x - k, y), (x + k, y)],
              fill=colour + (int(230 * alpha),), width=lw)
    draw.text((x + 3 * FS * U, y), text, font=f, fill=colour + (int(235 * alpha),), anchor="ls")


trackers, links = cloud(0x51_4D_CA_11)

# Keep the scatter off the hero label and inside the frame: a chip can be 220
# units wide, and one hanging off the edge reads as a rendering fault.
HERO = (288 * U, 344 * U)
def inside(t):
    right = t["x"] + (t["w"] * 0.8 * 3.0 * U if t["kind"] == "fill" else t["w"] * 0.5 * 3.0 * U)
    return 0.17 * N < t["x"] and right < 0.76 * N


trackers = [t for t in trackers
            if inside(t) and math.hypot(t["x"] - HERO[0], t["y"] - HERO[1]) > 150 * U]
alive = {id(t) for t in trackers}
links = [(a, b) for a, b in links if id(a) in alive and id(b) in alive]

for a, b in links:
    draw.line([(a["x"], a["y"]), (b["x"], b["y"])], fill=(255, 255, 255, 90),
              width=max(1, int(1.1 * FS * U)))
for t in trackers:
    fade = min(1.0, (t["ttl"] - t["age"]) / 20.0, t["age"] / 6.0)
    label(t, alpha=max(0.25, fade))

# ---------------------------------------------------------------- the reticle
#
# The one hand-placed thing: a viewfinder over the subject, thick enough to still
# read at 40 pixels, which is where an icon usually gets looked at.

BX, BY, BW, BH = 236, 216, 552, 600


def reticle():
    x0, y0 = BX * U, BY * U
    x1, y1 = (BX + BW) * U, (BY + BH) * U
    thin = max(1, int(5 * U))
    draw.rectangle([x0, y0, x1, y1], outline=(255, 255, 255, 85), width=thin)
    arm, thick = 162 * U, 26 * U
    for cx, cy, sx, sy in ((x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)):
        draw.rectangle([min(cx, cx + sx * arm), min(cy, cy + sy * thick),
                        max(cx, cx + sx * arm), max(cy, cy + sy * thick)], fill=WHITE + (245,))
        draw.rectangle([min(cx, cx + sx * thick), min(cy, cy + sy * arm),
                        max(cx, cx + sx * thick), max(cy, cy + sy * arm)], fill=WHITE + (245,))
    # the subject's own label, teal, inside the box under the top-left bracket,
    # drawn the way the overlay draws every other one: corner tick, then digits
    f = font(66 * U)
    bx, by = x0 + 52 * U, y0 + 128 * U
    lw = int(7 * U)
    draw.line([(bx, by + 22 * U), (bx, by), (bx + 22 * U, by)], fill=TEAL + (255,), width=lw)
    draw.text((bx + 16 * U, by), "8412", font=f, fill=TEAL + (255,), anchor="ls")


reticle()

# ---------------------------------------------------------------- finish
#
# A soft glow behind the reticle and a vignette, both drawn as one blurred layer
# so the field has some depth without any of it looking painted on.

vig = Image.new("L", (N, N), 0)
vd = ImageDraw.Draw(vig)
for i in range(60):
    f = i / 60.0
    r = N * (0.10 + 0.62 * f)
    vd.ellipse([N / 2 - r, N / 2 - r * 1.05, N / 2 + r, N / 2 + r * 1.05], fill=int(70 * (1 - f)))
glow = Image.new("RGB", (N, N), (24, 44, 60))
img = Image.composite(Image.blend(img, glow, 0.55), img, vig)

corner = Image.new("L", (N, N), 0)
cd = ImageDraw.Draw(corner)
for i in range(40):
    f = i / 40.0
    r = N * (0.52 + 0.30 * f)
    cd.ellipse([N / 2 - r, N / 2 - r, N / 2 + r, N / 2 + r], fill=0)
    cd.ellipse([N / 2 - r, N / 2 - r, N / 2 + r, N / 2 + r], outline=int(150 * f), width=int(N / 40))
img = Image.composite(Image.new("RGB", (N, N), (2, 4, 8)), img, corner)

img = img.resize((SIZE, SIZE), Image.LANCZOS)

# ---------------------------------------------------------------- write out

os.makedirs(OUT, exist_ok=True)
SIZES = [16, 32, 64, 128, 256, 512, 1024]
for s in SIZES:
    out = img if s == SIZE else img.resize((s, s), Image.LANCZOS)
    out.convert("RGB").save(os.path.join(OUT, "icon-%d.png" % s), "PNG", optimize=True)

contents = {
    "images": [
        {"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"filename": "icon-16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "icon-32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "icon-32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "icon-64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "icon-128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "icon-256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "icon-256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "icon-512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "icon-512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "icon-1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}
with open(os.path.join(OUT, "Contents.json"), "w") as fh:
    json.dump(contents, fh, indent=2)

root = os.path.join(OUT, "..", "Contents.json")
with open(root, "w") as fh:
    json.dump({"info": {"author": "xcode", "version": 1}}, fh, indent=2)

print("wrote", len(SIZES), "pngs to", os.path.normpath(OUT))
