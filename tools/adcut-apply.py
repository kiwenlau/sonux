#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 tools/adcheck.jsonl 的清单，无损切掉有声书里的广告/台呼/信息卡，产出干净文件。

切割方式：保留区间逐段用 `ffmpeg -c copy` 抽出（MP3 帧边界，误差 ~26ms，不重编码不掉音质），
再用 concat 封装器拼成一个文件；最后把原文件的 ID3 标签与内嵌封面整份复制过去，
保证 App 读到的书名/作者/封面不变。

用法：
    python3 tools/adcut-apply.py --book 大败局                  # 只打印计划（dry-run）
    python3 tools/adcut-apply.py --book 大败局 --apply          # 切到 TestBooks-clean/
    python3 tools/adcut-apply.py --all --apply --jobs 4         # 全库
    python3 tools/adcut-apply.py --verify 12                    # 抽查切好的文件边界
    python3 tools/adcut-apply.py --promote                      # 用干净文件替换 TestBooks/ 原文件

产物：TestBooks-clean/<书名>/<章节.mp3>；审核清单 tools/adcut-report.csv。
原始 TestBooks/ 不动，--promote 前请先试听抽查。
"""

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adcheck import FF, ROOT, SR, decode, keep_ranges  # noqa: E402

SRC_ROOT = os.path.join(ROOT, "TestBooks")
DST_ROOT = os.path.join(ROOT, "TestBooks-clean")
PLAN = os.path.join(ROOT, "tools", "adcuts.jsonl")      # 精炼后的清单（adcheck-refine 产出）
REPORT = os.path.join(ROOT, "tools", "adcut-report.csv")
MIN_CUT = 2.0        # 少于这个秒数不值得动文件
TAG_FRAMES = ("TPE1", "TPE2", "TALB", "TIT2", "TCON", "TRCK", "TPUB", "APIC", "TCOM", "TENC")


def book_rel(row):
    """清单里的 file 是仓库相对路径，转成书库目录内的相对路径（去掉 TestBooks/ 这层）。"""
    rel = row["file"]
    return rel[len("TestBooks/"):] if rel.startswith("TestBooks/") else rel


def load_plan(path=PLAN):
    rows = []
    for line in open(path):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if "cuts" in r and r["cuts"]:
            rows.append(r)
    return rows


def cut_one(src, dst, keeps, tmpdir):
    """逐段无损抽出再 concat；返回是否成功。"""
    pieces = []
    for i, (s, e) in enumerate(keeps):
        p = os.path.join(tmpdir, f"p{i:03d}.mp3")
        cmd = [FF, "-hide_banner", "-loglevel", "error", "-y",
               "-ss", f"{s:.3f}", "-to", f"{e:.3f}", "-i", src,
               "-vn", "-map", "0:a:0", "-c:a", "copy", "-write_xing", "0", p]
        if subprocess.run(cmd, capture_output=True).returncode != 0:
            return False
        pieces.append(p)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if len(pieces) == 1:
        shutil.move(pieces[0], dst)
        return True
    lst = os.path.join(tmpdir, "list.txt")
    with open(lst, "w") as fh:
        for p in pieces:
            fh.write("file '%s'\n" % p.replace("'", "'\\''"))
    out = dst + ".tmp.mp3"
    cmd = [FF, "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
           "-i", lst, "-map", "0:a", "-c", "copy", "-write_xing", "1", out]
    if subprocess.run(cmd, capture_output=True).returncode != 0:
        return False
    shutil.move(out, dst)
    return True


def copy_tags(src, dst):
    """把原文件的 ID3 帧（含内嵌封面）整份搬到新文件。"""
    try:
        from mutagen.id3 import ID3
    except ImportError:
        return "无 mutagen，跳过标签"
    try:
        tags = ID3(src)
    except Exception:
        return "原文件无 ID3"
    try:
        out = ID3()
        for f in TAG_FRAMES:
            for v in tags.getall(f):
                if out.get(f):
                    continue            # 同名帧只留一个，避免 APIC 重复报错
                out.add(v)
        out.save(dst)
        return None
    except Exception as ex:
        return f"标签复制失败：{ex}"


def verify(src_new, row, orig_dur):
    """切完的自检：时长对得上、每段切口都在，缺则报问题。"""
    problems = []
    try:
        x = decode(src_new)
    except Exception as ex:
        return [f"无法解码：{ex}"]
    got = len(x) / SR
    want = sum(e - s for s, e in keep_ranges(orig_dur, row["cuts"]))
    if abs(got - want) > 1.5:
        problems.append(f"时长 {got:.1f}s ≠ 预期 {want:.1f}s")
    if got < 30:
        problems.append("切完只剩不到 30 秒")
    return problems


def apply_one(row, dst_root, tmp_root, dry, report_rows):
    rel = row["file"]
    src = os.path.join(ROOT, rel)
    dst = os.path.join(dst_root, book_rel(row))
    dur = row["dur"]
    keeps = keep_ranges(dur, row["cuts"])
    cut = dur - sum(e - s for s, e in keeps)
    book = rel.split(os.sep)[1]
    report_rows.append([book, os.path.basename(rel), round(dur, 1), round(cut, 1),
                        f"{100*cut/dur:.1f}", len(row["cuts"]),
                        "; ".join(f"{s:.0f}-{e:.0f}" for s, e in row["cuts"]),
                        "是" if row.get("needs_review") else "",
                        " | ".join(row.get("evidence", [])[:3])[:200]])
    if dry or cut < MIN_CUT or not keeps:
        return "skip"
    tmpdir = tempfile.mkdtemp(prefix="adcut-", dir=tmp_root)
    try:
        if not cut_one(src, dst, keeps, tmpdir):
            return "ffmpeg 失败"
        note = copy_tags(src, dst)
        probs = verify(dst, row, dur)
        if probs:
            return "；".join(probs)
        return note or "ok"
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def new_time(t, cuts):
    """原文件时刻 t 在切完的新文件里的位置；落在被切区间内返回 None。"""
    off = 0.0
    for s, e in sorted(cuts):
        if e < t:
            off += e - s
        elif s < t:
            return None
    return t - off


def do_verify(n, dst_root, plan=PLAN):
    """抽查：把干净文件里每个切口前后各几秒转写出来，看有没有误删正文。"""
    import adcheck
    rows = load_plan(plan)[:n]
    adcheck.init_worker()
    for r in rows:
        dst = os.path.join(dst_root, book_rel(r))
        if not os.path.exists(dst):
            continue
        keeps = keep_ranges(r["dur"], r["cuts"])
        print(f"\n### {r['file']}  {r['dur']:.0f}s → {sum(e - s for s, e in keeps):.0f}s")
        for s, e in sorted(r["cuts"]):
            # 新文件里切口前的最后几句（应还是正文）与切口后的头几句（不应再有广告口播）
            for label, at, win in (("切掉前", new_time(s, r["cuts"]), (-12, 2)),
                                   ("接上后", new_time(e + 0.01, r["cuts"]), (-2, 12))):
                if at is None:
                    continue
                a0 = max(0.0, at + win[0])
                segs = adcheck.asr_pcm(dst, adcheck.decode(dst, a0, max(0.0, at + win[1] - a0)))
                print(f"    {label} @{at:.0f}s：" +
                      " / ".join(x["t"] for x in segs[:4])[:120])


def promote(dst_root):
    """用干净文件替换 TestBooks/ 里的原文件（原文件挪到 TestBooks-original/）。"""
    bak = os.path.join(ROOT, "TestBooks-original")
    n = 0
    for rel in [book_rel(r) for r in load_plan(PLAN)]:
        src = os.path.join(SRC_ROOT, rel)
        new = os.path.join(dst_root, rel)
        if not os.path.exists(new):
            continue
        os.makedirs(os.path.dirname(os.path.join(bak, rel)), exist_ok=True)
        if not os.path.exists(os.path.join(bak, rel)):
            shutil.move(src, os.path.join(bak, rel))
        else:
            os.remove(src)
        shutil.copy2(new, src)
        n += 1
    print(f"已替换 {n} 章，原文件在 {bak}")


def main():
    ap = argparse.ArgumentParser(description="按清单无损切除有声书广告")
    ap.add_argument("--plan", default=PLAN,
                    help="切除清单，默认 tools/adcuts.jsonl（精炼结果）；不要用 tools/adcheck.jsonl")
    ap.add_argument("--book")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--apply", action="store_true", help="真正写文件（默认 dry-run）")
    ap.add_argument("--dest", default=DST_ROOT)
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--verify", type=int, nargs="?", const=8, default=None)
    ap.add_argument("--promote", action="store_true")
    args = ap.parse_args()

    if args.promote:
        promote(args.dest)
        return
    if args.verify is not None:
        do_verify(args.verify, args.dest, args.plan)
        return

    rows = load_plan(args.plan)
    print(f"清单：{args.plan}（{len(rows)} 章有切口）", flush=True)
    if args.book:
        rows = [r for r in rows if r["file"].split(os.sep)[1] == args.book]
    tmp_root = tempfile.mkdtemp(prefix="adcut-tmp-", dir=tempfile.gettempdir())
    report = []
    stats = {"ok": 0, "skip": 0, "fail": 0}
    for i, r in enumerate(rows):
        note = apply_one(r, args.dest, tmp_root, not args.apply, report)
        stats["ok" if note == "ok" else ("skip" if note == "skip" else "fail")] += 1
        if note not in ("ok", "skip"):
            print("⚠️", r["file"], note)
        if (i + 1) % 50 == 0:
            print(f"  {i+1}/{len(rows)}", flush=True)
    shutil.rmtree(tmp_root, ignore_errors=True)

    with open(REPORT, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["书名", "章节", "原时长s", "切除s", "占比", "切口数", "切口位置", "需复核", "证据"])
        w.writerows(report)
    tot_cut = sum(x[3] for x in report)
    print(f"{'dry-run（未写文件）' if not args.apply else '已写入 ' + args.dest}："
          f"{len(report)} 章，共切除 {tot_cut/3600:.1f} 小时（成功 {stats['ok']}，跳过 {stats['skip']}，"
          f"失败 {stats['fail']}）")
    print("→ 审核清单", REPORT)


if __name__ == "__main__":
    main()
