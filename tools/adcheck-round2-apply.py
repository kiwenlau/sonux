#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二遍去广告的落地编排：切 → 验收 → promote → 收听进度换算 → 同步 → 重转写字幕。

为什么要单独一个编排：整轮要跑几十分钟到几小时，断掉必须能从断点续上；更要紧的是
promote 之前必须先过验收——这一遍是语言模型判的广告，切坏了就是丢正文，不可逆。

阶段与状态都记在 .tmp-adcheck/round2-state.json 里，重跑只补没做完的书。

promote 闸门（不满足就只切不推，原因写进状态文件）：
- 验收出现「出错」或「跳过」（没切出干净文件）→ 不 promote；
- 「可疑」且原因不是 H1 气口（也就是 H0 时长/无损不达标）→ 不 promote；
  H1 单独放行：第二遍要切的常是纯音乐底（区间内无人说话），音乐里根本没有停顿可落，
  第一遍那 4 处「可疑」核实下来全是这种，卡在这里就永远切不完；
- 通过刀数为 0 → 不 promote（这本书没有可落地价值）；
- 切除比例超过 --max-pct（默认 15%）→ 不 promote，留给人确认。

用法：
    python3 tools/adcheck-round2-apply.py                      # 所有还没落地的书
    python3 tools/adcheck-round2-apply.py --book 与鬼为邻      # 只处理指定书（可重复）
    python3 tools/adcheck-round2-apply.py --phase audit        # 只重跑某一段
    python3 tools/adcheck-round2-apply.py --status             # 只看状态表
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adcheck import ROOT  # noqa: E402

PLAN = os.path.join(ROOT, "tools", "adcuts-llm.jsonl")
DEST = "TestBooks-clean2"
STATE = os.path.join(ROOT, ".tmp-adcheck", "round2-state.json")
BUCKET = os.path.join(ROOT, ".tmp-adcheck", "round2")
BUNDLE = "com.kiwenlau.sonux"
PHASES = ("cut", "audit", "promote", "remap", "sync", "asr")
# 昨晚已经落地过的两本书：状态里直接标成已完成，别重复切、更别重复换算进度
SEEDED = ("民主的细节", "大败局")


def log(msg):
    print(f"[{time.strftime('%F %T')}] {msg}", flush=True)


def load_state():
    try:
        st = json.load(open(STATE, encoding="utf-8"))
    except Exception:
        st = {}
    for b in SEEDED:
        st.setdefault(b, {})
        st[b].update({"cut": st[b].get("cut") or {"chapters": 0, "note": "上一轮已落地"},
                      "audit": st[b].get("audit") or {"通过": 0, "可疑": 0, "出错": 0, "跳过": 0},
                      "promoted": True, "promote_note": "上一轮已落地"})
    return st


def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + f".{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(st, fh, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(tmp, STATE)


def plan_books():
    """清单里有切口的书 → {书名: [章数, 刀数, 秒数]}。"""
    out = {}
    for line in open(PLAN, encoding="utf-8"):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if not r.get("cuts"):
            continue
        b = r["file"].split("/")[1]
        p = out.setdefault(b, [0, 0, 0.0])
        p[0] += 1
        p[1] += len(r["cuts"])
        p[2] += r["cut_sec"]
    return out


def run(cmd, tail=0):
    """跑子进程，回 (返回码, 输出)。"""
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    txt = (p.stdout or "") + (p.stderr or "")
    if tail:
        for l in [x for x in txt.splitlines() if x.strip()][-tail:]:
            log("    " + l[:150])
    return p.returncode, txt


# ---------------------------------------------------------------- 各阶段
def do_cut(book, s):
    rep = os.path.join(BUCKET, f"cut-{book}.csv")
    os.makedirs(BUCKET, exist_ok=True)
    _, txt = run([sys.executable, "tools/adcut-apply.py", "--plan", PLAN, "--book", book,
                  "--dest", DEST, "--report", rep, "--apply"])
    m = re.search(r"：(\d+) 章，共切除 ([\d.]+) 小时（成功 (\d+)，跳过 (\d+)，失败 (\d+)）", txt)
    got = {"章数": int(m.group(1)), "小时": float(m.group(2)), "成功": int(m.group(3)),
           "跳过": int(m.group(4)), "失败": int(m.group(5))} if m else {"原文": txt[-200:]}
    s["cut"] = got
    if not m or got.get("失败"):
        s["cut_fail"] = f"切除有失败：{got}"
    return got


