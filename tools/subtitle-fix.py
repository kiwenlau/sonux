#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用本地大模型修字幕里的同音别字：ASR 只管时间轴，文字交给语言模型。

为什么要这一步：whisper 与中文专用 Paraformer 我都试过，两路在同一类地方一起栽——
文言引文、人名、生僻词（「曾国荃」一个写成「曾国权」一个写成「曾国醛」，「佾生」
一个写成「一声」一个写成「一声」）。原因是 ASR 只有声学、没有语言知识，而这类错误
的特征正是「读音对、字形错」，恰好是语言模型擅长修的。

三道闸，防止语言模型把「纠错」变成「改写」：
1. 只许改字：改后必须与原行等长（±2 字），逐字拼音（忽略声调）相似度 ≥0.85；
2. 不许增删：提示词里明确只改别字与标点，不重写句子、不补内容；
3. 拿不准就不改：模型只输出它确实改动的行号，其余保持 ASR 原文。

用法：
    python3 tools/subtitle-fix.py --book 曾国藩的正面与侧面        # 修一本
    python3 tools/subtitle-fix.py --all                          # 全库（跳过已修的章）
    python3 tools/subtitle-fix.py --files TestBooks/书/01.mp3 --dry-run   # 只看提示词
产物：tools/transcripts-fix/<书>/<章>.json；transcribe.py 打包时优先取这份，
缺的章退回 ASR 版。所以纠错可以一本一本地推进，没修到的书照样有字幕可看。
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import transcribe as T  # noqa: E402  复用章节枚举、成句、路径与打包约定

ROOT = T.ROOT
FIX_DIR = os.path.join(ROOT, "tools", "transcripts-fix")
MODEL_DIR = os.environ.get(
    "SONUX_FIX_MODEL", os.path.join(ROOT, "tools", "models", "Qwen2.5-14B-Instruct-4bit"))
FIX_TAG = f"fix:{os.path.basename(MODEL_DIR)}"
MIN_PINYIN_SIM = 0.85      # 整行拼音相似度低于此就认定模型改的不是同一个读音，驳回
MIN_PAIR_SIM = 0.6         # 单个替换词的拼音相似度下限（整行比例会放过「声→岁」这种）
LEN_SLACK = 2              # 允许字数增减（补漏字/删赘字），再多就视为改写

SYSTEM = (
    "你在校对中文有声书的自动转写字幕。字幕来自语音识别，声学上没错，"
    "但常有同音字、近音字用错，尤其是文言引文、人名、地名、官职名和生僻词。"
    "你的任务是按上下文把这些别字改回来。")

RULES = (
    "规则：\n"
    "1. 只改词，不改句：不许重写、不许润色、不许增删信息，句子的说法必须保持原样。\n"
    "2. 只能改成与原字同音或近音的字（声调可以不同）。做不到就不提这一行。\n"
    "3. 宁缺毋滥：没把握就留着不改；一行最多提两处替换；不要为了句子通顺而改。\n"
    "4. 只输出你确实要改的行，每行一个 JSON 对象："
    '{"i":行号,"w":[["原词","新词"],…]}。' 
    "「原词」必须该行里一字不差出现过的写法，程序会直接拿它去替换。\n"
    "5. 不要输出整行文本，不要输出解释，不要输出代码块标记。没要改的行就不输出。")


def fix_path(book, name):
    return os.path.join(FIX_DIR, book, name + ".json")


def fix_done(path, size):
    try:
        row = json.load(open(path))
    except Exception:
        return False
    return row.get("sig") == size and row.get("asr") == FIX_TAG


def asr_lines(book, name, size):
    """取该章的 ASR 字幕行（必须是当前 ASR 后端产出的，且音频未变）。"""
    p = T.part_path(book, name)
    try:
        row = json.load(open(p))
    except Exception:
        return None
    if row.get("sig") != size or row.get("asr") != T.asr_tag():
        return None
    return row.get("lines")


def build_prompt(book, author, chapter, window, editable_from):
    """一段上下文的提示词：window 是 (行号, 文本) 列表，行号 >= editable_from 的才允许改。

    给人看也给模型看的行号从 1 开始（模型默认按自然数列号回话，用 0 基会整列错位一行，
    实测就是把上一行的改后文本当成下一行的新内容），内部仍用 0 基下标。
    """
    head = f"书名《{book}》" + (f"，作者{author}" if author else "") + f"，本章《{chapter}》。\n"
    body = "\n".join(f"{i + 1}\t{t}" for i, t in window)
    return (head + RULES + f"\n\n以下是连续的字幕行（行号\\t内容），行号 {editable_from + 1} 及之后"
            f"的是待校对行，前面的只作上下文：\n{body}\n")


