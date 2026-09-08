#!/usr/bin/env python3
"""The disk image's backdrop: "drag and drop", and an arrow from the app to Applications.

Drawn at 1x and 2x and folded into one TIFF, which is how the Finder picks the sharp
one on a Retina display. Run once after changing it and commit the outputs:

    python3 packaging/dmg/background.py

The window is 660 by 440 points; the app icon sits at (150, 185) and the Applications
link at (510, 185) — package.sh places them there, so the words sit between the icons
at their height and the arrow passes between the two labels.
"""
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).parent
W, H = 660, 440
INK = (28, 28, 30)          # the app icon's black
SOFT = (142, 142, 147)      # the label grey the app uses
PAPER = (247, 247, 249)


def draw(scale: int) -> Image.Image:
    s = scale
    img = Image.new("RGB", (W * s, H * s), PAPER)
    d = ImageDraw.Draw(img)

    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf", 26 * s)
    first, rest = "drag ", "and drop"
    w1 = d.textlength(first, font=font)
    w2 = d.textlength(rest, font=font)
    x = (W * s - (w1 + w2)) / 2
    y = 185 * s
    d.text((x, y), first, font=font, fill=INK, anchor="lm")
    d.text((x + w1, y), rest, font=font, fill=SOFT, anchor="lm")

    # A curve that dips between the two labels, ending in an arrowhead.
    x0, y0, x1, y1 = 234 * s, 262 * s, 445 * s, 262 * s
    cx, cy = 330 * s, 322 * s
    pts = []
    for i in range(0, 101):
        t = i / 100
        px = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * cx + t * t * x1
        py = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * cy + t * t * y1
        pts.append((px, py))
    d.line(pts, fill=INK, width=5 * s, joint="curve")
    # Round the tail.
    r = 2.5 * s
    d.ellipse((x0 - r, y0 - r, x0 + r, y0 + r), fill=INK)
    # The head: two strokes back from the tip along the curve's final direction.
    import math
    tx, ty = pts[-1]
    px, py = pts[-8]
    ang = math.atan2(ty - py, tx - px)
    length = 16 * s
    for spread in (0.55, -0.55):
        ex = tx - length * math.cos(ang + spread)
        ey = ty - length * math.sin(ang + spread)
        d.line([(tx, ty), (ex, ey)], fill=INK, width=5 * s)
        d.ellipse((ex - r, ey - r, ex + r, ey + r), fill=INK)
    d.ellipse((tx - r, ty - r, tx + r, ty + r), fill=INK)
    return img


if __name__ == "__main__":
    one = HERE / "background.png"
    two = HERE / "background@2x.png"
    draw(1).save(one)
    draw(2).save(two)
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(HERE / "background.tiff")], check=True)
    print("wrote", one.name, two.name, "background.tiff")
