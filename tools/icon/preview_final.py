#!/usr/bin/env python3
"""Show the shipped Sonux icon at real home-screen size on a light and a dark wallpaper.

Writes tools/icon/out/mock-final.png
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent / "out"
ICON = 180
LABEL = "Sonux"


def mask(size: int, ratio: float = 0.2237) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1],
                                        radius=size * ratio, fill=255)
    return m


def gradient(w: int, h: int, top, bottom) -> Image.Image:
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def font(size: int):
    for path in ("/System/Library/Fonts/PingFang.ttc",
                 "/System/Library/Fonts/SFNS.ttf",
                 "/System/Library/Fonts/Supplemental/Arial.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main() -> None:
    icon = Image.open(OUT / "sonux-AppIcon.png").convert("RGBA").resize((ICON, ICON),
                                                                          Image.LANCZOS)
    m = mask(ICON)
    panel_w, panel_h, gap, pad = 420, 360, 40, 40
    canvas = Image.new("RGB", (pad * 2 + panel_w * 2 + gap, pad * 2 + panel_h), (255, 255, 255))
    d = ImageDraw.Draw(canvas)
    lf = font(30)

    panels = [("Light wallpaper", gradient(panel_w, panel_h, (226, 223, 232), (186, 182, 200)),
               (40, 34, 56)),
              ("Dark wallpaper", gradient(panel_w, panel_h, (44, 38, 64), (14, 11, 24)),
               (255, 255, 255))]

    for i, (title, bg, text) in enumerate(panels):
        x0 = pad + i * (panel_w + gap)
        y0 = pad
        canvas.paste(bg, (x0, y0))
        p = ImageDraw.Draw(canvas)
        p.rounded_rectangle([x0, y0, x0 + panel_w - 1, y0 + panel_h - 1], radius=28,
                            outline=(0, 0, 0, 30))
        ix = x0 + (panel_w - ICON) // 2
        iy = y0 + 110
        canvas.paste(icon, (ix, iy), m)
        p.text((ix + ICON // 2, iy + ICON + 20), LABEL, font=lf, fill=text, anchor="ma")
        p.text((x0 + 24, y0 + 20), title, font=font(24), fill=text + ((160,) if len(text) == 3 else ()))

    out = OUT / "mock-final.png"
    canvas.save(out)
    print(out)


if __name__ == "__main__":
    main()