def do_audit(book, s, args):
    out = os.path.join(BUCKET, f"audit-{book}.csv")
    _, txt = run([sys.executable, "tools/adcheck-audit.py", "--plan", PLAN, "--clean", DEST,
                   "--out", out, "--book", book, "--jobs", str(args.jobs)])
    if not os.path.exists(out):
        s["audit_fail"] = f"验收没出报告：{txt[-160:]}"
        return {}
    rows = [r for r in csv.DictReader(open(out, encoding="utf-8")) if r.get("cut")]
    c = {"通过": 0, "可疑": 0, "出错": 0, "跳过": 0}
    hard = []
    for r in rows:
        v = r["verdict"]
        c[v] = c.get(v, 0) + 1
        why = r.get("why") or ""
        # H1 气口不合格可以放行（音乐段本来没有停顿）；其余「可疑」都是硬问题
        if v == "可疑" and "H1" not in why:
            hard.append(f"{os.path.basename(r['file'])[:22]} {r['cut']} {why or r.get('hard', '')[:60]}")
        if v == "出错":
            hard.append(f"{os.path.basename(r['file'])[:22]} 出错 {why[:60]}")
    c["硬性不合格"] = len(hard)
    s["audit"] = c
    s["audit_hard"] = hard[:6]
    return c


def do_repair(book, s):
    """验收判定「切到正文」的刀，直接从清单里摘掉再重切。

    不为了一本书的坏刀把整轮卡住：这些刀本来就是模型误判（多为 whisper 把十几秒正文
    塌成一行，模型以为那行是台呼），摘掉后剩下的刀照样能落地。
    """
    out = os.path.join(BUCKET, f"audit-{book}.csv")
    if not os.path.exists(out):
        return 0
    bad = {(r["file"], r["cut"]) for r in csv.DictReader(open(out, encoding="utf-8"))
           if r.get("cut") and r["verdict"] == "可疑" and "H1" not in (r.get("why") or "")}
    if not bad:
        return 0
    rows, n = [], 0
    for line in open(PLAN, encoding="utf-8"):
        r = json.loads(line)
        for key in list(bad):
            if key[0] == r["file"]:
                a, b = [float(x) for x in key[1].split("-")]
                keep = [c for c in r.get("cuts") or [] if abs(c[0] - a) > 0.6 or abs(c[1] - b) > 0.6]
                n += len(r.get("cuts") or []) - len(keep)
                r["cuts"] = keep
                sec = round(sum(c[1] - c[0] for c in keep), 1)
                r["cut_sec"], r["cut_pct"] = sec, round(100 * sec / max(1.0, r.get("dur") or 1), 2)
        rows.append(r)
    tmp = PLAN + f".{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, PLAN)
    s["repairs"] = s.get("repairs", 0) + n
    s.pop("cut", None)
    s.pop("audit", None)
    return n


def gate(book, st, max_pct):
    """这本书能不能 promote。st 传的是「该书那一格」，不是整份状态。"""
    a = st.get("audit") or {}
    if st.get("cut_fail") or st.get("audit_fail"):
        return False, (st.get("cut_fail") or st.get("audit_fail"))
    if not a:
        return False, "没跑验收"
    if a.get("出错") or a.get("跳过"):
        return False, f"验收有出错/跳过：{a}"
    if a.get("硬性不合格"):
        return False, f"有 {a['硬性不合格']} 处硬问题：{(st.get('audit_hard') or [''])[0]}"
    if not a.get("通过"):
        return False, f"没有一刀通过验收：{a}"
    return True, ""


def cut_pct(book):
    """这本书本轮切除比例（相对当前 TestBooks 文件），用来拦「切太多」。"""
    tot = cut = 0.0
    for line in open(PLAN, encoding="utf-8"):
        r = json.loads(line)
        if r["file"].split("/")[1] != book or not r.get("cuts"):
            continue
        tot += r.get("dur") or 0
        cut += r.get("cut_sec") or 0
    return 100 * cut / max(1.0, tot)


def do_promote(book, s):
    rc, txt = run([sys.executable, "tools/adcut-apply.py", "--plan", PLAN, "--book", book,
                   "--dest", DEST, "--promote"], tail=1)
    if rc != 0:
        s["promote_fail"] = txt[-160:]
        return False
    s["promoted"] = True
    s["promoted_at"] = time.strftime("%F %T")
    s["needs_remap"] = True       # 换算只能做一次，重复做会把进度往前挪两遍
    return True


