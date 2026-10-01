#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描 TestBooks/ 的目录名，生成/更新元数据清单 tools/books.json。

目录名格式：分类-作者[书名](节选-)?全N集-朗读者
清单是「期望状态」，后续 fetch_covers.py / fix_metadata.py 都以它为准；
重复运行只补充新书与缺失字段，不会覆盖已有的豆瓣结果和人工修订。

用法：
    python3 tools/scan_books.py            # 生成/更新清单
    python3 tools/scan_books.py --check    # 只校验，有差异时退出码非 0
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from booklib import audio_files, parse_folder_name  # noqa: E402

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(TOOLS_DIR)
BOOKS_DIR = os.path.join(REPO_DIR, "TestBooks")
MANIFEST = os.path.join(TOOLS_DIR, "books.json")


def scan(known):
    """从目录名解析出每本书的字段，返回 {书名: 条目}。

    known 是已有清单：目录已经是规范后的纯书名（解析不出格式）时，按书名认账。
    """
    found = {}
    for name in sorted(os.listdir(BOOKS_DIR)):
        path = os.path.join(BOOKS_DIR, name)
        if not os.path.isdir(path) or name.startswith("."):
            continue
        info = parse_folder_name(name)
        if not info:
            prev = known.get(name)
            if prev and not prev.get("missing"):
                # 已经整理过目录名的书：只刷新目录名与音频数
                count = len(audio_files(path))
                if count:
                    found[name] = {**prev, "missing": False, "episodes": count, "sources": [name]}
                continue
            print(f"⚠️  目录名既不符合「分类-作者[书名]全N集-朗读者」也不在清单里，跳过：{name}")
            continue
        count = len(audio_files(path))
        if count == 0:
            print(f"⚠️  没有音频文件，跳过：{name}")
            continue
        if count != info["episodes"]:
            print(f"ℹ️  《{info['title']}》目录名写 {info['episodes']} 集，实际 {count} 个音频")
        found[info["title"]] = {
            "title": info["title"],
            "author": info["author"],
            "category": info["category"],
            "narrator": info["narrator"],
            "abridged": info["abridged"],
            "episodes": count,
            "sources": [name],
        }
    return found


def merge(old, new):
    """把扫描结果并入已有清单：sources 取并集，人工改过的字段以清单为准。"""
    # 清单里人工改过书名时按新名找不到，所以再用旧目录名建一层索引
    by_source = {}
    for title, prev in old.items():
        for s in prev.get("sources", []):
            by_source[s] = (title, prev)

    merged = {}
    for title, entry in new.items():
        prev = old.get(title)
        if prev is None:
            for s in entry["sources"]:
                if s in by_source:
                    prev = by_source[s][1]
                    break
        prev = prev or {}
        sources = list(dict.fromkeys(prev.get("sources", []) + entry["sources"]))
        item = {**prev, **entry, "sources": sources}
        item.pop("missing", None)
        # 人工在清单里改过的字段优先
        for key in ("title", "author", "category", "narrator", "chapterPrefixes"):
            if prev.get(key) and prev[key] != entry.get(key):
                item[key] = prev[key]
        for key in ("douban", "cover"):
            if prev.get(key):
                item[key] = prev[key]
        merged[item["title"]] = item
    # 清单里有、目录里已经没有了的书：保留记录，便于回滚定位
    for title, prev in old.items():
        if title not in merged:
            merged[title] = {**prev, "missing": True}
    return merged


def main():
    ap = argparse.ArgumentParser(description="扫描测试书库目录名，生成 tools/books.json")
    ap.add_argument("--check", action="store_true", help="只比较清单与磁盘，不写文件")
    args = ap.parse_args()

    old = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            old = json.load(f).get("books", {})

    scanned = scan(old)
    books = merge(old, scanned)

    if args.check:
        stale = [t for t, b in books.items() if b.get("missing")]
        print(f"清单 {len(books)} 本，磁盘 {len(scanned)} 本，缺失 {len(stale)} 本")
        for t in stale:
            print(f"  缺：{t}")
        return 1 if stale else 0

    payload = {"version": 1, "books": books}
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"\n✅ 清单已写入 {MANIFEST}（{len(books)} 本）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
