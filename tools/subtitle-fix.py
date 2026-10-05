#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用大模型修字幕里的同音别字：ASR 只管时间轴，文字交给语言模型。

两个模型后端（闸门逻辑共用，换后端不影响产物结构）：
- 本地 MLX（默认）：tools/models/Qwen2.5-14B-Instruct-4bit，每进程约 9GB 内存，
  一次只能跑 1~2 个，全库要二十几小时；14B 的知识量对文言引文与人名不够用。
- 云端 API（--api）：OpenAI 兼容接口，默认阿里云百炼。上下文可以开大到 160 行/次，
  多线程并发，全库几十分钟；专名与文言还原明显更强。密钥只从环境变量读：
  DASHSCOPE_API_KEY（或 SONUX_LLM_API_KEY），绝不写进仓库。

为什么要这一步：whisper 与中文专用 Paraformer 我都试过，两路在同一类地方一起栽——
文言引文、人名、地名、官职名、生僻词（「曾国荃」一个写成「曾国权」一个写成「曾国醛」）。
ASR 只有声学、没有语言知识，而这类错误的特征正是「读音对、字形错」，恰好是语言模型擅长的。

三道闸，防止语言模型把「纠错」变成「改写」（不管本地还是云端都一视同仁）：
1. 逐词拼音相似度 ≥0.6：挡得住「一声→一岁」(0.50)、「窃→谴」(0.57)，
   又留得住「虹口→湖口」(0.67)；
2. 整行拼音 ≥0.85 且长度变化 ≤2 字：挡住「顺手把句子改通顺」；
3. 拿不准就不改：模型只输出它确实改动的行号，其余保持 ASR 原文。

用法：
    python3 tools/subtitle-fix.py --book 曾国藩的正面与侧面            # 本地模型
    DASHSCOPE_API_KEY=sk-... tools/.venv-mlx/bin/python3 tools/subtitle-fix.py \
        --api --all --workers 8 --chunk 160                            # 云端校对
    ... --api --probe 3                                                # 先跑 3 章看质看成本
密钥也可以放 ~/.config/sonux/llm-key（一行，chmod 600），后台看门狗不需要 export。
产物：tools/transcripts-fix/<书>/<章>.json；transcribe.py 打包时优先取这份，
缺的章退回 ASR 版。标签里带模型名与规则版本，换模型或改闸门会自动重跑。
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import transcribe as T  # noqa: E402  复用章节枚举、成句、路径与打包约定

ROOT = T.ROOT
FIX_DIR = os.path.join(ROOT, "tools", "transcripts-fix")
MODEL_DIR = os.environ.get(
    "SONUX_FIX_MODEL", os.path.join(ROOT, "tools", "models", "Qwen2.5-14B-Instruct-4bit"))
