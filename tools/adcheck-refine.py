#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""二次精炼：用「罐头文案」把正文中间的插播广告做实。

为什么要这一步：adcheck 第一遍靠「声纹离群 + 关键词」，两者都会误报——
正文里一句被当成异声的长句、商业书里正常提到「广告/淘宝」，都可能被误切。
而广告是罐头素材：同一条口播会在同一本书的很多章里逐字重现，正文却绝不会这样重复。
于是把每章的 ASR 文本切成滑窗短语，统计它在多少个不同章节出现过：
出现 ≥3 章的短语就是罐头素材（台呼、口播广告、信息卡），它所在的区间才允许切。

注意不能拿声学指纹当重复证据：同一个朗读者、同一套录音设备，两段不同正文的
MFCC 也会高度相关（实测会把「根据宪法……」这类正文误判成重复广告）。

中间插播只在满足其一时才切：命中广告关键词 / 整段无语音（纯音乐）/ 罐头文案重现。
片头片尾沿用 adcheck 的边缘走查规则。

用法：
    python3 tools/adcheck-refine.py                 # 全库（读 adcheck.jsonl + ASR 缓存）
    python3 tools/adcheck-refine.py --book 大败局
    python3 tools/adcheck-refine.py --ads           # 顺带打印每本书的罐头素材台账
产物：tools/adcuts.jsonl（adcut-apply.py 直接吃）+ tools/adcheck-ads.jsonl。
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adcheck as A  # noqa: E402

RAW = os.path.join(A.ROOT, "tools", "adcheck.jsonl")
OUT = os.path.join(A.ROOT, "tools", "adcuts.jsonl")
ADS = os.path.join(A.ROOT, "tools", "adcheck-ads.jsonl")
WIN = 10               # 滑窗长度（字）
MIN_BOOK_CHAPTERS = 3  # 少于 3 章的书不做罐头判定（样本太小，容易把正文当广告）


def cut_text(s):
    """归一化 ASR 文本，只留汉字/字母数字，便于跨章比对。"""
    return A.norm(s.get("t", ""))


def windows_of(text, w=WIN):
    return [text[i:i + w] for i in range(0, max(len(text) - w + 1, 1))] if len(text) >= w else []


def core_span(labels, foreign, lo, hi):
    """两句正文之间，真正属于广告的核心段（声纹离群区 ∪ 带标签句）。

    不直接把两句正文之间全切：那里往往开头还有一句正文，只因广告把它顶开了。
    """
    iv = [(max(lo, r0), min(hi, r1)) for r0, r1, _, _ in foreign if r1 > lo and r0 < hi]
    iv += [(max(lo, s["a"]), min(hi, s["b"])) for s in labels
           if s["lab"] != "body" and s["why"] and s["b"] > lo and s["a"] < hi]
    iv = [(a, b) for a, b in iv if b > a]
    if not iv:
        return None
    iv.sort()
    merged = [list(iv[0])]
    for a, b in iv[1:]:
        if a <= merged[-1][1] + 3.0:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return max(merged, key=lambda x: x[1] - x[0])


