#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用阿里云百炼的云端语音识别转写整章音频，替代本地 whisper。

为什么上云端：本地 whisper large-v3-turbo 对文言引文、人名、生僻词错误率高
（「佾生」听成「一声」、「唾骂」写成「拓骂」），而百炼的 fun-asr 明确针对
「中文古诗词的韵律、节奏与文言表达」做过优化并主打有声读物场景；
qwen-audio-3.x-asr-flash-filetrans 则支持即时热词，可以把「曾国荃、靖港、佾生」
直接喂进识别上下文。两者都按音频时长计费 ¥0.00022/秒（全库 368 小时约 ¥290），
RPM 600，几十路并发没压力——本机 GPU 要跑十几小时的事，云端几十分钟。

音频怎么给云端：转写接口只吃 URL。本地文件用 SDK 的临时上传通道
（OssUtils.upload_file 换回 oss:// 链接，48 小时有效，调用时带请求头
X-DashScope-OssResourceResolve: enable）。官方注明该通道限流 100 QPS 且不支持
扩容，所以并发默认 12，并且每章只传一次。

用法：
    python3 tools/dashscope-asr.py --probe                      # 两个模型跑同一章对比
    python3 tools/dashscope-asr.py --book 曾国藩的正面与侧面     # 一本书
    python3 tools/dashscope-asr.py --all                        # 全库（跳过已转的章）
    python3 tools/dashscope-asr.py --all --model fun-asr --concurrency 12

