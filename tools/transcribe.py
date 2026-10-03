#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把整章音频转成带时间轴的字幕（播放页章节名下方那句同步文案的数据源）。

与 adcheck.py 的区别：adcheck 只转片头/片尾/声纹离群区（找广告够用），
这里要整篇转写并切成适合当字幕显示的短句，产出给 App 读的字幕包。

三段式，全程幂等，断电重跑即从断点继续：
1. 逐章转写 → tools/transcripts-parts/<书>/<章>.json（{sig,dur,lines:[[起,止,文]]}）
   sig 是音频字节数：文件被切除广告后 sig 变了，该章会自动重转，字幕时间轴不会错位。
2. 按书打包 → transcripts/<书>.json（{"v":1,"chapters":{"章文件名":[[起,止,文]]}}）
   App 用 Documents/transcripts/<书目录名>.json 按 chapter 文件名取字幕。
3. 同步：./sync-transcripts.sh（模拟器 rsync，真机 devicectl）

用法：
    python3 tools/transcribe.py --book 曾国藩的正面与侧面 --pack   # 单本（先出正在听的）
    python3 tools/transcribe.py --all --jobs 6                     # 全库，最近听过的排前面
    python3 tools/transcribe.py --pack-only                        # 只重新打包
    python3 tools/transcribe.py --status                           # 进度与耗时估算

耗时：whisper-small CPU int8 单进程约 10x 实时，6 进程聚合约 40x；
全库 368 小时音频一轮 8~10 小时。
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

# 限制 BLAS/Accelerate 线程：否则每个子进程的 FFT 会吃满全部核，把 whisper 挤垮
for _v in ("OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "2")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "TestBooks")
PARTS = os.path.join(ROOT, "tools", "transcripts-parts")
OUT_DIR = os.path.join(ROOT, "transcripts")
MODEL_DIR = os.environ.get("SONUX_WHISPER_MODEL",
                           os.path.join(ROOT, "tools", "models", "whisper-small"))
AUDIO_EXTS = (".mp3", ".m4a", ".m4b", ".aac", ".wav", ".wave")
SR = 16000

# 字幕成句：一句最多这么多字/这么久，句间空隙小于 max_gap 就并成一句
MAX_CHARS = 20
MAX_SPAN = 7.0
MAX_GAP = 0.7
# 打包时单行字幕的字数上限：播放页只留两行，一行约 20 字，再长就拆句
SPLIT_MAX = 34

# 转写提示：whisper 会跟着 prompt 的字形走，不给提示时繁简混杂（源书是港台配音）
INITIAL_PROMPT = "以下是简体中文有声书朗读，请用简体中文书写，只使用简体中文汉字。"

_MODEL = None


def ffmpeg_path():
    p = os.popen("command -v ffmpeg 2>/dev/null").read().strip()
    if p:
        return p
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


FF = ffmpeg_path()


# ---------------------------------------------------------------- 章节枚举


def lsc(name):
    """localizedStandardCompare 的近似：数字按数值比，'02' 排在 '10' 前。"""
    parts = re.split(r"(\d+)", unicodedata.normalize("NFKC", name).casefold())
    return [int(p) if p.isdigit() else p for p in parts]


def chapters(root=LIB):
    """列出全部章：返回 (绝对路径, 书目录名, 章文件名)。"""
    out = []
    for b in sorted(os.listdir(root), key=lsc):
        d = os.path.join(root, b)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d), key=lsc):
            if not name.lower().endswith(AUDIO_EXTS) or name.startswith("."):
                continue
            out.append((os.path.join(d, name), b, name))
    # 顶层散落音频：一本书一个文件，书名用文件名
    for name in sorted(os.listdir(root), key=lsc):
        p = os.path.join(root, name)
        if os.path.isfile(p) and name.lower().endswith(AUDIO_EXTS) and not name.startswith("."):
            out.append((p, os.path.splitext(name)[0], name))
    return out