def pinyin_seq(text):
    """拼音拼成一串再比。按音节列表比太粗：「俯念/抚院」只有一半音节相同会被误杀，
    「一声/一岁」则因为共享「yi」而被放过。"""
    from pypinyin import lazy_pinyin, Style
    return "".join(lazy_pinyin(text, style=Style.NORMAL, errors="default"))


def sim(a, b):
    return difflib.SequenceMatcher(None, pinyin_seq(a), pinyin_seq(b)).ratio()


def acceptable(orig, new):
    """闸门：长度不许大变 + 读音序列必须高度一致。"""
    if not new or new == orig:
        return False, "无改动"
    if abs(len(new) - len(orig)) > LEN_SLACK:
        return False, f"长度 {len(orig)}→{len(new)}"
    ratio = sim(orig, new)
    if ratio < MIN_PINYIN_SIM:
        return False, f"拼音相似度 {ratio:.2f}"
    return True, f"拼音相似度 {ratio:.2f}"


def parse_model_out(text, editable):
    """解析模型输出的 JSONL；行号按 1 基转回 0 基，只接受可改范围内的行。

    主格式是替换对 {"i":行号,"w":[["原","新"]]}（只输出真正要改的几个字，
    比回整行省 3~5 倍输出 token，而这一步的瓶颈就是解码）；
    兼容模型偶尔回退成 {"i":…, "t":"整行"} 的写法。
    """
    out = []
    for line in text.splitlines():
        line = line.strip().strip("`").strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        i = obj.get("i")
        if not isinstance(i, int):
            continue
        i -= 1                                # 模型给的是 1 基行号
        if i not in editable:
            continue
        if isinstance(obj.get("w"), list):
            pairs = [(a, b) for a, b in obj["w"]
                     if isinstance(a, str) and isinstance(b, str) and a and b and a != b]
            if pairs:
                out.append((i, ("pairs", pairs)))
        elif isinstance(obj.get("t"), str):
            out.append((i, ("line", obj["t"].strip())))
    return out


def apply_edits(orig, kind, payload):
    """把替换对作用到原行；原词不在行里、或两个词读音不相近的，逐对驳回。

    为什么逐对再查一道：整行的拼音相似度会被长行稀释，「发一声→发一岁」
    这种只改两个字、且改的不是同音字的错改，整行比例能到 1.00。
    """
    if kind == "line":
        return payload, []
    new, dropped = orig, []
    for a, b in payload:
        if a not in new:
            dropped.append(f"{a}→{b}（原词不在行内）")
            continue
        if sim(a, b) < MIN_PAIR_SIM:
            dropped.append(f"{a}→{b}（{sim(a, b):.2f} 不同音）")
            continue
        new = new.replace(a, b)
    return new, dropped


def run_llm(messages, model, tokenizer, max_tokens):
    """一次对话式生成。

    这版 mlx-lm 的 generate() 只接受拼好的 prompt 字符串（没有 messages 参数），
    采样参数也不叫 temperature，得自己构造一个 sampler。用贪心解码：校对要的是
    可复现，不靠采样拿惊喜。
    """
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    return generate(model, tokenizer, prompt, max_tokens=max_tokens,
                    sampler=make_sampler(temp=0.0), verbose=False)


