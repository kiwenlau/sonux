#!/usr/bin/env python3
"""Composite the rendered Sonux icons onto a realistic iPhone-style home screen mock.

Reads tools/icon/out/icon-*.png and writes tools/icon/out/mock-home-screen.png
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent / "out"
ICON = 180          # iPhone home-screen icon size @3x (60pt)
LABEL = "Sonux"

ICONS = [
    ("A", "icon-a-waveform-ring.png"),
    ("B", "icon-b-headphones.png"),
    ("C", "icon-c-glass-play.png"),
    ("D", "icon-d-broadcast.png"),
    ("E", "icon-e-sound-disc.png"),
    ("F", "icon-f-light-waveform-ring.png"),
]


def mask(size: int, ratio: float = 0.2237) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=size * ratio, fill=255)
    return m


def wallpaper(w: int, h: int) -> Image.Image:
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    top, bottom = (46, 34, 74), (12, 9, 22)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)],
               fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in ("/System/Library/Fonts/SFNS.ttf",
                 "/System/Library/Fonts/Supplemental/Arial.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main() -> None:
    cols, rows = 3, 2
    cell_w, cell_h = 300, 300
    pad = 90
    w = pad * 2 + cols * cell_w
    h = pad * 2 + rows * cell_h + 120
    img = wallpaper(w, h)
    d = ImageDraw.Draw(img)
    label_font, tag_font = font(30), font(24)
    m = mask(ICON)

    for i, (tag, name) in enumerate(ICONS):
        path = OUT / name
        if not path.exists():
            continue
        icon = Image.open(path).convert("RGBA").resize((ICON, ICON), Image.LANCZOS)
        col, row = i % cols, i // cols
        x = pad + col * cell_w + (cell_w - ICON) // 2
        y = pad + row * cell_h + 40
        img.paste(icon, (x, y), m)
        d.text((x + ICON // 2, y + ICON + 22), LABEL, font=label_font,
               fill=(255, 255, 255, 235), anchor="ma")
        d.text((x, y - 16), tag, font=tag_font, fill=(255, 255, 255, 120))

    out = OUT / "mock-home-screen.png"
    img.save(out)
    print(out)


if __name__ == "__main__":
    main()
