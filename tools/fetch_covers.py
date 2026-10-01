#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从豆瓣读书按书名+作者抓封面，结果写进 tools/books.json 与 tools/covers/。

用豆瓣的联想接口 book.douban.com/j/subject_suggest 搜候选，按「书名一致 + 作者对得上」
打分挑一个最靠谱的，再把小图 URL 换成大图下载到 tools/covers/<书名>.jpg，
同时把豆瓣条目 id / 标题 / 作者 / 匹配分写回清单的 douban 字段，便于人工复核。

用法：
    python3 tools/fetch_covers.py                  # 抓所有还没有封面的书
    python3 tools/fetch_covers.py --all            # 全部重抓
    python3 tools/fetch_covers.py --book 乱世华尔街  # 只处理某一本
    python3 tools/fetch_covers.py --dry-run        # 只看匹配结果，不下载
    python3 tools/fetch_covers.py --min-score 5    # 提高匹配门槛（默认 3）
"""

import argparse
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(TOOLS_DIR)
MANIFEST = os.path.join(TOOLS_DIR, "books.json")
COVER_DIR = os.path.join(TOOLS_DIR, "covers")

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
SUGGEST = "https://book.douban.com/j/subject_suggest?q={}"
TIMEOUT = 15


def norm(s):
    """比较用：全半角归一、去标点、转小写。"""
    s = unicodedata.normalize("NFKC", s or "").lower()
    return re.sub(r"[\s·・．.。，,、:：!！?？\-—_《》〈〉\"'“”‘’()（）\[\]]", "", s)


def authors_of(s):
    """把「彼得·德鲁克」「唐德刚 张某某」拆成规范化后的名字集合。"""
    parts = re.split(r"[、,，/&和与\s·]+", s or "")
    return {norm(p) for p in parts if norm(p)}


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://book.douban.com/"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def fetch_bytes(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://book.douban.com/"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def score(candidate, title, author):
    """匹配分：书名相等 3 分，包含 1 分；作者对得上 2 分，作者互为包含 1 分。"""
    ct, ca = candidate.get("title", ""), candidate.get("author_name", "")
    nt = norm(title)
    if nt and nt == norm(ct):
        s = 3.0
    elif nt and (nt in norm(ct) or norm(ct) in nt):
        s = 1.0
    else:
        return 0.0
    want = authors_of(author)
    cand_authors = authors_of(ca)
    if cand_authors & want:
        s += 2
    elif any(a and b and (a in b or b in a) for a in want for b in cand_authors):
        s += 1          # 「日本读卖新闻」 vs 「日本读卖新闻战争责任检证委员会」
    elif not cand_authors:
        s += 0.5
    return s


def search_queries(entry):
    """豆瓣搜索词：清单里的 query 优先，否则用全名 + 冒号/破折号前的短名。"""
    override = entry.get("query")
    if override:
        return [override] if isinstance(override, str) else list(override)
    title = entry["title"]
    queries = [title]
    short = re.split(r"[：:—\-·]", title)[0].strip()
    if short and short != title:
        queries.append(short)
    return queries


def by_subject_id(subject_id):
    """按豆瓣条目 id 直接取条目（名称/作者/大图），用于清单里人工指定的情形。"""
    url = f"https://book.douban.com/subject/{subject_id}/"
    try:
        html = fetch_bytes(url).decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"    条目页抓取失败（{subject_id}）：{e}")
        return None
    pic = re.search(r'<meta property="og:image" content="([^"]+)"', html)
    title = re.search(r"<title>\s*(.+?)\s*[（(]", html)
    author = re.search(r'<meta name="description" content="[^"]*?作者[：:]\s*([^，,\s]+)', html)
    if not pic:
        return None
    return {
        "title": (title.group(1) if title else "").strip(),
        "author_name": (author.group(1) if author else "").strip(),
        "pic": pic.group(1),
        "url": url,
        "id": str(subject_id),
        "type": "b",
    }


def best_match(entry):
    if entry.get("doubanId"):
        c = by_subject_id(entry["doubanId"])
        return (c, 5.0) if c else (None, 0.0)
    best, best_score = None, 0.0
    for q in search_queries(entry):
        try:
            candidates = fetch_json(SUGGEST.format(urllib.parse.quote(q)))
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
            print(f"    网络失败（{q}）：{e}")
            return None, 0.0
        for c in candidates or []:
            if c.get("type") != "b":
                continue
            s = score(c, entry["title"], entry["author"])
            if s > best_score:
                best, best_score = c, s
        if best_score >= 3:
            break
        time.sleep(0.4)
    return best, best_score


def large_pic(pic):
    """豆瓣 /subject/s/ 小图换 /subject/l/ 大图。"""
    return pic.replace("/subject/s/", "/subject/l/") if pic else ""


def og_image(subject_url):
    """条目页里的 og:image（大图），作为 /l/ 地址失效时的兜底。"""
    if not subject_url:
        return ""
    try:
        html = fetch_bytes(subject_url).decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError):
        return ""
    m = re.search(r'<meta property="og:image" content="([^"]+)"', html)
    return m.group(1) if m else ""


def download(entry, candidate, min_score):
    """下载封面到 covers/<书名>.jpg，返回 (状态, 说明)。"""
    score_value = score(candidate, entry["title"], entry["author"])
    if score_value < min_score:
        return "low", f"匹配分 {score_value} 偏低：{candidate.get('title')} / {candidate.get('author_name')}"

    target = os.path.join(COVER_DIR, re.sub(r"[/]", "／", entry["title"]) + ".jpg")
    pic = candidate.get("pic", "")
    for url in (large_pic(pic), pic, og_image(candidate.get("url", ""))):
        if not url:
            continue
        try:
            data = fetch_bytes(url)
        except (urllib.error.URLError, TimeoutError) as e:
            print(f"    下载失败（{url}）：{e}")
            continue
        if len(data) < 4096:
            continue
        os.makedirs(COVER_DIR, exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
        return "ok", f"{len(data) // 1024}KB ← {candidate.get('title')}（{candidate.get('author_name')}）{url}"
    return "nopic", f"候选无可用封面：{candidate.get('url')}"


def main():
    ap = argparse.ArgumentParser(description="从豆瓣抓测试书封面")
    ap.add_argument("--all", action="store_true", help="已有封面的也重抓")
    ap.add_argument("--book", action="append", default=[], help="只处理指定书名，可重复")
    ap.add_argument("--min-score", type=float, default=3.0, help="接受的最低匹配分（默认 3）")
    ap.add_argument("--dry-run", action="store_true", help="只匹配不下载")
    ap.add_argument("--sleep", type=float, default=0.8, help="每本之间的间隔秒数")
    args = ap.parse_args()

    with open(MANIFEST, encoding="utf-8") as f:
        payload = json.load(f)
    books = payload["books"]

    done = failed = skipped = 0
    for title, entry in books.items():
        if args.book and title not in args.book:
            continue
        if entry.get("missing"):
            continue
        if not args.all and entry.get("cover") and os.path.exists(os.path.join(TOOLS_DIR, entry["cover"])):
            skipped += 1
            continue

        print(f"《{title}》 作者={entry['author']}")
        candidate, _ = best_match(entry)
        if not candidate:
            print("    ❌ 豆瓣无匹配结果")
            entry["douban"] = {"queried": True, "found": False}
            failed += 1
            time.sleep(args.sleep)
            continue
        # 清单里人工指定了搜索词或条目 id：不再卡匹配分
        gate = 0.0 if (entry.get("doubanId") or entry.get("query")) else args.min_score

        if args.dry_run:
            print(f"    → {candidate['title']} / {candidate.get('author_name')} "
                  f"score={score(candidate, title, entry['author'])} {candidate['url']}")
            time.sleep(args.sleep)
            continue

        status, note = download(entry, candidate, gate)
        entry["douban"] = {
            "id": candidate.get("id"),
            "url": candidate.get("url"),
            "doubanTitle": candidate.get("title"),
            "doubanAuthor": candidate.get("author_name"),
            "score": score(candidate, title, entry["author"]),
        }
        if status == "ok":
            entry["cover"] = os.path.relpath(os.path.join(COVER_DIR,
                                     re.sub(r"[/]", "／", title) + ".jpg"), TOOLS_DIR)
            entry["coverSource"] = "douban"
            done += 1
        else:
            if status == "nopic":
                entry.pop("cover", None)
            failed += 1
        print(f"    {'✅' if status == 'ok' else '⚠️ '} {note}")
        time.sleep(args.sleep)

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"\n完成：抓到 {done}，未确认 {failed}，跳过 {skipped}（清单：{MANIFEST}）")
    if failed:
        print("未确认的书请人工核对，可直接把封面放到 tools/covers/<书名>.jpg 并在清单里写 \"cover\" 字段。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
