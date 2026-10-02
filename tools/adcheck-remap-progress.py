#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""切除广告后重映射 App 收听进度。

切除会让时间轴前移：老进度里的 500 秒在新文件里其实是 545 秒的内容。
本脚本按 tools/adcuts.jsonl 把 progress.json 里每个时间点换算到新时间轴，
并钳进新时长内；落在被切区间里的进度，挪到该区间之后第一秒（不会丢进度）。

用法：
    python3 tools/adcheck-remap-progress.py <progress.json> [--dry]
    # 模拟器：
    python3 tools/adcheck-remap-progress.py \
      "$(xcrun simctl get_app_container booted com.kiwenlau.sonux data)/Library/Application Support/progress.json"
"""

import argparse
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adcheck import ROOT, keep_ranges  # noqa: E402

PLAN = os.path.join(ROOT, "tools", "adcuts.jsonl")


def load_map(plan_path):
    """chapterId（书/文件名）→ (cuts, 新时长)。"""
    out = {}
    for line in open(plan_path):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if "cuts" not in r or not r["cuts"]:
            continue
        rel = r["file"]
        rel = rel[len("TestBooks/"):] if rel.startswith("TestBooks/") else rel
        keeps = keep_ranges(r["dur"], r["cuts"])
        out[rel] = (sorted(r["cuts"]), sum(e - s for s, e in keeps))
    return out


def remap(t, cuts, new_dur):
    """老时间 → 新时间。落在被切区间内则取该区间末尾（新轴上的位置）。"""
    off = 0.0
    for s, e in cuts:
        if e <= t:
            off += e - s
        elif s < t:                      # 正落在被切掉的片段里
            return min(max(e - off - 0.5, 0.0), max(new_dur - 1.0, 0.0))
        else:
            break
    return min(max(t - off, 0.0), max(new_dur - 1.0, 0.0))


def main():
    ap = argparse.ArgumentParser(description="重映射收听进度到新时间轴")
    ap.add_argument("progress")
    ap.add_argument("--plan", default=PLAN)
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    m = load_map(args.plan)
    d = json.load(open(args.progress))
    changed = 0
    for sect in ("books", "chapters"):
        for key, pos in sorted(d.get(sect, {}).items()):
            cid, t = pos.get("chapterId"), pos.get("time", 0.0)
            if cid not in m:
                continue
            cuts, new_dur = m[cid]
            nt = round(remap(t, cuts, new_dur), 2)
            if abs(nt - t) > 0.5:
                print(f"  {sect} {key}: {t:.0f}s → {nt:.0f}s（新时长 {new_dur:.0f}s）")
                pos["time"] = nt
                changed += 1
    print(f"共调整 {changed} 条进度")
    if args.dry or not changed:
        return
    shutil.copy2(args.progress, args.progress + ".before-remap")
    with open(args.progress, "w") as fh:
        json.dump(d, fh, ensure_ascii=False, sort_keys=True)
    print("→ 已写回", args.progress, "（原件备份为 .before-remap）")


if __name__ == "__main__":
    main()
