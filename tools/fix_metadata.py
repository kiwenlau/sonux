#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 tools/books.json 整理 TestBooks/：书名的目录、章节文件名、ID3 标签与封面。

做四件事：
1. 目录名 → 纯书名（App 用它当书名显示），如「财经-渔阳[乱世华尔街]全29集-有益」→「乱世华尔街」
2. 章节文件名 → 「NN.章节名.mp3」：去掉书名前缀、%2F、【完】等噪声，按解析出的序号重排编号
3. ID3 标签 → UTF-8 重写 TPE1/TPE2=作者、TALB=书名、TIT2=章节名、TCON=分类、TRCK=序号
   （原文件里的标签是 GBK 写成 latin-1 的乱码，App 读到的作者因此是「justing.com.cn」之类）
4. 封面 → 嵌入清单指定的封面；清单没有封面时保留音频原有的内嵌封面

默认只打印计划，加 --apply 才真正改文件。

用法：
    python3 tools/fix_metadata.py                       # 看计划
    python3 tools/fix_metadata.py --apply               # 执行
    python3 tools/fix_metadata.py --book 乱世华尔街 --apply
    python3 tools/fix_metadata.py --apply --no-rename   # 只改标签和文件名，不动目录名
    python3 tools/fix_metadata.py --revert              # 目录名改回清单 sources 里的原名
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from booklib import audio_files, plan_chapters, remove_path, write_tags  # noqa: E402

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(TOOLS_DIR)
BOOKS_DIR = os.path.join(REPO_DIR, "TestBooks")
MANIFEST = os.path.join(TOOLS_DIR, "books.json")


def load():
    with open(MANIFEST, encoding="utf-8") as f:
        return json.load(f)["books"]


def find_source_dir(entry):
    """返回该书当前在 TestBooks/ 下的目录名；找不到返回 None。"""
    for name in [entry["title"]] + list(entry.get("sources", [])):
        path = os.path.join(BOOKS_DIR, name)
        if os.path.isdir(path):
            return name
    return None


def existing_cover(entry, book_dir):
    """封面字节：清单指定 > 音频里已有的内嵌封面（避免整理时把封面弄丢）。"""
    rel = entry.get("cover")
    if rel:
        path = rel if os.path.isabs(rel) else os.path.join(TOOLS_DIR, rel)
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read(), os.path.basename(path)
    from mutagen import File
    for name in audio_files(book_dir)[:3]:
        f = File(os.path.join(book_dir, name))
        pics = f.tags.getall("APIC") if (f and f.tags and hasattr(f.tags, "getall")) else []
        if pics:
            return pics[0].data, f"{name} 原内嵌封面"
    return None, "无封面"


def process(entry, args, report):
    title = entry["title"]
    src_name = find_source_dir(entry)
    if not src_name:
        report["missing"].append(title)
        print(f"⏭️  《{title}》在 TestBooks/ 下找不到目录，跳过")
        return

    book_dir = os.path.join(BOOKS_DIR, src_name)
    plan = plan_chapters(book_dir, title)
    if not plan:
        report["missing"].append(title)
        print(f"⏭️  《{title}》没有音频，跳过")
        return

    cover, cover_note = existing_cover(entry, book_dir)
    total = len(plan)
    renamed = 0
    tagged = 0

    for i, (old, new, chapter_title, index) in enumerate(plan, start=1):
        tags = {
            "artist": entry["author"],
            "album_artist": entry["author"],
            "album": title,
            "title": chapter_title,
            "genre": entry.get("category", ""),
            "publisher": "静雅思听",
            "track": str(index),
        }
        path = os.path.join(book_dir, new if args.apply else old)
        if args.apply:
            # 重命名先做，保证写标签时路径有效
            if old != new:
                tmp = os.path.join(book_dir, f".tmp-{index}-{os.getpid()}{os.path.splitext(old)[1]}")
                os.rename(os.path.join(book_dir, old), tmp)
                if os.path.exists(path):
                    remove_path(path)
                os.rename(tmp, path)
            write_tags(path, tags, cover)
        tagged += 1
        if old != new:
            renamed += 1
        if args.verbose:
            print(f"    {old}  →  {new}")

    dir_renamed = False
    if src_name != title:
        if args.apply and not args.no_rename:
            dst = os.path.join(BOOKS_DIR, title)
            if os.path.exists(dst):
                print(f"⚠️  目标目录已存在，跳过改名：{title}")
            else:
                os.rename(book_dir, dst)
                book_dir = dst
            # 清掉整理过程中残留的空目录与隐藏杂项
            for junk in (".DS_Store", ".qoder", "__MACOSX"):
                p = os.path.join(book_dir, junk)
                if os.path.exists(p):
                    remove_path(p)
        dir_renamed = True

    report["books"].append({
        "title": title,
        "author": entry["author"],
        "chapters": total,
        "renamedFiles": renamed,
        "cover": cover_note,
        "dirRenamed": dir_renamed if not args.no_rename else "跳过",
    })
    flag = "" if cover else "  ⚠️ 无封面"
    print(f"✅ 《{title}》 作者={entry['author']} 章节={total} 改名={renamed} 封面={cover_note}{flag}"
          + ("" if args.apply else "   [dry-run]"))


def revert(entry, args):
    """把目录名改回清单 sources 里的原始名字。"""
    title = entry["title"]
    current = find_source_dir(entry)
    original = next((s for s in entry.get("sources", []) if s != title), None)
    if not current or not original:
        print(f"⏭️  《{title}》无需回退（current={current} original={original}）")
        return
    src = os.path.join(BOOKS_DIR, current)
    dst = os.path.join(BOOKS_DIR, original)
    if os.path.exists(dst):
        print(f"⚠️  目标已存在，跳过：{original}")
        return
    if args.apply:
        os.rename(src, dst)
    print(f"↩️  {current}  →  {original}" + ("" if args.apply else "   [dry-run]"))


def main():
    ap = argparse.ArgumentParser(description="按清单整理测试书库的名称、作者与封面")
    ap.add_argument("--apply", action="store_true", help="真正写文件（默认只打印计划）")
    ap.add_argument("--book", action="append", default=[], help="只处理指定书名，可重复")
    ap.add_argument("--no-rename", action="store_true", help="不改目录名，只改标签与文件名")
    ap.add_argument("--revert", action="store_true", help="把目录名回退成整理前的原名")
    ap.add_argument("--verbose", action="store_true", help="逐章打印文件名变化")
    args = ap.parse_args()

    books = load()
    targets = [b for b in books.values() if not b.get("missing")]
    if args.book:
        targets = [b for b in targets if b["title"] in args.book]

    if args.revert:
        for b in targets:
            revert(b, args)
        return 0

    report = {"books": [], "missing": []}
    for b in targets:
        process(b, args, report)

    covers = sum(1 for r in report["books"] if r["cover"] and "无封面" not in r["cover"])
    files = sum(r["renamedFiles"] for r in report["books"])
    print(f"\n{'已' if args.apply else '待'}处理 {len(report['books'])} 本 / "
          f"{sum(r['chapters'] for r in report['books'])} 章，"
          f"文件名需改 {files} 个，封面 {covers} 本")
    if report["missing"]:
        print("未找到目录：" + "、".join(report["missing"]))
    if not args.apply:
        print("（以上是计划，加 --apply 执行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