def recent_books():
    """从 App 进度文件里读书名，按最后播放时间从新到旧排（先在听的先出字幕）。

    进度文件优先取模拟器沙盒（最新），退化到仓库里的真机备份副本。
    """
    paths = []
    sim = subprocess.run(["xcrun", "simctl", "get_app_container", "booted",
                          "com.kiwenlau.sonux", "data"],
                         capture_output=True, text=True).stdout.strip()
    if sim:
        paths.append(os.path.join(sim, "Library", "Application Support", "progress.json"))
    paths.append(os.path.join(ROOT, ".tmp-adcheck", "iphone-backup", "progress.json"))
    stamp = {}
    for p in paths:
        try:
            data = json.load(open(p))
        except Exception:
            continue
        for book_id, t in (data.get("lastPlayed") or {}).items():
            name = book_id.split(":", 1)[-1].split("/", 1)[0]
            if t > stamp.get(name, 0):
                stamp[name] = t
    return [b for b, _ in sorted(stamp.items(), key=lambda kv: -kv[1])]


# ---------------------------------------------------------------- 成句


def has_text(t):
    """只剩标点/空白的转写结果不算一句（whisper 会在静音处吐「。」）。"""
    return bool(re.search(r"[\w\u4e00-\u9fff]", t))


def clean(t):
    t = t.strip().strip("「」『』“”\"'")
    return t.rstrip("。，、；：…,.!?;:").strip()


# 繁→简映射表（tools/t2s.json，由 tools/t2s-table.swift 从系统 ICU 数据导出）。
# 源书多是港台配音，whisper 吐出来的字繁简混杂，同一章上下句都能差一套字形；
# parts 里存转写原文，到打包才统一，改字形策略不用重跑 ASR。
T2S = {}
_t2s_path = os.path.join(ROOT, "tools", "t2s.json")
if os.path.exists(_t2s_path):
    with open(_t2s_path) as fh:
        T2S = str.maketrans(json.load(fh))


def normalize(text):
    """繁体转简体，并把中文句里的半角标点换成全角（whisper 习惯打 ASCII 逗号）。"""
    text = text.translate(T2S)
    if not re.search(r"[\u4e00-\u9fff]", text):
        return text
    for half, full in ((",", "，"), (";", "；"), (":", "："), ("?", "？"), ("!", "！")):
        text = re.sub(r"([\u4e00-\u9fff])" + re.escape(half), r"\1" + full, text)
    # 句号只在「汉字 + . + 句尾或汉字」时换，避开 No.1 / 3.5 这类写法
    text = re.sub(r"([\u4e00-\u9fff])\.(?=[\u4e00-\u9fff]|$)", r"\1。", text)
    return text


def split_line(start, end, text, max_chars=SPLIT_MAX):
    """过长的转写句拆成几句，时间按字数比例分。

    whisper 一口气能给到 100 字，而播放页字幕只留两行；不拆就会被裁掉后半句，
    而且一句挂太久也不跟得上朗读节奏。
    """
    if len(text) <= max_chars:
        return [[start, end, text]]
    parts = [p for p in re.split(r"(?<=[，。；：！？、])", text) if p]
    chunks, cur = [], ""
    for p in parts:
        if cur and len(cur) + len(p) > max_chars:
            chunks.append(cur)
            cur = p
        else:
            cur += p
    if cur:
        chunks.append(cur)
    # 整句没标点可拆：按长度硬切，否则还是会超出两行
    if len(chunks) == 1:
        chunks = [text[i:i + max_chars] for i in range(0, len(text), max_chars)]
    total = sum(len(c) for c in chunks) or 1
    lines, t = [], start
    for i, c in enumerate(chunks):
        stop = end if i == len(chunks) - 1 else t + (end - start) * len(c) / total
        lines.append([round(t, 1), round(stop, 1), c])
        t = stop
    return lines


def group(segs, max_chars=MAX_CHARS, max_span=MAX_SPAN, max_gap=MAX_GAP):
    """把 whisper 的碎片短句并成字幕行：句首句尾时间取实际语音的起止。

    连续重复的同一句是 whisper 在长静音/音乐上的自循环幻觉，只留第一次。
    """
    lines = []                       # [[起, 止, 文]]
    cur = None                       # 正在拼的一句：(起, 文, 止)
    for s in segs:
        start, end, text = float(s["b"]), float(s["e"]), clean(s["t"])
        if not text or not has_text(text) or start >= end:
            continue
        if cur is None:
            if lines and text == lines[-1][2]:      # 刚收尾又重复同一句
                continue
            cur = (start, text, end)
            continue
        p_start, p_text, p_end = cur
        if text == p_text:                          # 同一句在静音里循环
            cur = (p_start, p_text, end)
            continue
        # 拉丁词与中文之间补一个空格（「设备iOS」读起来粘连）
        sep = " " if (re.search(r"[A-Za-z0-9]$", p_text) or re.match(r"[A-Za-z0-9]", text)) else ""
        joins = (start - p_end <= max_gap
                 and len(p_text) + len(text) <= max_chars
                 and end - p_start <= max_span)
        if joins:
            cur = (p_start, p_text + sep + text, end)
            continue
        lines.append([round(p_start, 1), round(p_end, 1), p_text])
        cur = (start, text, end)
    if cur is not None:
        lines.append([round(cur[0], 1), round(cur[2], 1), cur[1]])
    return lines