产物与本地 whisper 完全同构：tools/transcripts-parts/<书>/<章>.json，标签
dashscope:<模型>。所以打包、纠错、同步都不用改，只要之后都用
`python3 tools/transcribe.py --backend dashscope --pack-only`。
"""

import argparse
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import transcribe as T  # noqa: E402  复用章节枚举、成句、逐章落盘与标签约定

import dashscope  # noqa: E402
from dashscope.audio.asr import Transcription  # noqa: E402
from dashscope.utils.oss_utils import OssUtils  # noqa: E402

# 即时热词只有 qwen-audio-3.x-asr-flash-filetrans 支持；fun-asr 要走预建词表
INLINE_HOTWORD_MODELS = ("qwen-audio-3.1-asr-flash-filetrans", "qwen-audio-3.0-asr-flash-filetrans")
DEFAULT_MODEL = os.environ.get("SONUX_DS_ASR_MODEL", "fun-asr")
# 任务轮询节奏：14 分钟的音频通常 1~2 分钟出结果
POLL_SECONDS = 10
TASK_TIMEOUT = 30 * 60


def key():
    k = T.api_key()
    if not k:
        sys.exit("找不到百炼密钥：export DASHSCOPE_API_KEY=sk-... 或写进 ~/.config/sonux/llm-key")
    return k


def upload(path):
    """本地音频 → oss:// 临时链接（48 小时有效）。

    每次上传顺带申请一次上传凭证，那就是官方限流 100 QPS 的接口；我们并发只有
    十几路，离限流很远，不值得为了复用凭证再加一层锁。
    """
    url, _ = OssUtils.upload(model=MODEL, file_path=path, api_key=API_KEY)
    if not url:
        raise RuntimeError("音频上传失败")
    return url


def hotwords(book, name, authors):
    """本章的即时热词：书名、作者、章节名与文件名里的专名，权重 50（超级热词）。"""
    words = {book: 50}
    author = authors.get(book, "")
    if author:
        words[author] = 50
    chapter = T.chapter_title(name)
    for part in [chapter] + chapter.replace("：", " ").split():
        if 2 <= len(part) <= 12:
            words[part] = 5
    return dict(list(words.items())[:50])       # 超级热词最多 50 个


def submit(path, book, name, authors):
    """上传并提交转写任务，返回 task_id。"""
    url = upload(path)
    kwargs = {}
    if MODEL in INLINE_HOTWORD_MODELS:
        kwargs["vocabulary"] = hotwords(book, name, authors)
    if MODEL.startswith("paraformer") or MODEL.startswith("fun-asr"):
        kwargs["language_hints"] = ["zh"]
    resp = Transcription.async_call(
        MODEL, [url], api_key=API_KEY,
        headers={"X-DashScope-OssResourceResolve": "enable"},
        # 字幕不需要说话人分离；开启后每音轨独立计费，别乱开
        diarization_enabled=False, **kwargs)
    if resp.status_code != 200:
        raise RuntimeError(f"提交失败 {resp.status_code} {str(resp.message)[:120]}")
    return resp.output["task_id"]


def wait_task(task_id):
    """轮询到任务结束，返回 transcription_url 对应的结果 JSON。"""
    deadline = time.time() + TASK_TIMEOUT
    while time.time() < deadline:
        resp = Transcription.fetch(task=task_id, api_key=API_KEY)
        status = (resp.output or {}).get("task_status")
        if status == "SUCCEEDED":
            results = (resp.output or {}).get("results") or []
            if not results:
                # 新版单文件接口没有 results 数组，只有 result 对象
                single = (resp.output or {}).get("result") or {}
                results = [single] if single else []
            one = results[0]
            if one.get("subtask_status") not in (None, "SUCCEEDED"):
                raise RuntimeError(f"子任务失败 {one.get('code')} {str(one.get('message'))[:120]}")
            url = one["transcription_url"]
            with urllib.request.urlopen(url, timeout=60) as r:
                return json.load(r)
        if status in ("FAILED", "UNKNOWN"):
            raise RuntimeError(f"任务 {status}")
        time.sleep(POLL_SECONDS)
    raise RuntimeError("任务超时")


def to_segments(data):
    """百炼的转写 JSON → 我们的 [{b,e,t}]：句子级时间戳，单位毫秒。"""
    segs = []
    for tr in data.get("transcripts") or []:
        for s in tr.get("sentences") or []:
            text = (s.get("text") or "").strip()
            if not text:
                continue
            segs.append({"b": float(s.get("begin_time") or 0) / 1000.0,
                         "e": float(s.get("end_time") or 0) / 1000.0,
                         "t": text})
    return segs


def one(item, authors, args):
    """转写一章并落盘；已转过且音频未变的直接跳过。"""
    path, book, name = item
    rel = f"{book}/{name}"
    size = os.path.getsize(path)
    if T.part_valid(T.part_path(book, name), size):
        return {"file": rel, "skipped": True}
    t0 = time.time()
    try:
        task_id = submit(path, book, name, authors)
        data = wait_task(task_id)
    except Exception as ex:
        return {"file": rel, "error": str(ex)[:200]}
    segs = to_segments(data)
    if not segs:
        return {"file": rel, "error": "结果为空"}
    dur = max(s["e"] for s in segs)
    lines = T.write_part(book, name, size, dur, segs)
    out = {"file": rel, "n": len(lines), "nchar": sum(len(l[2]) for l in lines),
           "sec": round(time.time() - t0), "task": task_id[:8]}
    return out


def probe(items, authors, args):
    """同一章分别用两个模型转，打印前面几句与关键专名，用来看质量和实测耗时。"""
    global MODEL
    path, book, name = items[0]
    for model in args.probe_models:
        MODEL = model
        T.ASR_MODEL = model
        print(f"\n### {model}")
        t0 = time.time()
        try:
            task_id = submit(path, book, name, authors)
            data = wait_task(task_id)
        except Exception as ex:
            print("  失败：", ex)
            continue
        segs = to_segments(data)
        el = time.time() - t0
        print(f"  用时 {el:.0f}s（含上传与排队）  {len(segs)} 句  "
              f"约 ¥{max(s['e'] for s in segs) * 0.00022:.2f}")
        for s in segs[:10]:
            print(f"  [{s['b']:6.1f}] {s['t']}")
        text = "".join(s["t"] for s in segs)
        for w in ["唾骂", "靖港", "湖口", "佾生", "曾国荃", "家书", "壬辰"]:
            print(f"    含「{w}」{'✓' if w in text else '✗'}")


def main():
    global MODEL, API_KEY
    ap = argparse.ArgumentParser(description="百炼云端语音识别转写整章音频")
    ap.add_argument("--book", action="append", help="书名（可重复）")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--concurrency", type=int, default=12, help="同时处理的章数（上传通道限 100 QPS）")
    ap.add_argument("--probe", action="store_true", help="同一章多模型对比，不写结果")
    ap.add_argument("--probe-models", nargs="*",
                    default=["fun-asr", "qwen-audio-3.1-asr-flash-filetrans"])
    args = ap.parse_args()

    API_KEY = key()
    dashscope.api_key = API_KEY
    MODEL = args.model
    T.ASR_BACKEND = "dashscope"
    T.ASR_MODEL = args.model

    if args.files:
        items = []
        for f in args.files:
            p = f if os.path.isabs(f) else os.path.join(T.ROOT, f)
            items.append((p, os.path.basename(os.path.dirname(p)), os.path.basename(p)))
    else:
        items = T.chapters(T.LIB)
        if args.book:
            wanted = set(args.book)
            items = [it for it in items if it[1] in wanted]
        elif not (args.all or args.probe):
            ap.error("需要 --all / --book 书名 / --files 文件列表 / --probe 之一")
        if args.probe:
            # 探针用已经转过的书：本地 whisper 的结果就在手边，好对比
            items = [it for it in items if T.part_valid(T.part_path(it[1], it[2]),
                                                        os.path.getsize(it[0]))] or items
        else:
            items = [it for it in items if not T.part_valid(T.part_path(it[1], it[2]),
                                                            os.path.getsize(it[0]))]
        recent = {b: i for i, b in enumerate(T.recent_books())}
        items.sort(key=lambda it: (recent.get(it[1], len(recent)), T.lsc(it[1]), T.lsc(it[2])))
    if args.limit:
        items = items[:args.limit]
    if not items:
        print("没有要转写的章")
        return

    authors = T.book_authors()
    if args.probe:
        probe(items, authors, args)
        return

    from concurrent.futures import ThreadPoolExecutor
    print(f"云端转写：{args.model}，{len(items)} 章，并发 {args.concurrency}", flush=True)
    t0, n, done = time.time(), 0, 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(one, it, authors, args) for it in items]
        for f in futures:
            r = f.result()
            n += 1
            if r.get("error"):
                print(f"  失败 {r['file'][-40:]} {r['error'][:120]}", flush=True)
                continue
            if r.get("skipped"):
                continue
            done += 1
            el = time.time() - t0
            print(f"  {n}/{len(items)} {r['file'][-40:]:42s} {r['n']:3d} 句 {r['sec']:4d}s "
                  f"已用 {el/60:.1f} 分 预计还剩 {el/done*(len(items)-n)/60:.0f} 分", flush=True)
    print(f"完成 {done} 章，用时 {(time.time()-t0)/60:.1f} 分", flush=True)


if __name__ == "__main__":
    main()
