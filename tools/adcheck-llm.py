#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二遍去广告：让云端大模型读整章字幕，找第一遍漏掉的口播广告。

为什么还要第二遍：第一遍 tools/adcheck.py 靠「广告关键词词表 + 声纹离群 + 静音吸附」，
词表只能命中带品牌字的句子。2026-10 抽样实测（34 章，每书一章）：切完之后音频里仍残留
约 29% 的广告时长，而 adcheck 的 AD_RE/CARD_RE 只覆盖其中 15%——剩下的宣传句根本不提
「静雅思听」（「布咕1.0正式上线」「4330个音频内容为您所选」「答案就在我的七个美国老师
系列文章」「请您继续收听下一篇××」），这类只有语言模型读得出来。

为什么现在做得动：全库整章字幕（whisper-large-v3-turbo 出时间轴 + 百炼校对文字）已经落在
transcripts/，品牌词不再是一句话 91 种错别字写法。这里读的是**已经切过一遍的干净音频**的
字幕，所以标出来的广告句必然都是漏网的，直接就是待切除清单，不用再猜声学特征。

三道保险，只为压住本工具唯一的硬风险——把正文切掉：
1. 逐行复核：标注模型（默认 qwen3.8-max）标完，换一个不同源的模型（deepseek-v4-pro）带着
   上下文重判这一行是不是广告，只有判「是」的留下。实测单模型标注 precision 约 78%，
   复核后能压到九成以上；
2. 缝合复核（S6）：把候选切口左右各 3 行交给两个独立模型判「切掉的是不是广告、左右接不接
   得上」，任一个说正文断裂就整刀退回；片头片尾的刀只有一侧可比，靠上一条的逐行复核兜住；
3. 硬闸门：单章新增切除比例 ≤ --max-pct、切口 ≥ --min-cut、纯信息卡只在片头/片尾
   --head-tail 秒内生效、不许把整章切没。

时间轴：产出的秒数就是**当前 TestBooks/ 文件**（已被第一遍切过）的时间轴，所以 --plan
直接喂给 adcut-apply.py 再切一轮，不需要做时间换算；切完记得跑
tools/adcheck-remap-progress.py 换算 App 里的播放进度。

用法：
    python3 tools/adcheck-llm.py --book 民主的细节                 # 扫描并打印小结
    python3 tools/adcheck-llm.py --book 民主的细节 --emit          # 同时写切除清单
    python3 tools/adcheck-llm.py --all --passes 2 --workers 6 --emit       # 全库（扫两遍取并集）
    python3 tools/adcheck-llm.py --all --union --passes 1 --emit           # 再补扫一遍，只增不减
    # 第二轮切到独立目录，别覆盖第一遍的 TestBooks-clean/，报告也要另指一个文件：
    python3 tools/adcut-apply.py --plan tools/adcuts-llm.jsonl --dest TestBooks-clean2 \
        --report tools/adcut-report-llm.csv --book 民主的细节 --apply
    python3 tools/adcut-apply.py --plan tools/adcuts-llm.jsonl --dest TestBooks-clean2 --verify 5
产物：tools/adcuts-llm.jsonl（与 adcuts.jsonl 同字段，adcut-apply 可直接吃）、
      tools/adcheck-llm-report.csv（每一刀一行：起止、类别、被切文本、复核意见、采纳/退回）。