def scan_chapter(path):
    """单章：声纹离群区 + 句段标签 + 片头/片尾区间 + 中间候选区。"""
    p = path if os.path.isabs(path) else os.path.join(A.ROOT, path)
    rel = os.path.relpath(p, A.ROOT)
    cache = A.cache_path(p)
    if not os.path.exists(cache):
        return dict(file=rel, error="无 ASR 缓存")
    x = A.decode(p)
    dur = len(x) / A.SR
    f = A.acoustics(x)
    foreign = A.foreign_regions(f)
    gaps = A.silence_mids(f, min_gap=0.15)
    segs = json.load(open(cache))
    book_dir = os.path.basename(os.path.dirname(p))
    labels = A.label_segments(segs, f, foreign, A.chapter_keys(book_dir, os.path.basename(p)))
    ref = [s["db"] for s in labels if s["lab"] == "body" and s["nchar"] >= 8]
    f["refdb"] = float(np.median(ref)) if ref else -99.0
    head, hev = A.edge_cut(labels, foreign, gaps, dur, "head", A.HEAD_WINDOW, keep_card=False, f=f)
    tail, tev = A.edge_cut(labels, foreign, gaps, dur, "tail", A.TAIL_WINDOW, keep_card=False, f=f)

    body = [i for i, s in enumerate(labels) if s["lab"] == "body" and s["nchar"] >= 8]
    mids = []
    for i in range(1, len(body)):
        lo, hi = labels[body[i - 1]]["b"], labels[body[i]]["a"]
        if not (6 <= hi - lo <= 240):
            continue
        if (head and hi <= head[1] + 1.0) or (tail and lo >= tail[0] - 1.0):
            continue                      # 已被片头/片尾盖住
        inside = [s for s in labels if s["b"] > lo + 0.2 and s["a"] < hi - 0.2]
        kw = [s for s in inside if s["lab"] == "ad" and any("关键词" in w for w in s["why"])]
        cov = A.coverage(foreign, lo, hi)
        # 区间里若有一句「长、响亮」的散文式句子，就别切；按文本特征判，
        # 不看 lab——因为 lab 本身就是被声纹标签带偏的（循环论证会误删正文）
        def prose(s):
            return s["nchar"] >= 12 and s["db"] > f["refdb"] - 8 and not A.AD_RE.search(s["t"])
        real = [s for s in inside if prose(s)]
        if real and cov < 0.85:
            continue
        m0 = (f["t"] >= lo) & (f["t"] < hi)
        loud = float(np.percentile(f["db"][m0], 90)) if m0.sum() > 10 else -99.0
        core = core_span(labels, foreign, lo, hi) or [lo, hi]
        ca = A.snap(gaps, core[0], max(0, core[0] - 8), core[0] + 8)
        cb = A.snap(gaps, core[1], core[1] - 8, min(dur, core[1] + 8))
        if cb - ca < 6:
            continue
        ccov = A.coverage(foreign, ca, cb)
        core_in = [s for s in labels if s["b"] > ca + 0.2 and s["a"] < cb - 0.2]
        real_core = [s for s in core_in if prose(s)]
        # 核心段里得「有人在说话」才当插播广告；没人说话的只是配乐间奏/长停顿，切它没意义还有风险
        n_core_txt = sum(1 for s in core_in if s["nchar"] >= 4)
        mids.append(dict(a=round(ca, 2),
                         b=round(cb, 2),
                         cov=round(cov, 2), ccov=round(ccov, 2),
                         real_core=bool(real_core), ntxt=n_core_txt,
                         kw=[s["t"][:40] for s in kw[:3]],
                         # 「无语音」还必须有声响且声纹不离群：ASR 只跑片头/片尾/离群区，
                         # 未覆盖区段本来就没文字，不能当成音乐
                         music=(not inside) and loud > f["refdb"] - 12 and cov >= 0.5,
                         txt=" / ".join(s["t"][:26] for s in inside[:3]),
                         wsets=[cut_text(s) for s in inside if s["b"] > ca and s["a"] < cb]))
    # 全章文本的滑窗（用来统计罐头短语）；片头各句单独留窗口，便于后续延伸片头切点
    allw, headsegs = set(), []
    for s in labels:
        t = cut_text(s)
        if len(t) >= WIN:
            ws = windows_of(t)
            allw.update(ws)
            if s["a"] < 170:
                headsegs.append([s["a"], s["b"], ws, s["lab"]])
    return dict(file=rel, dur=round(dur, 1), book=book_dir, head=head, hev=hev,
                tail=tail, tev=tev, mids=mids, allw=sorted(allw), headsegs=headsegs,
                seglab=[[s["a"], s["b"], s["lab"], s["nchar"]] for s in labels])


def canned_map(items):
    """统计每个滑窗短语出现在多少个不同章节里。"""
    where = defaultdict(set)
    for it in items:
        for w in it["allw"]:
            where[w].add(it["file"])
    min_ch = MIN_BOOK_CHAPTERS if len(items) >= 5 else 2
    return {w: len(fs) for w, fs in where.items() if len(fs) >= min_ch}


def canned_head(labels_head, canned, dur):
    """片头延伸：从第一句起，只要这句含「本书多章重现的罐头短语」或是广告/卡片标签，
    就继续往裡吃；碰到真正的正文就停。能搭出同一位朗读者念的、声纹并不离群的宣传。"""
    end = None
    for a, b, ws, lab in labels_head:
        hit = any(w in canned for w in ws)
        tagged = lab in ("ad", "music", "card")
        if hit or tagged:
            end = b
        else:
            break
    if end is None or end < 4 or end > 150:
        return None, []
    return end, [f"片头延伸至 {end:.0f}s（开头连续多句含罐头文案）"]


