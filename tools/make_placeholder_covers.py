#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给清单里还没封面的书生成极简文字封面（占位，随时可被真实书封替换）。

豆瓣找不到的书（无对应条目）会走这里，保证书库不会出现「静雅思听」栏目图或空白。
想换成真实封面：把图片放到 tools/covers/<书名>.jpg，再跑一次 fix_metadata.py 即可。

用法：
    python3 tools/make_placeholder_covers.py            # 只补没有封面的书
    python3 tools/make_placeholder_covers.py --all      # 全部重新生成
    python3 tools/make_placeholder_covers.py --book 人类误判心理学
"""

import argparse
import json
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(TOOLS_DIR, "books.json")
COVER_DIR = os.path.join(TOOLS_DIR, "covers")

W, H = 720, 1080

# 系统里可用的中文字体，按优先级探测
FONT_CANDIDATES = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]

# 分类 → 底色/文字色，同一分类的书在网格里看起来成组
PALETTE = {
    "世界史": ("#1F3A5F", "#E8EEF6"),
    "中国史": ("#5B2A2A", "#F6EAE8"),
    "人物": ("#2E4756", "#E9F1F5"),
    "公民课": ("#3A4E2E", "#EEF3E8"),
    "军事": ("#3B3B45", "#F0F0F3"),
    "商业": ("#4A3A22", "#F5EFE4"),
    "心理": ("#33414F", "#EAF0F6"),
    "思维": ("#2B3D3A", "#E8F2EF"),
    "杂谈": ("#42324A", "#F1EAF5"),
    "法律": ("#22384C", "#E7EFF6"),
    "社会": ("#3F4A3C", "#EDF2EA"),
    "纪实": ("#4A4238", "#F4F0E8"),
    "财经": ("#1E3B34", "#E6F1ED"),
}
DEFAULT_COLORS = ("#333A45", "#EFF2F6")


def load_font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        return ImageFont.truetype(path, size)


def pick_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return load_font(path, size)
    return ImageFont.load_default()


def wrap(draw, text, font, max_width):
    """按字符宽度折行（中文没有空格，逐字量）。"""
    lines, line = [], ""
    for ch in text:
        if draw.textlength(line + ch, font=font) <= max_width:
            line += ch
        else:
            lines.append(line)
            line = ch
    if line:
        lines.append(line)
    return lines


def render(title, author, category, out_path):
    bg, fg = PALETTE.get(category, DEFAULT_COLORS)
    img = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(img)

    margin = 88
    max_w = W - margin * 2

    title_font = pick_font(96 if len(title) <= 8 else 76)
    lines = wrap(draw, title, title_font, max_w)
    line_h = int(title_font.size * 1.28)
    block_h = line_h * len(lines)
    top = (H - block_h) // 2 - 40

    y = top
    for line in lines:
        draw.text((margin, y), line, font=title_font, fill=fg)
        y += line_h

    # 书名下方一条细分隔线 + 作者，构成极简排版
    rule_y = y + 24
    draw.line([(margin, rule_y), (margin + 96, rule_y)], fill=fg, width=3)
    author_font = pick_font(44)
    draw.text((margin, rule_y + 34), author, font=author_font, fill=fg)

    cat_font = pick_font(34)
    draw.text((margin, H - 110), category, font=cat_font, fill=fg)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    img.save(out_path, "JPEG", quality=88)


def main():
    ap = argparse.ArgumentParser(description="为缺封面的测试书生成极简文字封面")
    ap.add_argument("--all", action="store_true", help="已有封面的也重新生成")
    ap.add_argument("--book", action="append", default=[], help="只处理指定书名")
    args = ap.parse_args()

    with open(MANIFEST, encoding="utf-8") as f:
        payload = json.load(f)
    books = payload["books"]

    made = 0
    for title, entry in books.items():
        if args.book and title not in args.book:
            continue
        existing = entry.get("cover")
        if existing and not args.all and os.path.exists(os.path.join(TOOLS_DIR, existing)):
            continue
        if entry.get("missing"):
            continue
        out = os.path.join(COVER_DIR, re.sub(r"[/]", "／", title) + ".jpg")
        render(title, entry["author"], entry.get("category", ""), out)
        entry["cover"] = os.path.relpath(out, TOOLS_DIR)
        entry["coverSource"] = "placeholder"
        made += 1
        print(f"🎨 {title} ← 占位封面（{entry.get('category')}）")

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"\n✅ 生成 {made} 张，输出目录 {COVER_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