密钥只从 DASHSCOPE_API_KEY 或 ~/.config/sonux/llm-key 读，绝不写进仓库。
幂等：清单按 file 去重，重跑只补没做过的章；被内容审查拦下的窗口自动对半拆小重试。
解释器：与 adcheck.py / adcut-apply.py 同一个（需要 numpy 与 imageio-ffmpeg）。
"""

import argparse
import csv
import json
import os
import re
import sys
import threading
import time
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import transcribe as T                       # noqa: E402  复用密钥读取
import adcheck as AC                                      # noqa: E402  共用静音探测
from adcheck import AD_RE, CARD_RE, ROOT, probe_len  # noqa: E402  词表只用来给无上下文的刀加一道旁证

LIB = os.path.join(ROOT, "TestBooks")
TR = os.path.join(ROOT, "transcripts")
PLAN_OUT = os.path.join(ROOT, "tools", "adcuts-llm.jsonl")
REPORT = os.path.join(ROOT, "tools", "adcheck-llm-report.csv")
API_BASE = os.environ.get(
    "SONUX_LLM_BASE_URL",
    "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
CATS = ("brand", "shop", "promo", "card", "note", "other")
# 强类别：句子里就带着品牌/电商/出品这类硬特征，逐行复核看不出时仍敢下刀
STRONG = ("brand", "shop", "note")
RULES_VER = "llm-ad-v4"     # 提示词或闸门变了就递增，旧章自动重扫
SEAM_LINES = 3
stats = Counter()        # 锚定失败、审查拆窗等过程计数

LABEL_SYS = (
    "你在审中文有声书的字幕，判断哪些行是**朗读者念的广告/宣传**而不是这本书的正文。"
    "这批音频来自「静雅思听」网站，除正文外还念：台呼口号（「静雅思听，让智慧也动听」「智慧声音」"
    "「等你一起出发」）、网站/微信公众号/淘宝店/客户端推广（客户端叫「小布谷」，会说版本号、"
    "上线、音频内容数量）、其他书目或光盘系列宣传（「书生系列光盘」「悦耳系列光盘」「七个美国老师」"
    "这类整段念别的书的句子或书名）、章节信息卡（「《书名》，N，作者××，朗读者××」）、"
    "节目预告与出品声明（「本内容由静雅思听网站制作出品」「请您继续收听下一篇××」「感谢观看」）。")

LABEL_RULES = (
    "规则：\n"
    "1. 只标你确信是广告/宣传/信息卡/预告的行；正文一律不标，拿不准也不标（宁可漏标）。\n"
    "2. 正文里出现「朗读」「作者」「下载」「网站」这些词不算广告，别标。\n"
    "3. 类别代码：brand=台呼口号，shop=网站/公众号/电商/客户端，promo=他书他碟宣传，"
    "card=章节信息卡（书名/作者/朗读者），note=预告或出品声明，other=其他口播广告。\n"
    '4. 每行一个 JSON 对象：{"i":行号,"k":"类别代码"}；没有要标的就一行都不输出。\n'
    "5. 只输出 JSON 行，不要解释，不要代码块标记。")

REVIEW_RULES = (
    "下面每段是一段连续字幕，其中带 >>> 的那行被自动判为广告。只判断那一行：\n"
    "0 = 确实是广告/宣传/信息卡/预告（可以切）\n"
    "1 = 是这本书的正文（不能切）\n"
    "2 = 半广告半正文，或该行被掐断看不出\n"
    '每段一个 JSON：{"i":段号,"t":">>> 那行开头 4~8 个字","v":0|1|2}\n只输出 JSON 行，不要解释。')

SEAM_SYS = (
    "中文有声书音频里夹着「静雅思听」网站的口播广告，已按候选切口切除。现在给你切除后**缝合处"
    "左右**的字幕：左边几行是切口前的正文尾，右边几行是切口后的正文头。判断中间被切掉的那段是什么。")

SEAM_RULES = (
    "0 = 切掉的是广告/宣传/信息卡/预告：左右两边各自都是完整的句子（这刀能切）\n"
    "1 = 切掉的很可能是正文：左边末句说到一半没说完，或右边首句是上一句的后半截（这刀不能切）\n"
    "2 = 切掉的是正文里的引文或别的书的摘录（删不删都有代价，默认不切）\n"
    "3 = 碎片看不出\n"
    "注意：广告本来就插在两段正文之间，所以**左右话题不一样是正常现象，不是证据**；"
    "字幕由语音识别产生，**错别字、乱码、英文串词也都不算证据**，只看句子有没有被拦腰切断。\n"
    '每段一个 JSON：{"i":序号,"t":"切口后首句开头 4~8 个字","v":0|1|2|3,"why":"不超过12字"}\n'
    "只输出 JSON 行。")


class LLM:
    """百炼 Token Plan 的 chat 客户端（与 tools/subtitle-fix.py 同一套必要设置）。

    enable_thinking=false：混合推理模型不开的话先写一大段思考，一个窗口能烧到 240 秒超时。
    流式读取：套餐入口读超时很宽，流式能避开卡死的连接，也能从最后一个块拿到 usage。
    glm/deepseek 会先吐 reasoning_content，max_tokens 要给足，否则正文被思考吃光、返回空串。
    """

    def __init__(self, base, key):
        self.base, self.key = base.rstrip("/"), key
        self.lock = threading.Lock()
        self.calls = self.in_tokens = self.out_tokens = 0

    def chat(self, model, messages, max_tokens):
        body = {"model": model, "messages": messages, "max_tokens": max_tokens,
                "temperature": 0.0, "stream": True,
                "stream_options": {"include_usage": True}}
        if model.startswith("qwen"):
            body["enable_thinking"] = False
        last = None
        for attempt in range(4):
            got, usage = [], {}
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
                txt = ""
                reader = getattr(ex, "read", None)
                if reader:
                    try:
                        txt = reader()[:300].decode("utf-8", "replace")
                    except Exception:
                        txt = ""
                last = f"{type(ex).__name__} {getattr(ex, 'code', '')} {txt or ex}"
                if getattr(ex, "code", None) in (400, 401, 403, 404) and "data_inspection" not in txt:
                    raise RuntimeError(last)      # 密钥/模型名/参数错，重试没意义
                time.sleep(2 ** attempt)
        raise RuntimeError(last)


def snap_cuts(path, cuts, args, dur=None):
    """把切点吸到真正的气口上；返回 (新切口, 说明一句)。

    字幕句边界是 ASR 给的，只有 ±0.5s 的精度，照它直接切会被验收的 H1（切点必须落在
    停顿里）卡住——实测 34 刀里有 6 刀不合格。这里复用第一遍那套静音探测
    （adcheck.silence_mids + snap），并且不对称地限定挪动范围：向广告那一侧最远可以
    多吃 --snap-into（宁可留半秒广告尾），向正文那一侧最远只许让 --snap-out，
    绝不能因为吸附而啃掉正文。找不到气口就保持原样。
    """
    try:
        f = AC.acoustics(AC.decode(path))
    except Exception as ex:
        return cuts, [f"解码失败，切点未吸附：{str(ex)[:70]}"]
    gaps = AC.silence_mids(f, min_gap=0.15)
    dur = dur or len(f["t"]) and float(f["t"][-1]) or 0.0
    out, moved, miss = [], 0, 0
    for a, b in cuts:
        na, nb = AC.snap(gaps, a, a - args.snap_out, a + args.snap_into), \
            AC.snap(gaps, b, b - args.snap_into, b + args.snap_out)
        if abs(na - a) > 0.02:
            moved += 1
        if abs(nb - b) > 0.02:
            moved += 1
        miss += (na == a and abs(a) > 0.05) + (nb == b)
        na, nb = max(0.0, min(na, dur)), max(0.0, min(nb, dur))
        if nb - na >= args.min_cut:
            out.append([round(na, 2), round(nb, 2)])
    out.sort()
    merged = []
    for a, b in out:                     # 吸附后可能贴上或互相包含
        if merged and a - merged[-1][1] <= 0.4:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return merged, [f"气口吸附：{moved} 个切点挪位、{len(cuts) - len(merged)} 刀并刀"
                    + (f"，{miss} 个切点附近无停顿（保持原样）" if miss else "")]


def anchor(obj, lines, want, lo=0, hi=None):
    """把模型给的行号钉到真实行上。

    模型回的行号有 0 基/1 基两种写法，还会整批错一行（实测踩过：错一行就会把上一行的
    判定安到下一行正文上，广告漏掉、正文被切）。所以用模型自己回显的「该行开头几个字」
    在候选行里核对，对不上就在这行的邻域里找，都对不上就丢掉这条判定。
    """
    if hi is None:
        hi = len(lines) - 1
    t = re.sub(r"[\s，。、！？；：\"'（）《》…—·]+", "", str(obj.get("t") or ""))[:8]
    cands = [want, want - 1, want + 1, want - 2, want + 2]
    for k in cands:
        if not (lo <= k <= hi):
            continue
        body = re.sub(r"[\s，。、！？；：\"'（）《》…—·]+", "", lines[k][2])
        if not t:
            return k if k == want else None       # 没回显文本就只信原序号
        if body.startswith(t) or t in body[:12]:
            return k
    return None


def stem(chap):
    """章节键去掉 .mp3 后缀，提示词里更好读（也避开 f-string 里不能写反斜杠的老问题）。"""
    return chap[:-4] if chap.endswith(".mp3") else chap


def verdicts(text):
    """抓出模型给的 {i,v[,k]} 列表，并把序号统一成 0 基。

    模型有时一行一个对象、有时整个回成数组，序号 0 基 1 基都见过（实测踩过：按 1 基解
    会把每个判定错开一行），所以按「这批里出现过 0」判定为 0 基。
    """
    got = []
    for mo in re.finditer(r"\{[^{}]*\}", text or ""):
        try:
            o = json.loads(mo.group(0))
        except Exception:
            continue
        if isinstance(o.get("i"), int):
            got.append(o)
    if not got:
        return {}
    base = 0 if any(o["i"] == 0 for o in got) else 1
    return {o["i"] - base: o for o in got}


def chapter_list(books):
    """待扫章节：[(书名, 章节键, [(起, 止, 文本)])]，章节键带 .mp3。"""
    out = []
    for p in sorted(os.listdir(TR)):
        if not p.endswith(".json"):
            continue
        book = p[:-5]
        if books and book not in books:
            continue
        for name, lines in json.load(open(os.path.join(TR, p))).get("chapters", {}).items():
            if len(lines) >= 8:
                out.append((book, name, [(s[0], s[1], s[2]) for s in lines]))
    return out


def label_window(llm, args, book, chap, lines, start, stop, depth=0):
    """一个窗口的语义标注；被内容审查拦下就对半拆小重试（整章不能因一窗失败而丢掉）。"""
    rng = range(max(0, start - args.context), stop)
    body = "\n".join(f"{i + 1}\t[{lines[i][0]:.0f}-{lines[i][1]:.0f}s] {lines[i][2]}" for i in rng)
    prompt = (f"书名《{book}》，本章《{stem(chap)}》。\n" + LABEL_RULES +
              f"\n\n连续字幕行（行号\\t[起-止秒]内容），行号 {start + 1} 及之后是待判行，"
              f"之前的只作上下文：\n{body}\n")
    try:
        raw = llm.chat(args.model, [{"role": "system", "content": LABEL_SYS},
                                    {"role": "user", "content": prompt}], args.max_tokens)
    except Exception as ex:
        if "data_inspection" not in str(ex) or stop - start <= 8 or depth > 4:
            raise
        mid = (start + stop) // 2
        out = label_window(llm, args, book, chap, lines, start, mid, depth + 1)
        out.update(label_window(llm, args, book, chap, lines, mid, stop, depth + 1))
        stats["审查拆窗"] += 1
        return out
    out = {}
    for i, o in verdicts(raw).items():
        if o.get("k") not in CATS:
            continue
        k = anchor(o, lines, i, start, stop - 1)
        if k is None:
            stats["标注锚定失败"] += 1     # 序号与文本对不上，这条判定丢掉
            continue
        out[k] = o["k"]
    return out


def review_lines(llm, args, book, chap, lines, cand):
    """逐行复核：换一个不同源的模型，带上下文只判 >>> 那一行是广告还是正文。返回 {行号: 0|1|2}。"""
    res, B = {}, 10
    items = sorted(cand)
    for s in range(0, len(items), B):
        batch = items[s:s + B]
        blocks = []
        for i in batch:
            lo, hi = max(0, i - args.context), min(len(lines), i + args.context + 1)
            blk = "\n".join((">>>" if j == i else "   ") + f" [{j}] {lines[j][2]}"
                             for j in range(lo, hi))
            blocks.append(f"【{len(blocks) + 1}】《{book[:12]}·{stem(chap)[:18]}》\n{blk}")
        try:
            raw = llm.chat(args.judge, [{"role": "system", "content": LABEL_SYS + "\n\n" + REVIEW_RULES},
                                        {"role": "user", "content": "\n\n".join(blocks)}],
                           args.max_tokens)
        except Exception:
            raw = ""            # 复核拿不到结果就当没通过，宁可不切
        v = verdicts(raw)
        for n, i in enumerate(batch):
            o = v.get(n)
            if not o or not isinstance(o.get("v"), int):
                continue
            lo, hi = max(0, i - args.context), min(len(lines) - 1, i + args.context)
            k = anchor(o, lines, i, lo, hi)
            if k == i:
                res[i] = o["v"]
            else:
                stats["复核锚定失败"] += 1      # 序号与文本对不上，宁可不切这一行
    return res


def merge_groups(kept, lines, args):
    """把复核通过的广告行并成切口：允许中间夹几句短弱行，否则一句广告会留半句。"""
    groups, cur = [], []
    for i in kept:
        if not cur:
            cur = [i]
            continue
        gap = list(range(cur[-1] + 1, i))
        if not gap:
            cur.append(i)
        elif len(gap) <= args.merge_gap and all(len(lines[j][2]) <= args.weak_len for j in gap):
            cur.append(i)
        else:
            groups.append(cur)
            cur = [i]
    if cur:
        groups.append(cur)
    return groups


def bounds(lines, g, dur):
    """切口起止：只往字幕已记录的空白里扩（最多 0.25s），绝不吃掉相邻正文的时间。"""
    # 先钳进音频实际长度：whisper 在尾部会漂（实测 588 章最后一行超出音频时长，最多 +30s），
    # 不钳就会写出「切到 721s」而文件只有 698s 的切口，账面上的切除时长比实际多一大截
    a, b = min(lines[g[0]][0], dur), min(lines[g[-1]][1], dur)
    prev_end = lines[g[0] - 1][1] if g[0] > 0 else 0.0
    next_start = lines[g[-1] + 1][0] if g[-1] + 1 < len(lines) else dur
    a = max(prev_end, a - min(0.25, max(0.0, (a - prev_end) / 2)))
    b = min(next_start, b + min(0.25, max(0.0, (next_start - b) / 2)))
    if g[0] == 0:
        a = 0.0                     # 片头直接切到 0
    if g[-1] == len(lines) - 1:
        b = dur                     # 片尾切到结尾
    return round(a, 2), round(b, 2)


def seam_check(llm, args, book, chap, lines, cuts):
    """S6 缝合复核：候选切口左右各 3 行，两个独立模型都认可「切掉的是广告」才留这一刀。"""
    jobs = []
    for (a, b), cats in cuts:
        first = next((k for k in range(len(lines)) if lines[k][0] >= a), len(lines))
        after = next((k for k in range(len(lines)) if lines[k][0] >= b), len(lines))
        left, right = lines[max(0, first - SEAM_LINES):first], lines[after:after + SEAM_LINES]
        jobs.append({"cut": (a, b), "cats": cats, "votes": {},
                     "ctx": (left, right) if left and right else None})
    need = [j for j in jobs if j["ctx"]]
    for model in (args.seam_judge, args.seam_judge2):
        for s in range(0, len(need), 8):
            batch = need[s:s + 8]
            body = "\n\n".join(
                f"【{n + 1}】《{book[:12]}·{stem(chap)[:18]}》切口 "
                f"{j['cut'][1] - j['cut'][0]:.0f}s\n"
                f"切口前：{' / '.join(t[2] for t in j['ctx'][0])}\n"
                f"切口后：{' / '.join(t[2] for t in j['ctx'][1])}" for n, j in enumerate(batch))
            try:
                raw = llm.chat(model, [{"role": "system", "content": SEAM_SYS},
                                       {"role": "user", "content": SEAM_RULES + "\n\n" + body}],
                               max(args.max_tokens, 600 * len(batch)))
            except Exception:
                raw = ""
            v = verdicts(raw)
            for n, j in enumerate(batch):
                o = v.get(n)
                if not o or not isinstance(o.get("v"), int):
                    continue
                first = j["ctx"][1][0][2]
                t = re.sub(r"[\s，。、！？；：\"'（）《》…—·]+", "", str(o.get("t") or ""))[:8]
                body = re.sub(r"[\s，。、！？；：\"'（）《》…—·]+", "", first)
                if not t or body.startswith(t) or t in body[:12]:
                    j["votes"][model] = o
                else:
                    stats["缝合锚定失败"] += 1
    out = []
    for j in jobs:
        a, b = j["cut"]
        if j["ctx"] is None:
            out.append((a, b, j["cats"], "片头/片尾刀没有左右对照", True))
            continue
        vs = [(j["votes"].get(m) or {}).get("v") for m in (args.seam_judge, args.seam_judge2)]
        if not any(x is not None for x in vs):
            out.append((a, b, j["cats"], "缝合模型没给判定", args.keep_unjudged))
            continue
        if 1 in vs or 2 in vs:
            why = next(((j["votes"].get(m) or {}).get("why", "") for m in
                        (args.seam_judge, args.seam_judge2)
                        if (j["votes"].get(m) or {}).get("v") in (1, 2)), "")
            out.append((a, b, j["cats"], f"缝合判正文/引文 {vs} {why}"[:120], False))
        else:
            out.append((a, b, j["cats"], f"缝合通过 {vs}", True))
    return out


_CANNED = {}       # 书名 → {12 字滑窗: 出现过的章数}
_WIN = 12


def canned_index(book):
    """本书「同一句话出现在第几章」的索引。

    广告是罐头：同一段宣传词会在几十章里逐字重现；正文不会。第一遍的 adcheck-refine
    就是靠这个判中间插播，但它只留了 73 条记录，覆盖不到这一遍新找的刀，
    所以这里按缓存分段自己算一遍。
    """
    if book in _CANNED:
        return _CANNED[book]
    idx = {}
    d = os.path.join(AC.ROOT, "tools", "adcheck-cache")
    try:
        names = sorted(os.listdir(os.path.join(TR, book + ".json"))) and None
    except Exception:
        names = None
    chapters = sorted(json.load(open(os.path.join(TR, book + ".json"), encoding="utf-8"))["chapters"])
    for chap in chapters:
        rel = f"TestBooks/{book}/{chap}"
        txt = norm_txt("".join(t["t"] for t in AC.load_cache_segments(rel)))
        seen = set()
        for i in range(0, max(0, len(txt) - _WIN + 1)):
            g = txt[i:i + _WIN]
            if len(g) == _WIN:
                seen.add(g)
        for g in seen:
            idx[g] = idx.get(g, 0) + 1
    _CANNED[book] = idx
    return idx


def norm_txt(t):
    return re.sub(r"\W", "", t or "", flags=re.UNICODE)


def is_canned(book, txt, args):
    """这段文本是不是罐头宣传：有连续 _WIN 字在本书另外至少 --canned-in 章里逐字出现过。"""
    t = norm_txt(txt)
    if len(t) < _WIN:
        return False
    idx = canned_index(book)
    hit = sum(1 for i in range(0, len(t) - _WIN + 1)
              if idx.get(t[i:i + _WIN], 0) >= args.canned_in)
    return hit >= max(2, (len(t) - _WIN + 1) // 4)


def cache_evidence(rel, a, b, args):
    """用第一遍那份更细的 whisper-small 分段，独立看一眼这一刀切掉的是什么。

    大模型读的字幕出自 whisper-large，它会把十几秒音频塌成一行——实测「《静雅思听》
    让智慧也动听」占了 13.4 秒，而缓存里那 13 秒全是正文「就是不管你干得好不好 /
    你一直在干才是好员工 / 在日本加班是正常现象」。照大字幕的边界下刀就连正文一起切了。
    adcheck 的缓存是 2 秒粒度，正好当旁证：
      True  = 区间内几乎没人说话（音乐底）或文案命中广告/信息卡特征 → 这刀能切
      False = 区间内是成句文本又不含广告特征 → 不能切
      None  = 没有缓存可参照（让调用方退回用时间可信度判断）
    """
    segs = AC.load_cache_segments(rel)
    if not segs:
        return None, "无缓存旁证"
    inside = [t for t in segs if t["e"] > a + 0.2 and t["b"] < b - 0.2]
    txt = "".join(t["t"] for t in inside)
    n = len(re.sub(r"\W", "", txt, flags=re.UNICODE))
    if n < args.min_body:
        return True, f"区间内几乎无人说话（{n} 字）"
    if AD_RE.search(txt) or CARD_RE.search(txt):
        return True, "缓存文案命中广告/信息卡特征"
    if is_canned(rel.split("/")[1], txt, args):
        return True, "罐头文案在本书多章逐字重现"
    return False, f"区间内是成句文本（{n} 字，无广告特征、未跨章重现）"


def untrustworthy(line, args):
    """这一行的起止时间能不能信。

    whisper 会把一大段音频塌成一行：实测「《静雅思听》 让智慧也动听」占了 13.4 秒，
    而那 13 秒里其实还有 9 秒正文。照这种行的边界下刀就会连正文一起切掉（第一遍验收
    把这类刀标成「无内容证据」拦下了）。中文朗读正常 4~6 字/秒，低于阈值就是塌行。
    """
    span = line[1] - line[0]
    if span > args.max_span:
        return True
    n = len(re.sub(r"\W", "", line[2], flags=re.UNICODE))
    return span > args.rate_min_span and n / span < args.min_rate


def cut_text(lines, a, b):
    """切口覆盖到的字幕原文（进报告用，长句截断）。"""
    return " ".join(l[2] for l in lines if l[0] >= a - 0.01 and l[1] <= b + 0.01)[:120]


def scan_chapter(llm, args, book, chap, lines):
    """一章走完整流程：标注 → 逐行复核 → 并刀 → 硬闸门 → 缝合复核。返回 (清单行, 报告行)。"""
    try:
        dur = probe_len(os.path.join(LIB, book, chap)) or lines[-1][1]
    except Exception:
        dur = lines[-1][1]
    rel = f"TestBooks/{book}/{chap}"

    def row_of(cuts, evidence, review=False):
        cut_sec = round(sum(b - a for a, b in cuts), 1)
        mid = sum(1 for a, b in cuts if a > args.head_tail and b < dur - args.head_tail)
        return {"file": rel, "dur": round(dur, 2), "cuts": cuts, "cut_sec": cut_sec,
                "cut_pct": round(100 * cut_sec / max(1.0, dur), 2), "evidence": evidence,
                "needs_review": review, "asr": RULES_VER, "nseg": len(lines), "mid_cuts": mid}

    # 同一章可以扫多遍并取并集：单遍标注有波动（实测 12 章两遍并集比单遍多约两成切口），
    # 第二遍把窗口错开半个 win，避免同一处边界反复漏标
    cats_by_line = {}
    for p in range(args.passes):
        off = (args.win // 2) * p
        for s in range(off, len(lines), args.win):
            stop = min(len(lines), s + args.win)
            if s >= stop:
                continue
            cats_by_line.update(label_window(llm, args, book, chap, lines, s, stop))
    rep = []
    if not cats_by_line:
        return row_of([], ["语义普查未发现残留广告"]), rep

    rv = review_lines(llm, args, book, chap, lines, sorted(cats_by_line))
    kept = sorted(i for i, k in cats_by_line.items()
                  if rv.get(i) == 0 or (rv.get(i) == 2 and k in STRONG))
    for i in sorted(set(cats_by_line) - set(kept)):
        rep.append([book, chap, "", "", cats_by_line[i], lines[i][2][:60],
                    f"逐行复核判 {rv.get(i, '未判')}", "退回"])
    if not kept:
        return row_of([], [f"标注 {len(cats_by_line)} 行，逐行复核全否（保守起见不动文件）"]), rep

    cand, sus_span = [], []
    for g in merge_groups(kept, lines, args):
        a, b = bounds(lines, g, dur)
        # 单句字幕跨度超过上限 = ASR 把一大段音频塌成了一句（常发生在配乐/口播段），
        # 它的起止时间不可信，拿它下刀可能一下吃掉一分多钟正文，只能退回人工/声学复核
        bad = [i for i in g if untrustworthy(lines[i], args)]
        if bad:
            sus_span.append((a, b, sorted({cats_by_line[i] for i in g if i in cats_by_line}),
                             f"行时长不可信（{len(bad)} 句语速低于 {args.min_rate} 字/秒或跨度 >{args.max_span:.0f}s）"))
            continue
        if b - a >= args.min_cut:
            cand.append(((a, b), sorted({cats_by_line[i] for i in g if i in cats_by_line})))
    if not cand:
        return row_of([], [f"复核通过 {len(kept)} 行，但切口都短于 {args.min_cut}s"]), rep

    # 硬闸门：单章新增切除比例上限（先保长的刀）；纯信息卡只认片头片尾
    budget = dur * args.max_pct / 100.0
    cand.sort(key=lambda x: -(x[0][1] - x[0][0]))
    gated, over, total = [], [], 0.0
    for (a, b), cats in cand:
        head_tail = a <= args.head_tail or b >= dur - args.head_tail
        if all(c == "card" for c in cats) and not head_tail:
            over.append((a, b, cats, "纯信息卡但不在片头片尾"))
            continue
        if total + (b - a) > budget:
            over.append((a, b, cats, f"超单章 {args.max_pct}% 上限"))
            continue
        total += b - a
        gated.append(((a, b), cats))

    cuts, back = [], []
    for a, b, cats, why, ok in seam_check(llm, args, book, chap, lines, gated):
        if ok and "没有左右对照" in why:
            # 片头片尾的刀没有两侧正文可比，风险最高：要求它要么由多句组成，
            # 要么命中第一遍的词表特征（品牌、电商、作者/朗读者），否则不敢只凭一句话下刀
            inside = [l for l in lines if l[0] >= a - 0.01 and l[1] <= b + 0.01]
            txt = " ".join(t[2] for t in inside)
            if len(inside) < 2 and not (AD_RE.search(txt) or CARD_RE.search(txt)):
                ok, why = False, "无左右对照且证据单薄（单句、词表未命中）"
        if ok:
            rep.append([book, chap, f"{a:.1f}-{b:.1f}", round(b - a, 1), ",".join(cats),
                        cut_text(lines, a, b), why, "采纳"])
            cuts.append([a, b])
        else:
            back.append((a, b, cats, why))
    for a, b, cats, why in sus_span + over + back:
        rep.append([book, chap, f"{a:.1f}-{b:.1f}", round(b - a, 1), ",".join(cats),
                    cut_text(lines, a, b), why, "退回"])
    cuts.sort()
    if cuts and not args.no_snap:
        cuts, snap_note = snap_cuts(os.path.join(LIB, book, chap), cuts, args)
    else:
        snap_note = []
    ev = [f"标注 {len(cats_by_line)} 行 → 复核通过 {len(kept)} 行 → 候选 {len(cand)} 刀"
          f" → 采纳 {len(cuts)} 刀，退回 {len(over) + len(back)} 刀",
          "；".join(f"{a:.0f}-{b:.0f}s[{','.join(c)}]{w}" for a, b, c, w in over + back)[:280] or "无退回",
          "旁证：" + "；".join(weak)[:200] if weak else "无旁证"] + snap_note
    mixed = any(len(t[2]) > args.mixed_len and not (AD_RE.search(t[2]) or CARD_RE.search(t[2]))
                for a, b in cuts
                for t in lines if a <= t[0] and t[1] <= b)
    review = bool(sus_span) or mixed or any("超单章" in w for *_, w in over + back) or \
        any(b - a > args.head_max for a, b, *_ in cuts) or \
        (dur and sum(b - a for a, b in cuts) / dur > args.max_pct / 100.0 * 1.5)
    return row_of(cuts, [e for e in ev if e], bool(review)), rep


def load_done(path):
    """已扫过的章：{file: 清单行}。--union 时旧行会被并进新结果。"""
    done = {}
    if not os.path.exists(path):
        return done
    for line in open(path, encoding="utf-8"):
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("asr") == RULES_VER:
            done[r["file"]] = r
    return done


def compact_plan(path):
    """按 file 去重重写清单（后写的行覆盖先写的），保证 adcut-apply 一章只处理一次。"""
    rows = []
    if not os.path.exists(path):
        return
    for line in open(path, encoding="utf-8"):
        try:
            r = json.loads(line)
        except Exception:
            continue
        rows.append(r)
    last = {}
    for r in rows:
        last[r["file"]] = r
    tmp = path + f".{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for r in rows:
            if last[r["file"]] is r:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)
    print(f"清单去重：{len(rows)} 行 → {len(last)} 章")


def union_cuts(old, new, min_gap=1.0):
    """两批切口取并集并合并相邻/重叠的刀。"""
    segs = sorted([tuple(c) for c in list(old) + list(new)])
    out = []
    for a, b in segs:
        if out and a - out[-1][1] <= min_gap:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return [[round(x, 2), round(y, 2)] for x, y in out]


def main():
    ap = argparse.ArgumentParser(description="用云端大模型读整章字幕，找第一遍漏掉的广告")
    ap.add_argument("--book", action="append", help="书名（可重复）")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--limit", type=int, help="只扫前 N 章（试跑用）")
    ap.add_argument("--only", help="只扫这个文件里列出的章（一行一个 TestBooks/书/章.mp3），"
                                   "用来针对被闸门挡掉的章放宽参数补扫")
    ap.add_argument("--model", default="qwen3.8-max", help="标注模型")
    ap.add_argument("--judge", default="deepseek-v4-pro", help="逐行复核模型（与标注不同源）")
    ap.add_argument("--seam-judge", default="glm-5.2", help="缝合复核模型 A")
    ap.add_argument("--seam-judge2", default="deepseek-v4-pro", help="缝合复核模型 B")
    ap.add_argument("--win", type=int, default=80, help="一次送模型多少行")
    ap.add_argument("--passes", type=int, default=1,
                    help="同一章扫几遍取并集（单遍标注有波动，正式全库跑建议 2）")
    ap.add_argument("--context", type=int, default=4, help="标注与复核各带几行上下文")
    ap.add_argument("--max-tokens", type=int, default=4000)
    ap.add_argument("--workers", type=int, default=5, help="并发章数（纯 IO，不占内存）")
    ap.add_argument("--min-cut", type=float, default=2.0, help="短于此秒数不值得动文件")
    ap.add_argument("--max-pct", type=float, default=8.0, help="单章新增切除比例上限（百分比）")
    ap.add_argument("--head-tail", type=float, default=45.0, help="多长算片头/片尾")
    ap.add_argument("--max-span", type=float, default=20.0,
                    help="单句字幕跨度超过此秒数视为时间不可信，只标记不下刀")
    ap.add_argument("--canned-in", type=int, default=3,
                    help="连续 12 字在本书另外几章逐字重现就算罐头宣传（12 字窗口）")
    ap.add_argument("--min-body", type=int, default=12,
                    help="切区里缓存文本超过此字数且无广告特征，就判它切到了正文")
    ap.add_argument("--min-rate", type=float, default=2.2,
                    help="低于此字/秒算 whisper 塌行（正常中文朗读 4~6 字/秒），该行不下刀")
    ap.add_argument("--rate-min-span", type=float, default=5.0,
                    help="跨度超过此秒数才做语速检查（短句本来语速就低）")
    ap.add_argument("--mixed-len", type=int, default=24,
                    help="刀内出现长于此字数又不含广告特征的句子，就标 needs_review（疑似混进正文）")
    ap.add_argument("--head-max", type=float, default=60.0,
                    help="单刀超过此秒数就标 needs_review（正常广告口播没这么长）")
    ap.add_argument("--merge-gap", type=int, default=1, help="允许跨几句弱行把广告并成一把")
    ap.add_argument("--weak-len", type=int, default=10, help="不超过此字数算弱句")
    ap.add_argument("--keep-unjudged", action="store_true", help="缝合没判成的刀也保留（默认退回）")
    ap.add_argument("--snap-into", type=float, default=1.2,
                    help="切点向广告那一侧最多挪这么多秒去找气口")
    ap.add_argument("--snap-out", type=float, default=0.3,
                    help="切点向正文那一侧最多挪这么多秒（再远就是啃正文）")
    ap.add_argument("--no-snap", action="store_true", help="不做气口吸附（调试用）")
    ap.add_argument("--snap", action="store_true",
                    help="只给已有清单补做气口吸附（不重扫、不调模型）")
    ap.add_argument("--regrade", action="store_true",
                    help="对已有清单逐刀补做缓存旁证复核（第一遍那份更细的分段），"
                         "切到正文的刀摘掉；不调模型")
    ap.add_argument("--recheck", action="store_true",
                    help="用当前判据复核已有清单，把塌行造成的刀摘掉（不调模型）")
    ap.add_argument("--emit", action="store_true", help="写 tools/adcuts-llm.jsonl 与报告")
    ap.add_argument("--overwrite", action="store_true", help="已扫过的章重扫（丢弃旧结果）")
    ap.add_argument("--union", action="store_true",
                    help="已扫过的章再扫一遍，切口与旧结果取并集（标注有波动，多跑几遍只增不减）")
    ap.add_argument("--prompt", action="store_true", help="只打印第一章的提示词，不调模型")
    args = ap.parse_args()

    if not (args.all or args.book or args.snap or args.only):
        ap.error("需要 --all / --book 书名 / --only 章清单 / --snap（补吸附）之一")
    key = T.api_key()
    if not key:
        sys.exit("没找到密钥：export DASHSCOPE_API_KEY=sk-...，或写进 ~/.config/sonux/llm-key")
    llm = LLM(API_BASE, key)

    if args.regrade:
        want = None
        if args.only:
            want = {ln.strip() for ln in open(args.only, encoding="utf-8") if ln.strip()}
        rows, kept, dropped, secs = [], 0, 0, 0.0
        for line in open(PLAN_OUT, encoding="utf-8"):
            r = json.loads(line)
            if r.get("cuts") and (want is None or r["file"] in want):
                book, chap = r["file"].split("/")[1], r["file"].split("/")[2]
                keep = []
                for a, b in r["cuts"]:
                    ok, why = cache_evidence(r["file"], a, b, args)
                    if ok is None:
                        # 没有缓存旁证时退回时间可信度判断：区间里只要有塌行就不切
                        try:
                            ch = json.load(open(os.path.join(TR, book + ".json")))["chapters"]
                            lines = ch.get(chap) or ch.get(chap[:-4]) or []
                        except Exception:
                            lines = []
                        inside = [l for l in lines if l[0] >= a - 0.05 and l[1] <= b + 0.05]
                        if inside and any(untrustworthy(l, args) for l in inside):
                            dropped += 1
                            secs += b - a
                            continue
                    kept += 1
                    keep.append([a, b])
                r["cuts"] = keep
                sec = round(sum(b - a for a, b in keep), 1)
                r["cut_sec"], r["cut_pct"] = sec, round(100 * sec / max(1.0, r.get("dur") or 1), 2)
            rows.append(r)
        tmp = PLAN_OUT + f".{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        os.replace(tmp, PLAN_OUT)
        print(f"旁证复核：留 {kept} 刀，摘 {dropped} 刀（{secs/60:.1f} 分钟判为切到正文或时间不可信）；"
              f"清单现在 {sum(len(r['cuts']) for r in rows)} 刀 / "
              f"{sum(r['cut_sec'] for r in rows)/3600:.2f} 小时")
        return

    if args.recheck:
        # 清单是早先用旧判据扫的：按现在的「语速/跨度」判据把不可信的刀摘掉，
        # 不重新调模型（省一半时间），也保证清单与闸门规则一致
        want = None
        if args.only:
            want = {ln.strip() for ln in open(args.only, encoding="utf-8") if ln.strip()}
        rows, dropped, secs = [], 0, 0.0
        for line in open(PLAN_OUT, encoding="utf-8"):
            r = json.loads(line)
            keep_cuts = list(r.get("cuts") or [])
            if keep_cuts and (want is None or r["file"] in want):
                book, chap = r["file"].split("/")[1], r["file"].split("/")[2]
                try:
                    ch = json.load(open(os.path.join(TR, book + ".json")))["chapters"]
                    lines = ch.get(chap) or ch.get(chap[:-4]) or []
                except Exception:
                    lines = []
                if lines:
                    keep_cuts = []
                    for a, b in r["cuts"]:
                        inside = [l for l in lines if l[0] >= a - 0.05 and l[1] <= b + 0.05]
                        if inside and any(untrustworthy(l, args) for l in inside):
                            dropped += 1
                            secs += b - a
                            continue
                        keep_cuts.append([a, b])
                r["cuts"] = keep_cuts
                sec = round(sum(b - a for a, b in keep_cuts), 1)
                r["cut_sec"] = sec
                r["cut_pct"] = round(100 * sec / max(1.0, r.get("dur") or 1), 2)
                r["asr"] = RULES_VER      # 判据变了，标记成新版本，避免被旧结果误用
            rows.append(r)
        tmp = PLAN_OUT + f".{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        os.replace(tmp, PLAN_OUT)
        print(f"复核清单：摘掉 {dropped} 刀（共 {secs/60:.1f} 分钟时间不可信的刀），"
              f"现在 {sum(len(r['cuts']) for r in rows)} 刀 / "
              f"{sum(r['cut_sec'] for r in rows)/3600:.2f} 小时")
        return

    if args.snap:
        want = None
        if args.only:
            want = {ln.strip() for ln in open(args.only, encoding="utf-8") if ln.strip()}
        rows, moved_rows = [], 0
        for line in open(PLAN_OUT, encoding="utf-8"):
            r = json.loads(line)
            # 已经 promote 的章绝不能再吸附：清单一动，就和落盘的音频不一致，将来会切第二遍
            if not r.get("cuts") or (want is not None and r["file"] not in want) or \
                    (args.book and r["file"].split("/")[1] not in args.book):
                rows.append(r)
                continue
            new, note = snap_cuts(os.path.join(ROOT, r["file"]), r["cuts"], args, r.get("dur"))
            sec = round(sum(b - a for a, b in new), 1)
            if [list(map(float, c)) for c in new] != [list(map(float, c)) for c in r["cuts"]]:
                moved_rows += 1
                r.update({"cuts": new, "cut_sec": sec,
                          "cut_pct": round(100 * sec / max(1.0, r["dur"]), 2),
                          "evidence": list(r.get("evidence") or []) + note})
            rows.append(r)
        tmp = PLAN_OUT + f".{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        os.replace(tmp, PLAN_OUT)
        n = sum(len(r["cuts"]) for r in rows)
        print(f"补吸附完成：{moved_rows} 章的切口被挪动/合并，清单现有切口 {n} 个，"
              f"合计 {sum(r['cut_sec'] for r in rows)/3600:.2f} 小时")
        return

    chaps = chapter_list([] if args.all else args.book)
    if args.only:
        want = {ln.strip() for ln in open(args.only, encoding="utf-8") if ln.strip()}
        chaps = [x for x in chaps if f"TestBooks/{x[0]}/{x[1]}" in want]
        print(f"--only 限定 {len(want)} 章，命中 {len(chaps)} 章", flush=True)
    done = load_done(PLAN_OUT)
    todo = [(b, c, l) for b, c, l in chaps
            if args.overwrite or args.union or f"TestBooks/{b}/{c}" not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f"共 {len(chaps)} 章，待扫 {len(todo)} 章；标注 {args.model}，复核 {args.judge}，"
          f"缝合 {args.seam_judge}+{args.seam_judge2}", flush=True)
    if args.prompt:
        if not todo:
            sys.exit("没有可打印的章")
        b, c, l = todo[0]
        body = "\n".join(f"{i + 1}\t[{l[i][0]:.0f}-{l[i][1]:.0f}s] {l[i][2]}"
                         for i in range(min(args.win, len(l))))
        print("---- 标注提示词（第一章）----\n", LABEL_SYS, "\n\n", LABEL_RULES,
              f"\n\n书名《{b}》，本章《{c}》。连续字幕行：\n{body}\n")
        return
    if not todo:
        print("没有待扫的章（清单里都已有；要重扫加 --overwrite）")
        return

    plan_fh = open(PLAN_OUT, "a", encoding="utf-8") if args.emit else None
    rep_fh = rep_wr = None
    if args.emit:
        new = not os.path.exists(REPORT)
        rep_fh = open(REPORT, "a", newline="", encoding="utf-8")
        rep_wr = csv.writer(rep_fh)
        if new:
            rep_wr.writerow(["书名", "章节", "切口", "秒", "类别", "被切文本", "复核意见", "结论"])
    lock, stat, t0, n = threading.Lock(), Counter(), time.time(), 0

    def one(item):
        return scan_chapter(llm, args, *item)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {pool.submit(one, it): it for it in todo}
        for fut in as_completed(futs):
            try:
                row, rep = fut.result()
            except Exception as ex:
                print(f"  失败 {futs[fut][0][:12]}|{futs[fut][1][:20]} {str(ex)[:110]}", flush=True)
                stat["失败"] += 1
                continue
            n += 1
            if args.union and row["file"] in done:
                prev = done[row["file"]]
                merged = union_cuts(prev.get("cuts") or [], row["cuts"])
                sec = round(sum(b - a for a, b in merged), 1)
                row.update({"cuts": merged, "cut_sec": sec,
                            "cut_pct": round(100 * sec / max(1.0, row["dur"]), 2),
                            "needs_review": bool(prev.get("needs_review")) or row["needs_review"],
                            "evidence": row["evidence"] +
                            [f"与上一轮并集：原 {len(prev.get('cuts') or [])} 刀 → 并后 {len(merged)} 刀"]})
            with lock:
                if plan_fh:
                    plan_fh.write(json.dumps(row, ensure_ascii=False) + "\n")
                    plan_fh.flush()
                if rep_wr and rep:
                    rep_wr.writerows(rep)
                    rep_fh.flush()
            stat["刀"] += len(row["cuts"])
            stat["秒"] += row["cut_sec"]
            stat["有残留的章"] += 1 if row["cuts"] else 0
            el = time.time() - t0
            print(f"  {n}/{len(todo)} {row['file'][-40:]:42s} 新增 {len(row['cuts']):2d} 刀 "
                  f"{row['cut_sec']:6.1f}s ({row['cut_pct']:4.1f}%) 已用 {el/60:.1f} 分 "
                  f"还剩约 {el/n*(len(todo)-n)/60:.0f} 分", flush=True)
    for fh in (plan_fh, rep_fh):
        if fh:
            fh.close()
    if args.emit:
        compact_plan(PLAN_OUT)        # --union 会追加重复行，收尾按 file 保留最后一条
    print(f"\n完成 {n} 章，用时 {(time.time()-t0)/60:.1f} 分；调用 {llm.calls} 次，"
          f"输入 {llm.in_tokens/1e6:.2f}M / 输出 {llm.out_tokens/1e6:.2f}M token")
    print(f"新增 {stat['刀']} 刀、共 {stat['秒']/60:.1f} 分钟；仍检出残留广告的章 "
          f"{stat['有残留的章']}/{n or 1}；失败 {stat['失败']}")
    if stats:
        print("过程计数：" + "、".join(f"{k} {v}" for k, v in stats.most_common()))
    if args.emit:
        print(f"清单 → {PLAN_OUT}\n报告 → {REPORT}\n下一步："
              "python3 tools/adcut-apply.py --plan tools/adcuts-llm.jsonl --book 书名 --apply")
    else:
        print("（未加 --emit，清单与报告没落盘）")


if __name__ == "__main__":
    main()