def sim_progress():
    """模拟器里 App 的进度文件路径（跑真机时改 devicectl 那套）。"""
    p = subprocess.run(["xcrun", "simctl", "get_app_container", "booted", BUNDLE, "data"],
                       cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        return None
    # 注意是「Application Support」一个目录名（中间空格），拆成两级路径会找不到
    return os.path.join(p.stdout.strip(), "Library", "Application Support", "progress.json")


def do_remap(books, st):
    prog = sim_progress()
    if not prog or not os.path.exists(prog):
        log("  找不到模拟器进度文件，跳过换算（之后要手动跑 adcheck-remap-progress.py）")
        st["_remap"] = "跳过：没有进度文件"
        return
    cmd = [sys.executable, "tools/adcheck-remap-progress.py", prog, "--plan", PLAN]
    for b in books:
        cmd += ["--book", b]
    rc, txt = run(cmd, tail=1)
    st["_remap"] = [l for l in txt.splitlines() if l.strip()][-1] if rc == 0 else txt[-160:]


def do_sync():
    return run(["./sync-library.sh", "--yes"], tail=2)


def do_asr():
    """拉起字幕流水线：音频被换过，这些章的转写与校对 sig 全作废，得重跑。"""
    if subprocess.run(["pgrep", "-f", "subtitle-watchdog.sh"], capture_output=True).returncode == 0:
        log("  字幕流水线已经在跑，不重复拉起")
        return
    logf = open(os.path.join(ROOT, ".tmp-adcheck", "subtitle-watchdog.log"), "a")
    subprocess.Popen(["./tools/subtitle-watchdog.sh"], cwd=ROOT, stdout=logf, stderr=logf,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    log("  已拉起 tools/subtitle-watchdog.sh（重转写 + 重校对 + 打包 + 同步字幕）")


# ---------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser(description="第二遍去广告落地：切→验收→promote→换算进度→同步")
    ap.add_argument("--book", action="append", help="只处理这些书（可重复）；不给就是清单里所有还没落地的")
    ap.add_argument("--phase", choices=PHASES, help="只跑这一段（默认全流程）")
    ap.add_argument("--status", action="store_true", help="只打印状态表")
    ap.add_argument("--max-pct", type=float, default=15.0, help="单本书切除比例上限，超了不 promote")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=3, help="切→验→修的轮数（最后一轮还有硬问题就不推）")
    args = ap.parse_args()

    os.makedirs(BUCKET, exist_ok=True)
    st = load_state()
    books = plan_books()
    todo = args.book or [b for b in sorted(books) if not st.get(b, {}).get("promoted")]
    if args.status:
        print(f"{'书':28s}{'章':>5}{'刀':>6}{'分':>7}  切  验收  已推")
        for b in sorted(books):
            s = st.get(b) or {}
            a = s.get("audit") or {}
            print(f"{b[:26]:28s}{books[b][0]:>5}{books[b][1]:>6}{books[b][2]/60:>7.1f}"
                  f"  {'✓' if s.get('cut') else '·'}  "
                  f"{('通' + str(a.get('通过', 0)) + '/疑' + str(a.get('可疑', 0))) if a else '·'}"
                  f"  {'✓' if s.get('promoted') else '·'}")
        return
    log(f"待处理 {len(todo)} 本（清单共 {len(books)} 本）；阶段 {args.phase or '全流程'}")

    passed = []
    for b in todo:
        s = st.setdefault(b, {})
        for attempt in range(args.rounds):
            if args.phase in (None, "cut") and not s.get("cut"):
                got = do_cut(b, s)
                save_state(st)
                log(f"✂️ {b}：切 {got}")
            if args.phase in (None, "audit") and not s.get("audit"):
                c = do_audit(b, s, args)
                save_state(st)
                log(f"🔎 {b}：验收 {c}")
            hard = (s.get("audit") or {}).get("硬性不合格") or 0
            if args.phase not in (None, "audit") or not hard or attempt == args.rounds - 1:
                break
            n = do_repair(b, s)
            if not n:
                break
            save_state(st)
            log(f"🔧 {b}：验收判 {n} 刀切到正文，已从清单摘掉，重切重验")
        if args.phase in (None, "promote"):
            if s.get("promoted"):
                passed.append(b)
                continue
            ok, why = gate(b, s, args.max_pct)
            if ok and cut_pct(b) > args.max_pct:
                ok, why = False, f"切除比例 {cut_pct(b):.1f}% 超上限 {args.max_pct}%"
            if not ok:
                s["blocked"] = why
                log(f"⛔ {b}：不 promote——{why}")
            elif s.get("promoted"):
                pass
            else:
                if do_promote(b, s):
                    log(f"📦 {b}：已 promote 进 TestBooks")
            save_state(st)
            if s.get("promoted"):
                passed.append(b)

    # 换算/同步/重转写都按「状态文件里待办的书」来，崩在中间重跑也不会漏或重复
    pending_remap = [b for b, v in st.items()
                     if isinstance(v, dict) and v.get("needs_remap")]
    if args.phase in (None, "remap") and pending_remap:
        do_remap(pending_remap, st)
        for b in pending_remap:
            st[b]["remapped_at"] = time.strftime("%F %T")
            st[b].pop("needs_remap", None)
        save_state(st)
        log(f"⏱ 进度换算（{len(pending_remap)} 本）：{st.get('_remap')}")
    if args.phase in (None, "sync"):
        do_sync()
        log("📚 音频已镜像到模拟器")
    if args.phase in (None, "asr"):
        do_asr()

    blocked = {b: v.get("blocked") for b, v in st.items()
               if not b.startswith("_") and isinstance(v, dict) and v.get("blocked")}
    log(f"完成：本轮 promote {len(passed)} 本；被闸门拦下 {len(blocked)} 本")
    for b, w in blocked.items():
        log(f"   ⛔ {b}：{w}")


if __name__ == "__main__":
    main()