# 云端后端：用户买的是百炼 Token Plan 套餐，必须用套餐专属 Base URL 与 sk-sp- 开头的 Key，
# 与按量付费的 dashscope.aliyuncs.com 完全不互通（混用会 401 或走成按量扣费）
API_BASE = os.environ.get(
    "SONUX_LLM_BASE_URL",
    "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
API_MODEL = os.environ.get("SONUX_LLM_MODEL", "qwen3.8-max")
MIN_PINYIN_SIM = 0.85      # 整行拼音相似度低于此就认定模型改的不是同一个读音，驳回
# 单个替换词的拼音相似度下限。0.6 是实测定的：挡得住「一声→一岁」(0.50)、
# 「窃→谴」(0.57)、「魁丑→丑魁」(0.57) 这类错改，又留得住「虹口→湖口」(0.67)、
# 「大主→大辱」(0.67) 这类对改；抬到 0.7 就会把后面这两个好改动一起打掉
MIN_PAIR_SIM = 0.6
# 规则版本：改提示词或阈值时递增，旧结果会自动重跑（逐章文件里记着这个标签）
RULES_VER = "v2"
LEN_SLACK = 2              # 允许字数增减（补漏字/删赘字），再多就视为改写
# 当前使用的模型名（main 里按 --api 定）；进结果标签，换模型自动重跑
LLM_NAME = os.path.basename(MODEL_DIR)
FIX_TAG = f"fix:{LLM_NAME}:{RULES_VER}"

SYSTEM = (
    "你在校对中文有声书的自动转写字幕。字幕来自语音识别，声学上没错，"
    "但常有同音字、近音字用错，尤其是文言引文、人名、地名、官职名和生僻词。"
    "你的任务是按上下文把这些别字改回来。")

RULES = (
    "规则：\n"
    "1. 只改词，不改句：不许重写、不许润色、不许增删信息，句子的说法必须保持原样。\n"
    "2. 只能改成与原字同音或近音的字（声调可以不同）。做不到就不提这一行。\n"
    "3. 一行最多提四处替换；只补同音字，不要把句子改得更通顺。\n"
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
            # 模型偶尔回成三元组（多带一个说明）或混进非字符串，原来直接
            # 「too many values to unpack」把整章打崩（实测 43 章因此反复失败）；
            # 这里只取前两项，畸形的跳过，绝不让一章因为一条判定全丢
            pairs = []
            for item in obj["w"]:
                if isinstance(item, (list, tuple)) and len(item) >= 2:
                    a, b = str(item[0]), str(item[1])
                    if a and b and a != b:
                        pairs.append((a, b))
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


class LocalMLX:
    """本地 MLX 模型：模型只加载一次，贪心解码（校对要可复现，不靠采样拿惊喜）。"""

    def __init__(self, model_dir):
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler
        self.model, self.tokenizer = load(model_dir)
        self.sampler = make_sampler(temp=0.0)
        self.name = os.path.basename(model_dir)

    def chat(self, messages, max_tokens):
        from mlx_lm import generate
        # 这版 mlx-lm 的 generate() 只接受拼好的 prompt 字符串（没有 messages 参数）
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(self.model, self.tokenizer, prompt, max_tokens=max_tokens,
                        sampler=self.sampler, verbose=False)


class ApiLLM:
    """OpenAI 兼容接口的云端模型（默认百炼 Token Plan 套餐入口）。

    用 urllib 而不是官方 SDK：环境里没必要再多一个依赖，我们只用 chat/completions
    一个端点。线程安全：云端路径靠多线程并发提速，token 统计要累加。

    两个实测出来的必要设置（qwen3.7/3.8 这类混合推理模型）：
    - enable_thinking=false：不开的话模型先写一大段思考，一个 40 行窗口能烧到 240 秒
      超时；关掉后 13 秒返回，质量不受影响；
    - 流式读取：非流式要整段等完，套餐入口读超时很宽，流式能避开卡死的连接，
      也能从最后一个块拿到 usage。
    """

    def __init__(self, base, model, key, thinking=False):
        self.base, self.name, self.key = base.rstrip("/"), model, key
        # 只有千问系列认 enable_thinking 这个参数，别的模型传了可能被拒
        self.thinking = thinking and model.startswith("qwen")
        self.lock = threading.Lock()
        self.calls = self.in_tokens = self.out_tokens = 0

    def chat(self, messages, max_tokens):
        body = {"model": self.name, "messages": messages, "max_tokens": max_tokens,
                "temperature": 0.0, "stream": True,
                "stream_options": {"include_usage": True}}
        if self.name.startswith("qwen"):
            body["enable_thinking"] = self.thinking
        last_err = None
        for attempt in range(5):
            got = []
            usage = {}
            try:
                req = urllib.request.Request(
                    f"{self.base}/chat/completions", data=json.dumps(body).encode(),
                    headers={"Content-Type": "application/json",
                             "Authorization": "Bearer " + self.key,
                             "Accept": "text/event-stream"})
                with urllib.request.urlopen(req, timeout=300) as r:
                    for line in r:
                        if not line.startswith(b"data:"):
                            continue
                        payload = line[5:].strip()
                        if payload == b"[DONE]":
                            break
                        chunk = json.loads(payload)
                        if chunk.get("usage"):
                            usage = chunk["usage"]
                        for choice in chunk.get("choices") or []:
                            piece = (choice.get("delta") or {}).get("content")
                            if piece:
                                got.append(piece)
                with self.lock:
                    self.calls += 1
                    self.in_tokens += int(usage.get("prompt_tokens") or 0)
                    self.out_tokens += int(usage.get("completion_tokens") or 0)
                return "".join(got)
            except Exception as ex:
                # 密钥错、模型名错、被内容审查拒了都要看到具体原因，不能只剩
                # 「HTTP Error 400」一句话（实际踩过：查不到原因只能猜）
                body = ""
                reader = getattr(ex, "read", None)
                if reader:
                    try:
                        body = reader()[:300].decode("utf-8", "replace")
                    except Exception:
                        body = ""
                last_err = f"{type(ex).__name__} {getattr(ex, 'code', '')} {body or ex}"
                if getattr(ex, "code", None) in (400, 401, 403, 404):
                    raise RuntimeError(last_err)
                time.sleep(2 ** attempt)
        raise RuntimeError(f"云端接口连续 5 次失败，最后一次：{last_err}")


def rejected_by_guard(err):
    """这错是不是「输入被内容审查拦下」一类？这类重试没意义，只能把窗口切小。"""
    text = str(err)
    return "400" in text and ("data_inspection" in text or "inappropriate content" in text)


def make_llm(args):
    """按命令行返一个可调用的模型后端。"""
    if args.api:
        key = T.api_key()      # 环境变量或 ~/.config/sonux/llm-key，与转写工具共用一份实现
        if not key:
            sys.exit("走 --api 但没找到密钥：export DASHSCOPE_API_KEY=sk-...，"
                     "或者把密钥写进 ~/.config/sonux/llm-key（chmod 600）")
        return ApiLLM(args.base_url, args.llm_model, key, thinking=args.thinking)
    return LocalMLX(MODEL_DIR)


def fix_chapter(book, name, lines, author, chapter, llm, args, log):
    """一章分若干窗口送模型校对，返回 (新 lines, 改动数, 驳回数)。

    窗口被内容审查拦下时递归对半切小重试：实测有章节 80 行被拒、40 行能过
    （讲战争的内容容易触发 data_inspection_failed），不拆的话整章会永远卡住。
    """
    texts = [l[2] for l in lines]
    new_texts = list(texts)
    state = {"edit": 0, "reject": 0}

    def apply_window(start, stop):
        window = [(i, texts[i]) for i in range(max(0, start - args.context), stop)]
        editable = {i for i in range(start, stop)}
        prompt = build_prompt(book, author, chapter, window, start)
        try:
            raw = llm.chat([{"role": "system", "content": SYSTEM},
                            {"role": "user", "content": prompt}], args.max_tokens)
        except Exception as ex:
            if not rejected_by_guard(ex) or stop - start <= 8:
                raise
            mid = (start + stop) // 2
            log.append(f"  窗口 {start}-{stop} 被内容审查拦下，拆成两半重试")
            apply_window(start, mid)
            apply_window(mid, stop)
            return
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
                state["reject"] += 1
                log.append(f"  驳回 [{i}] {d}")
            ok, why = acceptable(texts[i], candidate)
            if ok:
                new_texts[i] = candidate
                state["edit"] += 1
                log.append(f"  [{i}] {texts[i]}\n  [{i}] {candidate}    （{why}）")
            else:
                state["reject"] += 1
                log.append(f"  驳回 [{i}] {texts[i]} → {candidate}    （{why}）")

    step = args.chunk
    for idx, start in enumerate(range(0, len(texts), step)):
        apply_window(start, min(len(texts), start + step))
        if args.limit_windows and (idx + 1) >= args.limit_windows:
            break
    out = [[l[0], l[1], new_texts[i]] for i, l in enumerate(lines)]
    return out, state["edit"], state["reject"]


def fix_one(item, llm, authors, args):
    """校对一章并落盘，返回一行结果（本地 worker 与云端线程共用这一份实现）。"""
    path, book, name = item
    size = os.path.getsize(path)
    if fix_done(fix_path(book, name), size):
        return {"file": f"{book}/{name}", "skipped": True}
    lines = asr_lines(book, name, size)
    if not lines:
        return {"file": f"{book}/{name}", "skipped": True}
    log = []
    t0 = time.time()
    out, n_edit, n_reject = fix_chapter(
        book, name, lines, authors.get(book, ""), T.chapter_title(name), llm, args, log)
    os.makedirs(os.path.dirname(fix_path(book, name)), exist_ok=True)
    tmp = fix_path(book, name) + f".{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w") as fh:
        json.dump({"sig": size, "asr": FIX_TAG, "src": T.asr_tag(),
                   "dur": lines[-1][1], "nchar": sum(len(l[2]) for l in out),
                   "lines": out}, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, fix_path(book, name))
    return {"file": f"{book}/{name}", "n": len(out), "edit": n_edit, "reject": n_reject,
            "sec": round(time.time() - t0), "log": log[:args.show_log]}


def worker_shard(shard, args):
    """一个本地纠错 worker：模型只加载一次，跑完自己那份分片。"""
    items = json.load(open(shard))
    authors = T.book_authors()
    llm = make_llm(args)
    for item in items:
        try:
            r = fix_one(item, llm, authors, args)
        except Exception as ex:
            r = {"file": f"{item[1]}/{item[2]}", "error": str(ex)[:180]}
        log = r.pop("log", None)
        print(json.dumps(r, ensure_ascii=False), flush=True)
        for l in (log or []):
            print("  " + l, flush=True)


def run_api(todo, args):
    """云端后端：单进程多线程按章并发（IO 等待为主，不占内存也不占 GPU）。"""
    from concurrent.futures import ThreadPoolExecutor
    authors = T.book_authors()
    llm = make_llm(args)
    print(f"云端校对：{llm.name} @ {llm.base}，并发 {args.workers}，每窗口 {args.chunk} 行",
          flush=True)
    t0, n, done = time.time(), 0, 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(fix_one, it, llm, authors, args) for it in todo]
        for f in futures:                      # futures 保留提交顺序，进度按章递增
            try:
                r = f.result()
            except Exception as ex:
                r = {"error": str(ex)[:180]}
            n += 1
            if r.get("error"):
                print(f"  失败 {r['error']}", flush=True)
                continue
            if r.get("skipped"):
                continue
            done += 1
            el = time.time() - t0
            print(f"  {n}/{len(todo)} {r['file'][-40:]:42s} 改 {r['edit']:3d} 驳回 {r['reject']:3d} "
                  f"{r['sec']:4d}s 已用 {el/60:.1f} 分 预计还剩 {el/done*(len(todo)-n)/60:.0f} 分",
                  flush=True)
            for l in r.get("log") or []:
                print(l, flush=True)
    print(f"完成 {done} 章，用时 {(time.time()-t0)/60:.1f} 分；"
          f"调用 {llm.calls} 次，输入 {llm.in_tokens/1e6:.2f}M token，"
          f"输出 {llm.out_tokens/1e6:.2f}M token", flush=True)


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
    # 本地 worker 每个吃 7.8GB，父进程被杀时必须带走它们，不然变孤儿把机器顶爆
    T.guard_children([p for p, _ in procs])
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
    global MODEL_DIR, FIX_TAG, LLM_NAME
    ap = argparse.ArgumentParser(description="用大模型修字幕的同音别字")
    ap.add_argument("--book", action="append", help="书名（可重复）")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--chunk", type=int, help="一次送模型校对多少行（本地默认 40，云端 160）")
    ap.add_argument("--context", type=int, default=4, help="额外带几行只作上下文")
    ap.add_argument("--max-tokens", type=int, help="单次回复上限（本地 1200，云端 3000）")
    ap.add_argument("--limit-windows", type=int, help="每章只跑前 N 个窗口（调试用）")
    ap.add_argument("--show-log", type=int, default=0, help="每章打印前 N 条改动/驳回详情")
    ap.add_argument("--probe", type=int, help="只跑 N 章并打印改动详情（看质量与成本）")
    ap.add_argument("--dry-run", action="store_true", help="只打印提示词，不调模型")
    ap.add_argument("--check", action="store_true", help="只报待修章数就退出（给看门狗探进用）")
    ap.add_argument("--api", action="store_true", help="用云端 OpenAI 兼容接口，不跑本地模型")
    ap.add_argument("--thinking", action="store_true",
                    help="允许千问模型先思考（实测一个 40 行窗口会烧到 240 秒超时，默认关掉）")
    ap.add_argument("--base-url", default=API_BASE, help="OpenAI 兼容入口地址")
    ap.add_argument("--llm-model", default=API_MODEL, help="云端模型名（如 qwen-plus / qwen-max）")
    ap.add_argument("--workers", type=int, default=8, help="云端并发线程数")
    ap.add_argument("--jobs", type=int, default=2, help="本地并行纠错进程数（每个占 ~9GB 内存）")
    ap.add_argument("--shard", help=argparse.SUPPRESS)      # 内部：worker 分片文件
    ap.add_argument("--model", default=MODEL_DIR)
    args = ap.parse_args()

    MODEL_DIR = args.model
    LLM_NAME = args.llm_model if args.api else os.path.basename(MODEL_DIR)
    FIX_TAG = f"fix:{LLM_NAME}:{RULES_VER}"
    # 云端窗口开大能大幅减少调用次数（上下文不再只靠 4 行），但单次回复也要给够
    args.chunk = args.chunk or (80 if args.api else 40)
    args.max_tokens = args.max_tokens or (4000 if args.api else 1200)
    if args.probe:
        args.limit = args.probe
        args.show_log = args.show_log or 40

    if args.shard:
        worker_shard(args.shard, args)
        return

    if args.files:
        items = []
        for f in args.files:
            p = f if os.path.isabs(f) else os.path.join(ROOT, f)
            book = os.path.basename(os.path.dirname(p))
            # 传进来多半是 parts 结果文件（xxx.mp3.json），但 fix_one 用 getsize(路径)
            # 当 sig：拿 json 的字节数去比音频的 sig 永远对不上，整章会被静默跳过
            # （表现为「待修 1 章」却「完成 0 章、调用 0 次」）。一律换成音频路径。
            name = os.path.basename(p)[:-5] if p.endswith(".json") else os.path.basename(p)
            audio = os.path.join(T.LIB, book, name)
            items.append((audio if os.path.exists(audio) else p, book, name))
    else:
        items = T.chapters(T.LIB)
        if args.book:
            wanted = set(args.book)
            items = [it for it in items if it[1] in wanted]
        elif not (args.all or args.probe):
            ap.error("需要 --all / --book 书名 / --files 文件列表 / --probe N 之一")
        items = [it for it in items if T.part_valid(T.part_path(it[1], it[2]), os.path.getsize(it[0]))]
        # 与转写同序：最近听过的书先修，你最先在自己正在听的那本上看到效果
        recent = {b: i for i, b in enumerate(T.recent_books())}
        items.sort(key=lambda it: (recent.get(it[1], len(recent)), T.lsc(it[1]), T.lsc(it[2])))
    authors = T.book_authors()
    todo = [it for it in items if not fix_done(fix_path(it[1], it[2]), os.path.getsize(it[0]))]
    if args.limit:
        # 只截「待修」名单。早先还额外把 items 截到 limit*4，结果待修的章全落在
        # 截断线之后，看门狗每轮都报「没有待修的章」空转了两个小时
        todo = todo[:args.limit]
    print(f"共 {len(items)} 章，待修 {len(todo)} 章，模型 {LLM_NAME}"
          + ("（云端）" if args.api else "（本地）"), flush=True)
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

    if args.api:
        run_api(todo, args)
    else:
        spawn_workers(todo, args)


if __name__ == "__main__":
    main()
