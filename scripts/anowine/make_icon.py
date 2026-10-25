"""Render AnoWine's placeholder app icon into the AppIcon asset catalog.

Draws one 1024x1024 master (macOS-style rounded square, gradient, "AW"
monogram) and writes every size/scale listed in Contents.json under the
existing filenames, then verifies each file's pixel size. Replace the art
whenever a real icon exists; keep the filenames.

Usage: python3 make_icon.py <path/to/AppIcon.appiconset>
Requires Pillow.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

MASTER = 1024
BODY = 824          # Apple's macOS icon grid: 824px body on a 1024px canvas
RADIUS = 185
TOP = (58, 32, 112)       # deep violet
BOTTOM = (20, 110, 140)   # teal
FONT_CANDIDATES = [
    "C:/Windows/Fonts/segoeuib.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def _font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    sys.exit("make_icon: no bold TrueType font found; add one to FONT_CANDIDATES")


def render_master():
    scale = 2  # supersample for smooth edges
    size, body, radius = MASTER * scale, BODY * scale, RADIUS * scale
    offset = (size - body) // 2

    gradient = Image.new("RGBA", (body, body))
    draw = ImageDraw.Draw(gradient)
    for y in range(body):
        t = y / (body - 1)
        color = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)
        draw.line([(0, y), (body, y)], fill=color)

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(gradient, (offset, offset), mask)

    text = ImageDraw.Draw(canvas)
    font = _font(int(body * 0.42))
    left, top, right, bottom = text.textbbox((0, 0), "AW", font=font)
    x = (size - (right - left)) / 2 - left
    y = (size - (bottom - top)) / 2 - top
    text.text((x, y), "AW", font=font, fill=(255, 255, 255, 255))

    return canvas.resize((MASTER, MASTER), Image.LANCZOS)


def main(argv):
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    iconset = argv[0]
    with open(os.path.join(iconset, "Contents.json"), encoding="utf-8") as f:
        images = json.load(f)["images"]
    master = render_master()
    expected = {}
    for entry in images:
        points = int(entry["size"].split("x")[0])
        pixels = points * int(entry["scale"].rstrip("x"))
        path = os.path.join(iconset, entry["filename"])
        master.resize((pixels, pixels), Image.LANCZOS).save(path, "PNG")
        expected[path] = pixels
    bad = 0
    for path, pixels in expected.items():
        got = Image.open(path).size
        ok = got == (pixels, pixels)
        bad += not ok
        print(("ok  " if ok else "BAD ") + "%s %dx%d" % (os.path.basename(path), got[0], got[1]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
