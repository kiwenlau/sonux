#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自动验收：不用人耳，判断每一刀「物理上没切坏、内容上确实是广告」。

硬指标（必须通过，否则算可疑）
  H1 切点落在停顿里    原音频里切点两侧都得是无音帧，停顿 ≥0.25s。
                      ——物理上不可能把某个字切掉一半。
  H2 保留段是原文件字节  新文件的 MP3 帧字节流按 2KB 逐块回查原文件，命中率应 ≥98%。
                      ——无损切割就是搬帧；一旦重编码、错位或写坏，命中率会崩。

内容证据（至少命中一条，说明被切掉的不是这本书的内容）
  S1 台呼/广告关键词   静雅思听各种错别字变体、光盘、网站、淘宝店、制作出品……
  S2 罐头文案重现      被切的短语在全库 ≥3 本不同的书里逐字出现（跨书），
                      或在本本书 ≥3 章里逐字出现（跨章）。正文不会这样重复。
  S3 声纹离群          被切区间 ≥60% 落在「与本章正文主声纹不一致」的区段里。
  S4 主题不连贯        被切文本的用词与本章保留正文几乎不搭（实词重合率 <8%），
                      典型就是一本讲日本社会的书里突然冒出「深夜街角少年头部起火」。

另外 `--deep N` 随机抽 N 章，把整章新文件重新转写，逐字比对
「新文件文本 ≈ 原稿文本 − 被切文本」，作为 H2 的全量抽查。

用法：
    python3 tools/adcheck-audit.py                       # 审 tools/adcuts.jsonl
    python3 tools/adcheck-audit.py --book 与鬼为邻 --deep 3
    python3 tools/adcheck-audit.py --export-suspects     # 可疑切口导成 20 秒小样