# ---------------------------------------------------------------- 转写


def init_worker():
    global _MODEL
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    from faster_whisper import WhisperModel
    _MODEL = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8",
                          cpu_threads=int(os.environ.get("TS_THREADS", "2")))


def part_path(book, name):
    return os.path.join(PARTS, book, name + ".json")


def part_valid(path, size):
    try:
        row = json.load(open(path))
    except Exception:
        return False
    return row.get("sig") == size and isinstance(row.get("lines"), list)


def transcribe(path):
    """整章转写：mp3 → 16k 单声道 wav → whisper（临时文件名带 pid，并行不互踩）。"""
    wav = os.path.join(tempfile.gettempdir(), f"transcribe-{os.getpid()}.wav")
    subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-y", "-i", path,
                    "-vn", "-ac", "1", "-ar", str(SR), wav], capture_output=True, check=True)
    dur = os.path.getsize(wav) / 2.0 / SR
    try:
        result = _MODEL.transcribe(wav, language="zh", beam_size=1, vad_filter=False,
                                   condition_on_previous_text=False,
                                   initial_prompt=INITIAL_PROMPT)
        segs = [{"b": s.start, "e": s.end, "t": s.text.strip()} for s in result[0]]
    finally:
        if os.path.exists(wav):
            os.remove(wav)
    return dur, segs


def job(item):
    path, book, name = item
    rel = os.path.relpath(path, ROOT)
    size = os.path.getsize(path)
    p = part_path(book, name)
    if part_valid(p, size):
        return dict(file=rel, skipped=True)
    t0 = time.time()
    try:
        dur, segs = transcribe(path)
    except Exception as ex:                # 单章失败不拖垮整轮
        return dict(file=rel, error=str(ex)[:200])
    lines = group(segs)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + f".{os.getpid()}.tmp"
    with open(tmp, "w") as fh:
        json.dump({"sig": size, "dur": round(dur, 1),
                   "nchar": sum(len(l[2]) for l in lines), "lines": lines},
                  fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, p)
    return dict(file=rel, dur=dur, n=len(lines), nchar=sum(len(l[2]) for l in lines),
                sec=round(time.time() - t0, 1))


# ---------------------------------------------------------------- 打包


def pack(books=None):
    """把逐章 parts 按书合成 App 读的 transcripts/<书>.json。

    逐章 parts 是并发写的（每章一个文件不会互相踩），打包只在主进程做，
    所以整本文件可以安全重写。缺章的字幕就是没有，App 端不显示字幕行。
    """
    os.makedirs(OUT_DIR, exist_ok=True)
    if not os.path.isdir(PARTS):
        print("还没有逐章结果，先跑转写")
        return
    done = []
    for book in sorted(os.listdir(PARTS), key=lsc):
        if books and book not in books:
            continue
        d = os.path.join(PARTS, book)
        if not os.path.isdir(d):
            continue
        chapters_map = {}
        for f in sorted(os.listdir(d), key=lsc):
            if not f.endswith(".json"):
                continue
            try:
                row = json.load(open(os.path.join(d, f)))
            except Exception:
                continue
            if isinstance(row.get("lines"), list):
                packed = []
                for l in row["lines"]:
                    if len(l) == 3 and l[2]:
                        packed += split_line(l[0], l[1], normalize(l[2]))
                chapters_map[f[:-len(".json")]] = packed
        if not chapters_map:
            continue
        out = os.path.join(OUT_DIR, book + ".json")
        payload = {"v": 1, "chapters": chapters_map}
        tmp = out + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, out)
        done.append((book, len(chapters_map), os.path.getsize(out)))
    for book, n, size in done:
        print(f"  {book[:28]:30s} {n:4d} 章  {size/1024:7.0f} KB")
    print(f"→ {OUT_DIR}（{len(done)} 本）")