def fix_chapter(book, name, lines, author, chapter, model, tokenizer, args, log):
    """一章分若干窗口送模型校对，返回 (新 lines, 改动数, 驳回数)。"""
    texts = [l[2] for l in lines]
    new_texts = list(texts)
    n_edit = n_reject = 0
    step = args.chunk
    for start in range(0, len(texts), step):
        ctx_from = max(0, start - args.context)
        window = [(i, texts[i]) for i in range(ctx_from, min(len(texts), start + step))]
        editable = {i for i, _ in window if i >= start}
        prompt = build_prompt(book, author, chapter, window, start)
        raw = run_llm([{"role": "system", "content": SYSTEM},
                       {"role": "user", "content": prompt}], model, tokenizer, args.max_tokens)
        # 模型可能把同一行拆成多条输出，先归并再应用，否则后一条会从前一条的结果里丢掉
        grouped = {}
        for i, (kind, payload) in parse_model_out(raw, editable):
            if kind == "line":
                grouped[i] = ("line", payload)
            else:
                prev = grouped.get(i)
                if prev and prev[0] == "pairs":
                    grouped[i] = ("pairs", prev[1] + payload)
                else:
                    grouped[i] = ("pairs", payload)
        for i, (kind, payload) in sorted(grouped.items()):
            candidate, dropped = apply_edits(texts[i], kind, payload)
            for d in dropped:
                n_reject += 1
                log.append(f"  驳回 [{i}] {d}")
            ok, why = acceptable(texts[i], candidate)
            if ok:
                new_texts[i] = candidate
                n_edit += 1
                log.append(f"  [{i}] {texts[i]}\n  [{i}] {candidate}    （{why}）")
            else:
                n_reject += 1
                log.append(f"  驳回 [{i}] {texts[i]} → {candidate}    （{why}）")
        if args.limit_windows and (start // step + 1) >= args.limit_windows:
            break
    out = [[l[0], l[1], new_texts[i]] for i, l in enumerate(lines)]
    return out, n_edit, n_reject


def worker_shard(shard, args):
    """一个纠错 worker：模型只加载一次，跑完自己那份分片。"""
    items = json.load(open(shard))
    authors = T.book_authors()
    from mlx_lm import load
    model, tokenizer = load(MODEL_DIR)
    for path, book, name in items:
        size = os.path.getsize(path)
        if fix_done(fix_path(book, name), size):
            continue
        lines = asr_lines(book, name, size)
        if not lines:
            continue
        log = []
        t0 = time.time()
        try:
            out, n_edit, n_reject = fix_chapter(
                book, name, lines, authors.get(book, ""), T.chapter_title(name),
                model, tokenizer, args, log)
        except Exception as ex:
            print(json.dumps({"file": f"{book}/{name}", "error": str(ex)[:180]}), flush=True)
            continue
        os.makedirs(os.path.dirname(fix_path(book, name)), exist_ok=True)
        tmp = fix_path(book, name) + f".{os.getpid()}.tmp"
        with open(tmp, "w") as fh:
            json.dump({"sig": size, "asr": FIX_TAG, "src": T.asr_tag(),
                       "dur": lines[-1][1], "nchar": sum(len(l[2]) for l in out),
                       "lines": out}, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, fix_path(book, name))
        print(json.dumps({"file": f"{book}/{name}", "n": len(out), "edit": n_edit,
                          "reject": n_reject, "sec": round(time.time() - t0)},
                         ensure_ascii=False), flush=True)
        for l in log[:args.show_log]:
            print("  " + l, flush=True)


def spawn_workers(todo, args):
    """主进程侧：按可用内存定并行数，分片开子进程（每个进程自己加载模型）。"""
    import queue
    import threading
    free = T.free_memory_gb()
    # 一个 Qwen 14B-4bit 进程占 ~9GB（权重 8.3GB + KV），每多一个就多 9GB
    max_jobs = max(1, int((free - 10) // 9))
    jobs = min(args.jobs, max_jobs)
    print(f"可用内存 {free:.0f}GB → 开 {jobs} 个纠错进程（上限按 {args.jobs} 与内存取小）", flush=True)
    shards = [todo[i::jobs] for i in range(jobs)]
    procs, lines_q = [], queue.Queue()
    for i, shard in enumerate(shards):
        if not shard:
            continue
        path = os.path.join(ROOT, "tools", f".fix-shard-{i}-{os.getpid()}.json")
        json.dump(shard, open(path, "w"), ensure_ascii=False)
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--shard", path,
             "--chunk", str(args.chunk), "--context", str(args.context),
             "--max-tokens", str(args.max_tokens), "--show-log", str(args.show_log),
             "--model", MODEL_DIR],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=sys.stderr, text=True, bufsize=1)
        procs.append((proc, path))
        threading.Thread(target=lambda p=proc: [lines_q.put(l) for l in p.stdout],
                         daemon=True).start()
    t0, n, done = time.time(), 0, 0
    alive = len(procs)
    while alive:
        try:
            line = lines_q.get(timeout=10)
        except queue.Empty:
            alive = sum(1 for p, _ in procs if p.poll() is None)
            continue
        if not line.strip().startswith("{"):
            print(line.rstrip(), flush=True)
            continue
        r = json.loads(line)
        n += 1
        if r.get("error"):
            print(f"  失败 {r['file'][-40:]} {r['error'][:120]}", flush=True)
            continue
        done += 1
        el = time.time() - t0
        print(f"  {n}/{len(todo)} {r['file'][-40:]:42s} 改 {r['edit']:3d} 驳回 {r['reject']:3d} "
              f"{r['sec']:4d}s 已用 {el/60:.0f} 分 预计还剩 {el/done*(len(todo)-n)/60:.0f} 分",
              flush=True)
        alive = sum(1 for p, _ in procs if p.poll() is None)
    for p, path in procs:
        p.wait()
        os.remove(path)
    print(f"完成 {done} 章，用时 {(time.time()-t0)/60:.1f} 分", flush=True)


def main():
    global MODEL_DIR, FIX_TAG
    ap = argparse.ArgumentParser(description="用本地大模型修字幕的同音别字")
    ap.add_argument("--book", action="append", help="书名（可重复）")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--chunk", type=int, default=40, help="一次送模型校对多少行")
    ap.add_argument("--context", type=int, default=4, help="额外带几行只作上下文")
    ap.add_argument("--max-tokens", type=int, default=1200)
    ap.add_argument("--limit-windows", type=int, help="每章只跑前 N 个窗口（调试用）")
    ap.add_argument("--show-log", type=int, default=0, help="每章打印前 N 条改动/驳回详情")
    ap.add_argument("--dry-run", action="store_true", help="只打印提示词，不调模型")
    ap.add_argument("--check", action="store_true", help="只报待修章数就退出（给看门狗探进用）")
    ap.add_argument("--jobs", type=int, default=2, help="并行纠错进程数（每个占 ~9GB 内存）")
    ap.add_argument("--shard", help=argparse.SUPPRESS)      # 内部：worker 分片文件
    ap.add_argument("--model", default=MODEL_DIR)
    args = ap.parse_args()

    MODEL_DIR = args.model
    FIX_TAG = f"fix:{os.path.basename(MODEL_DIR)}"

    if args.shard:
        worker_shard(args.shard, args)
        return

    if args.files:
        items = []
        for f in args.files:
            p = f if os.path.isabs(f) else os.path.join(ROOT, f)
            items.append((p, os.path.basename(os.path.dirname(p)), os.path.basename(p)))
    else:
        items = T.chapters(T.LIB)
        if args.book:
            wanted = set(args.book)
            items = [it for it in items if it[1] in wanted]
        elif not args.all:
            ap.error("需要 --all / --book 书名 / --files 文件列表 之一")
        items = [it for it in items if T.part_valid(T.part_path(it[1], it[2]), os.path.getsize(it[0]))]
        # 与转写同序：最近听过的书先修，你最先在自己正在听的那本上看到效果
        recent = {b: i for i, b in enumerate(T.recent_books())}
        items.sort(key=lambda it: (recent.get(it[1], len(recent)), T.lsc(it[1]), T.lsc(it[2])))
    if args.limit:
        items = items[:args.limit * 4]      # 先粗筛，再按待修名单取前 N（下面限）

    authors = T.book_authors()
    todo = [it for it in items if not fix_done(fix_path(it[1], it[2]), os.path.getsize(it[0]))]
    if args.limit:
        # 限流要作用在「待修」上：先截 items 的话，后续每轮会反复拿到已修完的前 N 章空转
        todo = todo[:args.limit]
    print(f"共 {len(items)} 章，待修 {len(todo)} 章，模型 {os.path.basename(MODEL_DIR)}", flush=True)
    if args.check:
        return
    if not todo and not args.dry_run:
        print("没有待修的章")     # 给看门狗一个明确信号，不加载模型就退出
        return
    if args.dry_run:
        if not todo:
            print("没有待修的章")
            return
        path, book, name = todo[0]
        lines = asr_lines(book, name, os.path.getsize(path))
        print(build_prompt(book, authors.get(book, ""), T.chapter_title(name),
                           [(i, l[2]) for i, l in enumerate(lines[:args.chunk])], 0))
        return

    spawn_workers(todo, args)


if __name__ == "__main__":
    main()