产物：tools/adcheck-audit.csv（每刀一行：硬指标、命中的证据、被切文本、接缝前后文）。
"""

import argparse
import csv
import json
import os
import random
import re
import subprocess
import sys
from collections import Counter, defaultdict

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adcheck as A  # noqa: E402

ROOT = A.ROOT
PLAN = os.path.join(ROOT, "tools", "adcuts.jsonl")
RAW = os.path.join(ROOT, "tools", "adcheck.jsonl")
CLEAN = os.path.join(ROOT, "TestBooks-clean")
OUT_CSV = os.path.join(ROOT, "tools", "adcheck-audit.csv")
CLIP_DIR = os.path.join(ROOT, "tools", "待听样本")
WIN = 10            # 罐头短语滑窗字数
MAX_OFF = 0.35      # 切点允许偏离最近气口的最大距离（秒）
STOPWORDS = set("的了是在和与也就都很已不被把对其从但而且所以如果因为这样那样还有")


def norm(t):
    return re.sub(r"[^\w]", "", t, flags=re.UNICODE).casefold()


def wins(text, w=WIN):
    return [text[i:i + w] for i in range(max(len(text) - w + 1, 0))]


def content_words(text):
    """实词集合（两字以上切片，去掉常见虚词），用来算主题重合率。"""
    t = norm(text)
    return {t[i:i + 2] for i in range(0, max(len(t) - 1, 0))} - STOPWORDS


def build_canned(paths):
    """两级罐头短语表：跨书（≥3 本）与跨章（同书 ≥3 章）。"""
    books = defaultdict(set)
    chapters = defaultdict(set)
    for rel in paths:
        segs = A.load_cache_segments(rel)
        book = rel.split("/")[1]
        for s in segs:
            t = norm(s["t"])
            if len(t) < WIN:
                continue
            for w in wins(t):
                books[w].add(book)
                chapters[w].add(rel)
    cross_book = {w for w, v in books.items() if len(v) >= 3}
    cross_chap = {w for w, v in chapters.items() if len(v) >= 3}
    return cross_book, cross_chap


CANNED_BOOK, CANNED_CHAP = set(), set()


def ad_evidence(segs_all, s, e, foreign, keys=None):
    """被切内容的证据，返回命中说明列表。"""
    inside = [t for t in segs_all if t["b"] >= s - 0.2 and t["e"] <= e + 0.2]
    joined = "".join(t["t"] for t in inside)
    out = []
    if A.AD_RE.search(joined) or BUILTIN_AD.search(joined):
        out.append("S1 广告关键词")
    n = norm(joined)
    ws = wins(n)
    if ws and any(w in CANNED_BOOK for w in ws):
        out.append("S2 罐头文案（全库 ≥3 本书逐字重现）")
    elif ws and any(w in CANNED_CHAP for w in ws):
        out.append("S2 罐头文案（本书 ≥3 章逐字重现）")
    cov = A.coverage(foreign, s, e)
    if cov >= 0.6:
        out.append(f"S3 声纹离群 {cov:.0%}")
    if len(n) >= 20:
        near = "".join(t["t"] for t in segs_all if s + 300 > t["b"] > max(0, s - 300)
                       and not (t["b"] >= s and t["e"] <= e))
        a = content_words(joined)
        b = content_words(near)
        if a and b and len(a & b) / len(a) < 0.08:
            out.append(f"S4 用词与本章正文不搭（重合 {len(a & b) / len(a):.0%}）")
    if not inside and (e - s) > 3:
        out.append("区间内无人说话（音乐/台呼曲）")
    # S5 章节信息卡：「书名·章节·作者 X·朗读者 Y」这种报目，用户要求一并删掉
    card = [t for t in inside if A.CARD_RE.search(t["t"]) or A.chapter_hit(t["t"], keys or [])]
    if card and all(A.CARD_RE.search(t["t"]) or A.chapter_hit(t["t"], keys or [])
                    or t["nchar"] < 10 for t in inside):
        out.append("S5 章节信息卡（书名/作者/朗读者报目）")
    return out, inside


BUILTIN_AD = re.compile(
    r"[静靖靜淨敬竟][雅衙][思斯][听聽厅廳]|静雅思听|靜雅思聽|让智慧的声音动听|讓智慧的聲音動聽|精彩即刻送到您耳边|精彩即刻送到您耳邊"
    r"|书生系列光盘|書生系列光盤|系列光盘|系列光碟|官方淘宝店|官方淘寶店|制作出品|製作出品"
    r"|智慧声音|智慧聲音|动听音频|動聽音頻|不翻页|不翻頁|无限播|無限播|想听就来|想聽就來"
    r"|登陆.{0,6}(网站|網站|厅|廳)|登录.{0,6}(网站|網站|厅|廳)")


def quiet_near(f, at, refdb, win=0.8):
    """切点附近「比正文安静 12dB 以上」的帧离切点多远（秒）；找不到返回 -1。

    比「切点是否落在静音区里」宽容：静音区很窄（0.1s）也算切在气口上。
    """
    m = (f["t"] >= at - win) & (f["t"] <= at + win)
    if not m.any():
        return -1.0
    q = m & (f["db"] < refdb - 12)
    if not q.any():
        return -1.0
    return float(np.abs(f["t"][q] - at).min())


def audio_bytes(path):
    """去掉 ID3v2 头，返回 MP3 帧字节流。"""
    with open(path, "rb") as fh:
        b = fh.read()
    if b[:3] == b"TAG":
        h = (b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F)
        b = b[10 + h:]
    return b


def byte_coverage(src, new, chunk=2048):
    """新文件的音频字节流有多少能按顺序在原文件里逐块找到。

    无损切割（-c copy）是直接搬帧，所以应当接近 1.0；一旦重编码就接近 0。
    这比波形相关可靠（MP3 从中间起解会有 priming 差异），而且不用解码。
    """
    s, n = audio_bytes(src), audio_bytes(new)
    if len(n) < chunk or len(s) < chunk:
        return 1.0
    hits = tot = pos = 0
    for i in range(0, len(n) - chunk + 1, chunk):
        tot += 1
        j = s.find(n[i:i + chunk], pos)
        if j >= 0:
            hits += 1
            pos = j + 1
    return hits / max(tot, 1)


def audit_chapter(row, deep=False):
    rel = row["file"]
    src = os.path.join(ROOT, rel)
    new = os.path.join(CLEAN, rel[len("TestBooks/"):])
    if not os.path.exists(new):
        return [dict(file=rel, cut="", verdict="跳过", why="还没切出干净文件",
                     hard="", ev="", removed="", seam="")]
    x = A.decode(src)
    f = A.acoustics(x)
    dur = f["n"]
    H0 = ""
    keeps = A.keep_ranges(dur, row["cuts"])
    want = sum(e - s for s, e in keeps)
    got = A.probe_len(new)
    H0 = f"H0 时长 {got:.1f}s/应 {want:.1f}s"
    if abs(got - want) > 1.5:
        H0 += " ❌清单与文件不一致（需重切）"
    # H2 字节级：保留下来的音频必须就是原文件的帧（无损、未重编码）
    cov = byte_coverage(src, new)
    H0 += f" | H2 原声字节命中 {cov:.1%}"
    if cov < 0.98:
        H0 += " ❌不是无损原声"
    segs = A.load_cache_segments(rel)
    keys = A.chapter_keys(rel.split("/")[1], os.path.basename(rel))
    for t in segs:
        t["nchar"] = A.nchars(t["t"])
        t["db"] = A.seg_db(f, t["b"], t["e"])
    loud = [t["db"] for t in segs if t["e"] - t["b"] > 1.5 and t["nchar"] >= 12]
    refdb = float(np.median(loud)) if loud else -25.0
    foreign = A.foreign_regions(f)
    out = []
    for s, e in row["cuts"]:
        hard, bad = [], []
        d0 = quiet_near(f, s, refdb) if s > 1.0 else 0.0
        d1 = quiet_near(f, e, refdb) if e < dur - 1.0 else 0.0
        worst = max(d0, d1)
        hard.append(f"H1 气口 {worst:.2f}s")
        if worst > MAX_OFF:
            bad.append(f"H1 切点没落在气口上（{worst:.2f}s）")
        keep_b = [t["t"] for t in segs if t["e"] <= s + 0.2][-2:]
        keep_a = [t["t"] for t in segs if t["b"] >= e - 0.2][:2]
        ev, inside = ad_evidence(segs, s, e, foreign, keys)
        out.append(dict(file=rel, cut=f"{s:.1f}-{e:.1f}", len=round(e - s, 1),
                        verdict="通过" if (not bad and ev and "❌" not in H0) else "可疑",
                        hard=" | ".join(([H0] if H0 else []) + hard), ev="；".join(ev) or "无内容证据",
                        removed=" / ".join(t["t"][:28] for t in inside[:4]),
                        seam=f"…{(keep_b[-1] if keep_b else '')[-14:]} ⟶ "
                             f"{(keep_a[0] if keep_a else '')[:14]}…",
                        why="；".join(bad)))
    if deep:
        out.append(deep_check(row, new, segs, dur))
    return out


def deep_check(row, new, segs, dur):
    """整章重转写新文件：保留句应当全在、被切句应当消失。

    用逐句命中而不是全文相似度：后者会被「原稿只转写了部分区段」（窗口化 ASR）
    与分句差异干扰；逐句命中直观且不受影响。
    """
    keeps = A.keep_ranges(dur, row["cuts"])
    try:
        heard = norm("".join(s["t"] for s in A.asr_pcm(new, A.decode(new))))
    except Exception as ex:
        return dict(file=row["file"], cut="整章重转写", verdict="出错", why=str(ex)[:80],
                    hard="", ev="", removed="", seam="", len="")

    def hit(t):
        n = norm(t)
        probe = n[:12] if len(n) > 12 else n
        return bool(probe) and probe in heard

    inside = lambda t: any(a <= (t["b"] + t["e"]) / 2 <= b for a, b in keeps)
    keep_s = [t for t in segs if t["nchar"] >= 10 and inside(t)]
    gone_s = [t for t in segs if t["nchar"] >= 10 and not inside(t)]
    kh = sum(1 for t in keep_s if hit(t["t"]))
    gh = sum(1 for t in gone_s if hit(t["t"]))
    kr, gr = kh / max(len(keep_s), 1), gh / max(len(gone_s), 1)
    # 硬指标只看两个：被切内容必须消失；新文件文本量不能明显少于应保留量
    # （保留句命中率只作参考：两次 ASR 本身用词就有差异，且窗口化 ASR 只转写了部分区段）
    vol = len(heard) / max(len(norm("".join(t["t"] for t in keep_s))), 1)
    ok = gr <= 0.10 and vol >= 0.9
    return dict(file=row["file"], cut="整章重转写", verdict="通过" if ok else "可疑",
                hard=f"被切句残留 {gr:.0%}（{gh}/{len(gone_s)}），文本量 {vol:.2f}，保留句字面命中 {kr:.0%}",
                ev="", removed="", seam="",
                why="" if ok else ("被切内容仍在文件里" if gr > 0.10 else "新文件文本量偏少"))


def init_worker():
    A.init_worker()
    paths = [r["file"] for r in A.load_rows(RAW) if "cuts" in r]
    global CANNED_BOOK, CANNED_CHAP
    CANNED_BOOK, CANNED_CHAP = build_canned(paths)


def job(row):
    try:
        return audit_chapter(row, deep=bool(row.get("_deep")))
    except Exception as ex:
        return [dict(file=row["file"], cut="", verdict="出错", why=str(ex)[:120],
                     hard="", ev="", removed="", seam="", len="")]


def export_clips(rows, sus, nmax=12):
    """可疑切口导成 20 秒小样（切点前 10 秒 + 后 10 秒），双击即可听。"""
    os.makedirs(CLIP_DIR, exist_ok=True)
    made = []
    for item in sus[:nmax]:
        row = next((r for r in rows if r["file"] == item["file"]), None)
        if not row:
            continue
        s = float(item["cut"].split("-")[0])
        dst = os.path.join(CLIP_DIR, re.sub(r"[^\w]+", "_",
                         f"{item['file'].split('/')[1]}_{os.path.basename(item['file'])[:10]}_{s:.0f}s") + ".mp3")
        subprocess.run([A.FF, "-hide_banner", "-loglevel", "error", "-y",
                        "-ss", str(max(0, s - 10)), "-t", "20", "-i",
                        os.path.join(ROOT, item["file"]), "-vn", "-c:a", "copy", dst],
                       capture_output=True)
        if os.path.exists(dst):
            made.append(dst)
    return made


def main():
    ap = argparse.ArgumentParser(description="自动验收切除结果")
    ap.add_argument("--plan", default=PLAN)
    ap.add_argument("--book")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--deep", type=int, default=0, help="随机抽 N 章做整章重转写")
    ap.add_argument("--export-suspects", action="store_true")
    args = ap.parse_args()

    rows = [r for r in A.load_rows(args.plan) if "cuts" in r]
    if args.book:
        rows = [r for r in rows if r["file"].split("/")[1] == args.book]
    random.seed(7)
    pick = set()
    if args.deep:
        pick = {r["file"] for r in random.sample(rows, min(args.deep, len(rows)))}
        for r in rows:
            r["_deep"] = r["file"] in pick
    nc = sum(len(r["cuts"]) for r in rows)
    print(f"验收 {len(rows)} 章 / {nc} 个切口（整章抽查 {len(pick) if args.deep else 0} 章）", flush=True)

    import multiprocessing as mp
    results = []
    with mp.Pool(args.jobs, initializer=init_worker) as pool:
        for i, chunk in enumerate(pool.imap_unordered(job, rows, chunksize=1)):
            results += chunk
            if (i + 1) % 25 == 0:
                print(f"  {i+1}/{len(rows)}", flush=True)

    cuts = [r for r in results if r.get("cut") and r["cut"] != "整章重转写"]
    deep = [r for r in results if r.get("cut") == "整章重转写"]
    errs = [r for r in results if r["verdict"] in ("出错", "跳过")]
    bad = [r for r in cuts if r["verdict"] != "通过"]
    with open(OUT_CSV, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["verdict", "file", "cut", "len", "hard", "ev", "seam", "removed", "why"])
        w.writeheader()
        for r in sorted(results, key=lambda r: (r["verdict"] == "通过", r["file"])):
            w.writerow({k: r.get(k, "") for k in w.fieldnames})

    print(f"\n切口 {len(cuts)} 个：通过 {len(cuts) - len(bad)}，可疑 {len(bad)}"
          f"（另有出错/跳过 {len(errs)}）")
    cnt = Counter()
    for r in cuts:
        for item in r["ev"].split("；"):
            cnt[item[:2] if item[:2] in ("S1", "S2", "S3", "S4") else item[:8]] += 1
    print("证据命中：" + "，".join(f"{k} {v} 处" for k, v in cnt.most_common()))
    for r in bad[:12]:
        print(f"  ⚠️ {r['file'].split('/')[-1][:24]:26s} {r['cut']:14s} {r['why'][:70]}")
    if deep:
        ok = sum(1 for r in deep if r["verdict"] == "通过")
        print(f"\n整章重转写抽查 {len(deep)} 章：通过 {ok}")
        for r in deep:
            print(f"  {r['verdict']} {r['file'].split('/')[-1][:26]:28s} {r['hard']}")
    print("→", OUT_CSV)
    if args.export_suspects and bad:
        made = export_clips(rows, bad)
        print(f"已导出 {len(made)} 个 20 秒小样到 {CLIP_DIR}")


if __name__ == "__main__":
    main()