# ---------------------------------------------------------------- 状态


def status(root=LIB):
    all_ch = chapters(root)
    have = sum(1 for p, b, n in all_ch if part_valid(part_path(b, n), os.path.getsize(p)))
    print(f"已转写 {have}/{len(all_ch)} 章（{100*have/max(len(all_ch),1):.0f}%）")
    nchar = 0
    for dirpath, _, files in os.walk(PARTS):
        for f in files:
            if f.endswith(".json"):
                try:
                    nchar += json.load(open(os.path.join(dirpath, f))).get("nchar", 0)
                except Exception:
                    continue
    print(f"字幕文本累计 {nchar/1e4:.0f} 万字")
    if os.path.isdir(OUT_DIR):
        outs = [f for f in os.listdir(OUT_DIR) if f.endswith(".json")]
        mb = sum(os.path.getsize(os.path.join(OUT_DIR, f)) for f in outs) / 1e6
        print(f"字幕包 {len(outs)} 本 / {mb:.1f} MB → {OUT_DIR}")
    else:
        print("还没有字幕包（先 --pack）")


# ---------------------------------------------------------------- 主流程


def main():
    ap = argparse.ArgumentParser(description="整章音频 → 带时间轴字幕")
    ap.add_argument("--root", default=LIB)
    ap.add_argument("--book", action="append", help="书名（可重复）")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--fresh", action="store_true", help="已转写的章也重跑")
    ap.add_argument("--pack-only", action="store_true")
    ap.add_argument("--pack", action="store_true", help="转写结束后打包")
    ap.add_argument("--pack-every", type=int, default=60, help="每 N 章打包一次，让字幕逐本可用")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args()

    if args.status:
        status(args.root)
        return
    if args.pack_only:
        pack(args.book)
        return

    if args.files:
        items = []
        for f in args.files:
            p = f if os.path.isabs(f) else os.path.join(ROOT, f)
            items.append((p, os.path.basename(os.path.dirname(p)), os.path.basename(p)))
    else:
        items = chapters(args.root)
        if args.book:
            wanted = set(args.book)
            items = [it for it in items if it[1] in wanted]
        elif not args.all:
            ap.error("需要 --all / --book 书名 / --files 文件列表 / --status 之一")

    if not args.fresh:
        items = [it for it in items if not part_valid(part_path(it[1], it[2]),
                                                      os.path.getsize(it[0]))]
    # 最近听过的书先做：用户最先在自己正在听的书上看到字幕
    books = sorted({it[1] for it in items}, key=lsc)
    if args.book:
        rank = {b: 0 for b in args.book}          # 指定了书名就只按章号排
    else:
        recent = recent_books()
        rank = {b: i for i, b in enumerate(recent)}
        for i, b in enumerate(books):
            rank.setdefault(b, len(recent) + i)
    items.sort(key=lambda it: (rank.get(it[1], len(rank)), lsc(it[2])))
    if args.limit:
        items = items[:args.limit]
    if not items:
        print("全部章都已有字幕结果，直接打包")
        pack(args.book)
        return

    print(f"本轮 {len(items)} 章，并行 {args.jobs}，模型 {os.path.basename(MODEL_DIR)}", flush=True)
    import multiprocessing as mp
    pool = mp.Pool(args.jobs, initializer=init_worker)
    t0 = time.time()
    n = done = 0
    errs = []
    for r in pool.imap_unordered(job, items, chunksize=1):
        n += 1
        if r.get("error"):
            errs.append(r)
        elif not r.get("skipped"):
            done += 1
            el = time.time() - t0
            eta = el / done * (len(items) - n)
            print(f"  {n}/{len(items)} {r['file'][-46:]:48s} {r['n']:3d} 句 "
                  f"{r['sec']:5.0f}s 已用 {el/60:.0f} 分 预计还剩 {eta/60:.0f} 分", flush=True)
        if args.pack_every and n % args.pack_every == 0:
            pack(args.book)
    pool.close()
    pool.join()
    if args.pack or args.all or args.book:
        pack(args.book)
    print(f"完成 {done} 章，用时 {(time.time()-t0)/60:.1f} 分，失败 {len(errs)}")
    for r in errs[:5]:
        print("  失败：", r["file"], r["error"])
    if errs:
        sys.exit(1)


if __name__ == "__main__":
    main()