def finalize(items, ads_out):
    canned = canned_map(items)
    rows = []
    for it in items:
        cuts, ev = [], []
        # 片头：边缘走查的结果与「罐头文案延伸」取更远的一个
        head = list(it["head"]) if it["head"] else None
        hev = list(it["hev"])
        hc, hev_c = canned_head(it.get("headsegs", []), canned, it["dur"])
        if hc and (head is None or hc > head[1]):
            head, hev = [0.0, hc], hev + hev_c
        if head:
            cuts.append([head[0], head[1]])
            ev += hev
        if it["tail"]:
            cuts.append(list(it["tail"]))
            ev += it["tev"]
        nmid = 0
        for m in it["mids"]:
            hits = [(w, n) for t in m["wsets"] for w in windows_of(t)
                    if (n := canned.get(w)) and len(w) >= WIN]
            why = []
            if hits:
                n = max(h[1] for h in hits)
                why.append(f"罐头文案（{len(hits)} 个短语在本书 {n} 章中重现）")
            if m["kw"]:
                why.append("文案关键词：" + "；".join(m["kw"])[:60])
            if m["ccov"] >= 0.85 and not m["real_core"] and m["ntxt"] >= 1 \
                    and m["b"] - m["a"] >= 8:
                why.append(f"核心段声纹离群 {m['ccov']:.0%}（有口播、无正文句混入）")
            # 注：没人说话的异声区（配乐间奏）不切，避免误伤正文与无谓抖动
            if not why:
                continue
            cuts.append([m["a"], m["b"]])
            nmid += 1
            ev.append(f"中间插播 {m['a']:.0f}-{m['b']:.0f}s 声纹覆盖 {m['cov']:.0%} :: " + " ; ".join(why))
            if hits:
                ads_out.append(dict(book=it["book"], file=it["file"], a=m["a"], b=m["b"],
                                    chapters=max(h[1] for h in hits),
                                    phrase=max((h[0] for h in hits), key=len), txt=m["txt"]))
        merged = []
        for s, e in sorted([list(map(float, c)) for c in cuts]):
            if merged and s <= merged[-1][1] + 0.2:
                merged[-1][1] = max(merged[-1][1], e)
            else:
                merged.append([s, e])
        cut = round(sum(e - s for s, e in merged), 1)
        rows.append(dict(file=it["file"], dur=it["dur"],
                         cuts=[[round(s, 2), round(e, 2)] for s, e in merged],
                         cut_sec=cut, cut_pct=round(100 * cut / max(it["dur"], 1), 1),
                         evidence=ev[:14], needs_review=cut / max(it["dur"], 1) > A.MAX_CUT_RATIO,
                         asr=True, nseg=len(it["seglab"]),
                         nbody=sum(1 for s in it["seglab"] if s[2] == "body"), mid_cuts=nmid))
    return rows


def main():
    ap = argparse.ArgumentParser(description="用罐头文案精炼中间插播判定")
    ap.add_argument("--raw", default=RAW)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--book")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--ads", action="store_true")
    args = ap.parse_args()

    files, seen = [], set()
    for line in open(args.raw):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if "cuts" in r and (not args.book or r["file"].split("/")[1] == args.book):
            if r["file"] in seen:
                continue                        # 多轮重跑可能留下重复行
            seen.add(r["file"])
            files.append(r["file"])
    print(f"待精炼 {len(files)} 章", flush=True)

    import multiprocessing as mp
    items = []
    with mp.Pool(args.jobs) as pool:
        for i, it in enumerate(pool.imap(scan_chapter, files, chunksize=2)):
            if "error" in it:
                print("⚠️", it["file"], it["error"], flush=True)
                continue
            items.append(it)
            if (i + 1) % 50 == 0:
                print(f"  {i+1}/{len(files)}", flush=True)

    by_book = defaultdict(list)
    for it in items:
        by_book[it["book"]].append(it)
    ads, rows = [], []
    for book, group in sorted(by_book.items()):
        rows += finalize(group, ads)
        n = sum(1 for a in ads if a["book"] == book)
        print(f"  {book[:24]:26s} {len(group):3d} 章  罐头素材命中 {n} 处", flush=True)
    rows.sort(key=lambda r: r["file"])
    with open(args.out, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(ADS, "w") as fh:
        for a in ads:
            fh.write(json.dumps(a, ensure_ascii=False) + "\n")

    tot = sum(r["cut_sec"] for r in rows)
    dur = sum(r["dur"] for r in rows)
    if rows:
        print(f"\n{len(rows)} 章 → 切除 {tot/3600:.1f}h / {dur/3600:.1f}h = {100*tot/dur:.1f}%，"
              f"平均每章 {tot/len(rows):.0f}s；中间插播 {sum(r['mid_cuts'] for r in rows)} 处"
              f"（罐头文案确认 {len(ads)} 处）")
    print("→", args.out)
    if args.ads:
        led = defaultdict(list)
        for a in ads:
            led[(a["book"], a["phrase"][:14])].append(a)
        print("\n罐头素材台账（书 / 代表短语 / 命中章数）：")
        for (book, ph), lst in sorted(led.items(), key=lambda kv: -max(x["chapters"] for x in kv[1]))[:30]:
            print(f"  {book[:18]:20s} {max(x['chapters'] for x in lst):3d} 章  "
                  f"{len({x['file'] for x in lst}):3d} 处  {ph}｜{lst[0]['txt'][:40]}")


if __name__ == "__main__":
    main()
