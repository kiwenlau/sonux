#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""找出台呼、口播广告、片尾宣传曲与章节信息卡这些「非正文」区间，输出可剪辑清单。

三路信号交叉判定，单一信号不足以动手：
1. 声纹离群——正文是同一人稳定录音；广告多是另一个声音、还垫着音乐。
   按 6 秒滑窗取浊音帧的 MFCC/音高/平坦度，与该章正文主声纹算稳健距离（MAD 归一）。
2. ASR 文案——整篇转写，命中台呼口号、光盘/网站/公众号等关键词即判广告；
   命中「作者/译者/朗读者」或本章书名章节名即判信息卡（只认片头位置的）。
3. 静音缝隙——切点吸附到最近停顿的中点，避免切掉半个字。

判定粒度是「区间」：先找出正文句，再看正文句之间的空隙是否同时满足
「声纹覆盖率 / 广告关键词 / 音乐特征」中的强证据，才列为待切除。宁可漏切，不可误删正文。

用法：
    python3 tools/adcheck.py --book 大败局                 # 跑一本书
    python3 tools/adcheck.py --all --jobs 6                # 全库（自动跳过已完成的章）
    python3 tools/adcheck.py --files a.mp3 b.mp3           # 指定文件
    python3 tools/adcheck.py --report                      # 汇总已有结果
    python3 tools/adcheck.py --no-asr --book 大败局         # 只出声学（快，精度低）

结果：tools/adcheck.jsonl，每章一行（file/dur/cuts/cut_sec/evidence/needs_review）。
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import unicodedata

# 限制 BLAS/Accelerate 线程：否则每个子进程的 FFT 会吃满全部核，把 whisper 挤垮
for _v in ("OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "2")

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_JSONL = os.path.join(ROOT, "tools", "adcheck.jsonl")
CACHE_DIR = os.path.join(ROOT, "tools", "adcheck-cache")
MODEL_DIR = os.environ.get("SONUX_WHISPER_MODEL",
                           os.path.join(ROOT, "tools", "models", "whisper-small"))
SR = 16000
FLEN, FSTEP, NFFT, NFILT, NMEL = 400, 160, 512, 40, 20
HEAD_WINDOW = 200.0      # 片头信息卡/台呼最多看到这么远
TAIL_WINDOW = 260.0      # 片尾广告最多这么长
MAX_CUT_RATIO = 0.25     # 单章切除比例护栏，超过只保留头尾并标记复核

# ---------------------------------------------------------------- ffmpeg


def ffmpeg_path():
    p = os.popen("command -v ffmpeg 2>/dev/null").read().strip()
    if p:
        return p
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


FF = ffmpeg_path()


def decode(path, start=None, dur=None):
    cmd = [FF, "-hide_banner", "-loglevel", "error"]
    if start:
        cmd += ["-ss", str(start)]
    if dur:
        cmd += ["-t", str(dur)]
    cmd += ["-i", path, "-vn", "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    if not raw:
        raise RuntimeError("ffmpeg 解码失败")
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


# ---------------------------------------------------------------- 声学特征


def _mel_bank():
    fr = np.linspace(0, SR / 2, NFILT + 2)
    hz = 700 * (10 ** (2595 * np.log10(1 + fr / 700) / 2595) - 1)
    bins = np.floor((NFFT + 1) * hz / SR).astype(int)
    w = np.zeros((NFILT, NFFT // 2 + 1))
    for i in range(NFILT):
        a, b, c = bins[i], bins[i + 1], bins[i + 2]
        if b > a:
            w[i, a:b + 1] = (np.arange(a, b + 1) - a) / (b - a)
        if c > b:
            w[i, b + 1:c + 1] = (c - np.arange(b + 1, c + 1)) / (c - b)
    return w


BANK = _mel_bank()
DCT = np.cos(np.pi * np.arange(NMEL)[:, None] * (np.arange(NFILT)[None, :] + 0.5) / NFILT)


def acoustics(x):
    """逐帧特征：时间轴、MFCC、响度 dB、音高、频谱平坦度。"""
    pad = np.pad(x, (0, FLEN))
    fr = np.lib.stride_tricks.sliding_window_view(pad, FLEN)[::FSTEP][: len(x) // FSTEP + 1]
    fr = fr * np.hanning(FLEN)
    t = (np.arange(len(fr)) * FSTEP + FLEN / 2) / SR
    mag2 = np.abs(np.fft.rfft(fr, n=NFFT)) ** 2
    mfcc = np.log(mag2.dot(BANK.T) + 1e-10).dot(DCT.T)
    db = 20 * np.log10(np.sqrt((fr ** 2).mean(axis=1)) + 1e-9)
    lo, hi = SR // 400, SR // 60
    f0 = np.zeros(len(fr))
    for s0 in range(0, len(fr), 4000):
        blk = fr[s0:s0 + 4000]
        zp = np.zeros((len(blk), 2 * NFFT))
        zp[:, :FLEN] = blk
        ac = np.fft.irfft(np.abs(np.fft.rfft(zp, axis=1)) ** 2, axis=1)[:, :FLEN]
        ac = ac / (ac[:, :1] + 1e-12)
        band = ac[:, lo:hi]
        f0[s0:s0 + len(blk)] = np.where(band.max(axis=1) > 0.35, SR / (band.argmax(axis=1) + lo), 0.0)
    flat = np.exp(np.log(mag2 + 1e-10).mean(axis=1)) / (mag2.mean(axis=1) + 1e-10)
    lvl = float(np.percentile(db[db > -60], 75)) if (db > -60).any() else -60.0
    return dict(t=t, mfcc=mfcc, db=db, f0=f0, flat=flat, n=len(x) / SR, lvl=lvl)


def voiced(f):
    return (f["f0"] > 0) & (f["db"] > -35)


def win_vec(f, a, b):
    """窗口声纹：浊音帧 MFCC 形状 + 音高 + 平坦度；浊音帧太少（纯音乐/静音）不评判。"""
    m = (f["t"] >= a) & (f["t"] < b)
    vo = m & voiced(f)
    if vo.sum() < 25:
        return None
    mf = f["mfcc"][vo]
    v = list(mf.mean(axis=0)[1:NMEL]) + list(mf.std(axis=0)[1:7])
    v.append(float(np.log2(np.median(f["f0"][vo]))))
    v.append(float(np.median(f["flat"][m])))
    return np.array(v)


def _kmeans2(X, w):
    c = [X[0].copy(), X[((X - X[0]) ** 2).sum(axis=1).argmax()].copy()]
    lab = np.zeros(len(X), dtype=int)
    for _ in range(25):
        new = np.stack([((X - c[k]) ** 2).sum(axis=1) for k in range(2)], axis=1).argmin(axis=1)
        for k in range(2):
            m = new == k
            if m.any():
                c[k] = (X[m] * w[m, None]).sum(axis=0) / (w[m].sum() + 1e-9)
        if (new == lab).all():
            break
        lab = new
    return lab, c


def foreign_regions(f, win=6.0, thr=2.6, min_hits=2):
    """声纹离群区：与本章正文主声纹距离过大的连续滑窗，合并成区间。"""
    dur = f["n"]
    B, V = [], []
    for a in np.arange(0.0, max(dur - win, 1.0), win):
        b = min(a + win * 2, dur)
        v = win_vec(f, a, b)
        if v is not None:
            B.append((float(a), float(b)))
            V.append(v)
    if len(V) < 10:
        return []
    X = np.array(V)
    mu = np.median(X, axis=0)
    mad = np.median(np.abs(X - mu), axis=0) * 1.4826 + 1e-6
    Z = np.clip((X - mu) / mad, -6, 6)
    lab, cents = _kmeans2(Z, np.array([b - a for a, b in B]))
    body = int(np.bincount(lab, weights=np.array([b - a for a, b in B])).argmax())
    away = np.sqrt(((Z - cents[body]) ** 2).sum(axis=1) / Z.shape[1])
    out = []
    for k in range(len(B)):
        if away[k] <= thr:
            continue
        a, b = B[k]
        if out and a - out[-1][1] <= win * 2.5:
            out[-1][1] = max(out[-1][1], b)
            out[-1][2] += 1
            out[-1][3] = max(out[-1][3], float(away[k]))
        else:
            out.append([a, b, 1, float(away[k])])
    return [(a, b, n, aw) for a, b, n, aw in out if n >= min_hits]


def silence_mids(f, min_gap=0.35, thresh=None):
    """可下刀的静音中点；不传阈值则按全篇响度自动取（比正文轻 10dB 以上）。"""
    if thresh is None:
        thresh = (f.get("lvl", -20.0) - 10.0) if isinstance(f.get("lvl", None), float) else -38.0
    act = f["db"] > thresh
    out, i = [], 0
    while i < len(act):
        if act[i]:
            i += 1
            continue
        j = i
        while j < len(act) and not act[j]:
            j += 1
        if f["t"][min(j - 1, len(act) - 1)] - f["t"][i] >= min_gap:
            out.append(float((f["t"][i] + f["t"][min(j - 1, len(act) - 1)]) / 2))
        i = j
    return out


def snap(gaps, x, lo, hi):
    cand = [g for g in gaps if lo <= g <= hi]
    return min(cand, key=lambda g: abs(g - x)) if cand else x


def music_like(f, a, b):
    """音乐/歌唱：能量不低但浊音规律差，或频谱很平（有器乐底）。"""
    if f is None:
        return False
    m = (f["t"] >= a) & (f["t"] < b)
    if m.sum() < 30 or (m & (f["db"] > -35)).sum() < 20:
        return False
    return float(voiced(f)[m].mean()) < 0.32 or float(np.median(f["flat"][m])) > 0.05


def coverage(regions, a, b):
    """[a,b] 落在声纹离群区里的比例。"""
    if b <= a:
        return 0.0
    tot = sum(max(0.0, min(b, r1) - max(a, r0)) for r0, r1, _, _ in regions)
    return min(1.0, tot / (b - a))


# ---------------------------------------------------------------- 文案判定

# ASR 对台呼口号识别很不稳定，关键词一律带错别字变体
AD_RE = re.compile("|".join([
    r"[静靖靜淨敬竟][雅衙][思斯][听聽厅廳廷婷]",
    r"[静靖靜淨敬竟][雅衙]斯[听聽厅廳]",
    r"雅斯听|雅思听|雅斯聽|雅思聽",
    r"(精彩|精華|精华).{0,6}(即刻|立即|马上).{0,6}(送到|送达|收听|呈現|呈现)",
    r"(登陸|登陆|登录|鎖定|锁定|打開|打开).{0,8}(雅|斯|廳|厅|網|网)",
    r"(让|讓).{0,2}(智慧|知慧).{0,10}(動聽|动听|聲音|声音|聆聽|聆听)",
    r"想聽就來|想听就来|想聽請到|更多精彩|更多好書|更多好书",
    r"(光盤|光盘|磁帶|磁带|光碟|書生系|书生系)",
    r"(公眾號|公众号|小程序|二维码|二維碼|掃碼|扫码)",
    r"(微信|微博).{0,8}(號|号|公眾|公众|关注|關注|添加|扫一扫|掃一掃|私信|留言)",
    r"(官網|官网|官方).{0,8}(網|网|w\s*w|com|net)",
    r"(網址|网址|域名)",
    r"(訪問|访问).{0,6}(網|网)",
    r"(贊助|赞助|冠名|貼片|贴片)",
    r"(插播|播出|感謝|感谢).{0,8}(廣告|广告)",
    r"(淘寶|淘宝).{0,10}(店|官方|下單|下单|連結|链接)",
    r"(京東|京东|噹噹|当当).{0,10}(店|官方|下單|下单)",
    r"喜马拉雅|樊登|懒人听书|懶人聽書|得到app|得到客戶端|得到客户端|得到听书|得到聽書",
    r"(版權所有|版权所有|侵權|侵权|未經許可|未经许可|轉載|转载)",
    r"(录製|录制|製作|制作).{0,8}(團隊|团队|工作室|公司)",
    r"(字幕|子幕).{0,3}(by|BY|由)",
    r"(本台|本站).{0,6}(推荐|推薦|播出|首發|首发)",
    r"(今日推薦|今日推荐|本期推薦|本期推荐)",
]))
CARD_RE = re.compile(
    r"(作者|作着|譯者|译者|翻澤|翻译|朗读者|朗読者|演播|播講|播讲|主播|旁白|"
    r"解説|解说|原書|原书|原著|第[一二三四五六七八九十百零\d]+[章节章])")


def norm(s):
    s = unicodedata.normalize("NFKC", s)
    return re.sub(r"[^\w]+", "", s, flags=re.UNICODE).casefold()


def chapter_keys(book_dir, filename):
    """本书书名 + 本章节名（取自文件名），用于识别片头信息卡。"""
    stem = re.sub(r"[（(]\s*\d+\s*[)）]$", "", os.path.splitext(filename)[0])
    stem = re.sub(r"^\s*\d+\s*[.、_\-]\s*", "", stem)
    return [k for k in (norm(book_dir), norm(stem)) if len(k) >= 3]


def nchars(txt):
    return len(re.sub(r"\W", "", txt, flags=re.UNICODE))


def label_segments(segs, f, foreign, keys):
    """给每个 ASR 句段打标签 body / ad / card / music，并记录判定理由。"""
    out = []
    for s in segs:
        txt, a, b = s["t"], s["b"], s["e"]
        cov = coverage(foreign, a, b)
        n = nchars(txt)
        lab, why = "body", []
        if AD_RE.search(txt):
            lab = "ad"
            why.append("文案命中台呼/广告关键词")
        elif cov >= 0.5 and n >= 4:
            lab = "ad"
            why.append(f"声纹离群（覆盖 {cov:.0%}）")
        elif n <= 2 and music_like(f, a, b):
            lab = "music"
            why.append("纯音乐/歌唱")
        if lab == "body" and b <= HEAD_WINDOW and (CARD_RE.search(txt) or chapter_hit(txt, keys)):
            lab = "card"
            hit = chapter_hit(txt, keys)
            if hit and CARD_RE.search(txt):
                why.append("信息卡（书名+角色词）")
            elif hit:
                why.append("信息卡含书名/章节名")
            else:
                why.append("信息卡关键词（作者/译者/朗读者）")
        out.append(dict(a=a, b=b, t=txt, lab=lab, cov=round(cov, 2), why=why, nchar=n,
                        db=round(seg_db(f, a, b), 1)))
    return out


def seg_db(f, a, b):
    """该区间的说话电平（有声帧的高分位）；广告口播/歌曲往往比正文轻 8dB 以上。"""
    m = (f["t"] >= a) & (f["t"] < b) & (f["db"] > -50)
    return float(np.percentile(f["db"][m], 90)) if m.sum() > 5 else -99.0


def chapter_hit(txt, keys):
    t = norm(txt)
    return any(k in t for k in keys)


# ---------------------------------------------------------------- 切点规划


def _evidence(labels, foreign, a, b, strong_only):
    """区间 [a,b] 切除证据；证据不足返回 []。strong_only 用于正文中间插播。"""
    inside = [s for s in labels if s["b"] > a + 0.2 and s["a"] < b - 0.2]
    tagged = [s for s in inside if s["lab"] != "body" and s["why"]]
    ad_txt = [s for s in tagged if s["lab"] in ("ad", "music")]
    cov = coverage(foreign, a, b)
    long_body = [s for s in inside if s["lab"] == "body" and s["nchar"] >= 14]
    if long_body and cov < 0.8:
        return []            # 区间里有一句像样的正文，不敢切
    if strong_only:
        # 正文中间：必须有真正的广告句（关键词或声纹离群且够长），或者整段无文字的音乐
        real_ad = [s for s in ad_txt if s["lab"] == "ad" and s["nchar"] >= 4]
        ok = bool(real_ad) or (not inside and cov >= 0.6)
    else:
        ok = bool(ad_txt) or bool(tagged) or cov >= 0.5 or not inside
    if not ok:
        return []
    notes = [f"{s['a']:.1f}-{s['b']:.1f}s [{'/'.join(s['why'])}] {s['t'][:40]}" for s in tagged[:6]]
    if cov >= 0.5:
        notes.append(f"声纹离群覆盖 {cov:.0%}")
    if not inside:
        notes.append("该区间 ASR 无文字（纯音乐）")
    return notes


def _established(labels, i, back=False, refdb=-99.0):
    """正文是否「站稳」：本句与相邻（前/后）句都是像样正文、间隔很近、响度接近正文水平。"""
    if labels[i]["lab"] != "body" or labels[i]["nchar"] < 8 or labels[i]["db"] <= refdb - 8:
        return False
    rng = range(max(i - 2, 0), i) if back else range(i + 1, min(i + 3, len(labels)))
    for k in rng:
        if labels[k]["lab"] != "body" or labels[k]["nchar"] < 8 or labels[k]["db"] <= refdb - 8:
            continue
        gap = (labels[i]["a"] - labels[k]["b"]) if back else (labels[k]["a"] - labels[i]["b"])
        if gap < 8:
            return True
    return False


def card_anchor(labels, limit):
    """找可用的片头信息卡锚点。

    真卡片是「书名 / 章节 / 作者 X / 朗读者 Y」这种短句报目，跨度小；
    正文里一句带「作者……」的长句不能当锚点（实测会误删特别长一段正文）。
    """
    for i, s in enumerate(labels):
        if s["lab"] != "card" or s["a"] > min(limit, 120.0) or s["nchar"] > 20:
            continue
        run = [s]
        k = i + 1
        while k < len(labels) and labels[k]["lab"] == "card" \
                and labels[k]["a"] - run[-1]["b"] < 6 and labels[k]["nchar"] <= 20:
            run.append(labels[k])
            k += 1
        span = max(x["b"] for x in run) - s["a"]
        strong = (len(run) >= 2 and span <= 45) or any("书名+角色词" in w for w in s["why"])
        if strong:
            return (s["a"], i, max(x["b"] for x in run), s["t"])
    return None


def edge_cut(labels, foreign, gaps, dur, side, limit, keep_card, f):
    """从文件边缘往正文走，返回应切除的片头/片尾区间。

    一直走到「正文站稳」才停；途中被 ASR 当成正文的短句（片尾那首歌）不会提前终止。
    区间的证据（广告句/信息卡/声纹离群）覆盖率不足则不切。
    """
    order = range(len(labels)) if side == "head" else range(len(labels) - 1, -1, -1)
    stop = None
    if side == "head":
        # 静雅思听的结构是「台呼/口播广告 → 信息卡 → 正文」，找到信息卡就当锚点：
        # 卡前面的一切都是片头（卡片本身按 keep_card 决定是否一并切除）
        anchor = card_anchor(labels, limit)
        if anchor is not None:
            b = None
            for i in range(anchor[1], len(labels)):
                if _established(labels, i, refdb=f.get("refdb", -99.0)):
                    b = labels[i]["a"]
                    break
            if b is None:
                b = anchor[2]
            if keep_card:
                b = min(b, anchor[0])
            if 4 <= b <= min(limit, 150.0):
                ev = [f"片头 {0:.0f}-{b:.0f}s（信息卡锚点：{anchor[3][:36]}）"]
                ev += [f"{s['a']:.1f}-{s['b']:.1f}s [{'/'.join(s['why'])}] {s['t'][:40]}"
                       for s in labels if s["a"] < b and s["why"]][:4]
                return (0.0, snap(gaps, b - 0.3, 0, limit)), ev
    for i in order:
        s = labels[i]
        tagged = s["lab"] in ("ad", "music", "card")
        if side == "head":
            if tagged:
                stop = max(stop or 0.0, s["b"])            # 切到最后一句广告/信息卡的结尾
            elif _established(labels, i, refdb=f.get("refdb", -99.0)):
                stop = max(stop or 0.0, s["a"])            # 或切到站稳的正文开头
                break
            # 未站稳的正文句（可能是被当成正文的歌词）不终止扫描
        else:
            if tagged:
                stop = min(stop if stop is not None else dur, s["a"])
            elif _established(labels, i, back=True, refdb=f.get("refdb", -99.0)):
                stop = min(stop if stop is not None else s["b"], s["b"])
                break
    if stop is None:
        return None, []
    a, b = (0.0, stop) if side == "head" else (stop, dur)
    if side == "tail":
        # 片尾保守：先排除夹在里面的「长、且声纹不离群」正文句，
        # 再把切点放到「最后正文」与「第一句广告」之间的那道停顿里
        conv = [s for s in labels if s["a"] >= stop - 0.01 and s["lab"] == "body"
                and s["nchar"] >= 8 and s["cov"] < 0.3 and s["db"] > f.get("refdb", -99.0) - 8]
        if conv:
            last_body = max(s["b"] for s in conv)
            tags = [s["a"] for s in labels if s["lab"] in ("ad", "music", "card") and s["a"] >= last_body]
            first_ad = min(tags) if tags else dur
            stop = snap(gaps, (last_body + first_ad) / 2, last_body, max(last_body, first_ad)) \
                if first_ad > last_body else last_body
            a, b = stop, dur
    if keep_card and side == "head":
        cards = [s for s in labels if s["lab"] == "card" and s["a"] < stop]
        if cards:
            b = min(b, cards[0]["a"])
    if not (4 <= b - a <= limit):
        return None, []
    # 证据覆盖率：被 tagged 句或声纹离群区盖住的比例
    tagged = sum(max(0.0, min(b, s["b"]) - max(a, s["a"]))
                 for s in labels if s["lab"] != "body" and s["why"])
    cov = max(tagged / (b - a), coverage(foreign, a, b))
    ins = [s for s in labels if a <= s["a"] < b]
    kw_or_card = any(s["lab"] == "card" or any("关键词" in w for w in s["why"]) for s in ins)
    # 片头里有广告口播/信息卡即认定存在片头（静雅思听的文件开头都是台呼+口播）
    if not (cov >= 0.5 or (side == "head" and kw_or_card and b <= 150)):
        return None, []
    at = b if side == "head" else a
    edge = snap(gaps, at + (-0.3 if side == "head" else 0.3), max(0.0, at - 12), min(dur, at + 12))
    ev = [f"{'片头' if side == 'head' else '片尾'} {a:.0f}-{b:.0f}s 证据覆盖 {cov:.0%}"]
    ev += [f"{s['a']:.1f}-{s['b']:.1f}s [{'/'.join(s['why'])}] {s['t'][:40]}"
           for s in labels if a <= s["a"] < b and s["why"]][:5]
    return (a, edge) if side == "head" else (edge, b), ev


def plan_cuts(dur, labels, foreign, gaps, f, drop_card=True):
    """产出待切除区间（含头尾与中间插播）与证据说明。"""
    body = [i for i, s in enumerate(labels) if s["lab"] == "body" and s["nchar"] >= 8]
    cand = []                                   # (kind, start, end, evidence)
    # 片头 / 片尾：从边缘往正文走，直到正文站稳
    for side, limit in (("head", HEAD_WINDOW), ("tail", TAIL_WINDOW)):
        got, ev = edge_cut(labels, foreign, gaps, dur, side, limit,
                           keep_card=not drop_card, f=f)
        if got:
            cand.append((side, round(got[0], 2), round(got[1], 2), ev))
    # 正文中间：相邻正文句之间的空隙
    for i in range(1, len(body)):
        lo, hi = labels[body[i - 1]]["b"], labels[body[i]]["a"]
        if not (6 <= hi - lo <= 240):
            continue
        if any(lo < e and s < hi for _, s, e, _ in cand):
            continue                      # 已被片头/片尾区间盖住
        ev = _evidence(labels, foreign, lo, hi, strong_only=True)
        if ev:
            cand.append(("mid", snap(gaps, lo, max(0, lo - 8), lo + 8),
                         snap(gaps, hi, hi - 8, min(dur, hi + 8)), ev))
    # 护栏：总切除比例超阈值时先丢中间切口，并标记需人工复核
    def total(items):
        return sum(min(e, dur) - s for _, s, e, _ in items)

    mid = [c for c in cand if c[0] == "mid"]
    keep = [c for c in cand if c[0] != "mid"]
    dropped = 0
    for c in mid:
        if (total(keep) + c[2] - c[1]) / max(dur, 1) <= MAX_CUT_RATIO:
            keep.append(c)
        else:
            dropped += 1
    review = dropped > 0 or total(keep) / max(dur, 1) > MAX_CUT_RATIO

    merged, notes = [], []
    for kind, s, e, ev in sorted(keep, key=lambda c: c[1]):
        s, e = max(0.0, s - 0.25), min(dur, e + 0.25)
        if e - s < 1.0:
            continue
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
            notes[-1].extend(ev)
        else:
            merged.append([s, e])
            notes.append(list(ev))
    cuts = [[round(s, 2), round(e, 2)] for s, e in merged]
    flat = [f"[{s:.0f}-{e:.0f}] {n}" for (s, e), evs in zip(cuts, notes) for n in evs[:5]]
    return cuts, flat, bool(review)


# ---------------------------------------------------------------- 单章分析


def analyze(path, use_asr=True, transcribe=None):
    book_dir = os.path.basename(os.path.dirname(path))
    x = decode(path)
    dur = len(x) / SR
    f = acoustics(x)
    foreign = foreign_regions(f)
    gaps = silence_mids(f, min_gap=0.15)
    segs = []
    if use_asr and transcribe:
        cache = cache_path(path)
        if os.path.exists(cache):
            segs = json.load(open(cache))
        else:
            segs, covered = transcribe(x, dur, foreign)
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(cache, "w") as fh:
                json.dump(segs, fh, ensure_ascii=False)
    labels = label_segments(segs, f, foreign, chapter_keys(book_dir, os.path.basename(path)))
    # 自校准响度参考：拿本章正文句的说话电平中位数，不拿全篇分位数（静音会带偏）
    ref = [s["db"] for s in labels if s["lab"] == "body" and s["nchar"] >= 8]
    f["refdb"] = float(np.median(ref)) if ref else -99.0
    cuts, notes, review = plan_cuts(dur, labels, foreign, gaps, f)
    cut = round(sum(e - s for s, e in cuts), 1)
    return dict(file=os.path.relpath(path, ROOT), dur=round(dur, 1), cuts=cuts,
                cut_sec=cut, cut_pct=round(100 * cut / max(dur, 1), 1),
                foreign=[[round(a, 1), round(b, 1), n, round(aw, 1)] for a, b, n, aw in foreign],
                evidence=notes, needs_review=bool(review), asr=bool(segs),
                nseg=len(labels), nbody=sum(1 for s in labels if s["lab"] == "body"),
                mid_cuts=sum(1 for s, e in cuts if s > 25 and e < dur - 25))


# ---------------------------------------------------------------- 批量运行

_MODEL = None
FULL_ASR = False


def init_worker():
    global _MODEL
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    from faster_whisper import WhisperModel
    _MODEL = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8",
                          cpu_threads=int(os.environ.get("AD_THREADS", "2")))


def cache_path(path):
    """ASR 结果缓存：调规则时不用重跑转写。

    键里带上文件字节数：换掉（切除后）的文件会自动失效重转，不会拿着旧时间轴做判断。
    """
    p = path if os.path.isabs(path) else os.path.join(ROOT, path)
    rel = os.path.relpath(p, ROOT)
    try:
        size = os.stat(p).st_size
    except OSError:
        size = 0
    key = hashlib.sha1(f"{rel}:{size}".encode("utf-8")).hexdigest()[:16]
    return os.path.join(CACHE_DIR, key + ".json")


def load_cache_segments(path):
    """读已缓存的转写结果（没缓存返回空列表），统一成 {b,e,t}。"""
    p = cache_path(path)
    if not os.path.exists(p):
        return []
    try:
        segs = json.load(open(p))
    except Exception:
        return []
    for s in segs:
        s.setdefault("b", s.get("start", 0.0))
        s.setdefault("e", s.get("end", 0.0))
    return [s for s in segs if s.get("t")]


def keep_ranges(dur, cuts, min_piece=0.8):
    """切掉 cuts 后剩下的区间；太短的碎片直接丢。

    切除工具与验收工具共用这一份实现，否则两边算出的「应有时长」会不一致。
    """
    out, pos = [], 0.0
    for s, e in sorted(cuts):
        s, e = max(0.0, s), min(dur, e)
        if s > pos + 0.05:
            out.append((pos, s))
        pos = max(pos, e)
    if dur > pos + 0.05:
        out.append((pos, dur))
    return [(s, e) for s, e in out if e - s >= min_piece]


def probe_len(path):
    """容器声明的时长（不解码，给边界钳位用）。"""
    err = subprocess.run([FF, "-hide_banner", "-i", path], capture_output=True).stderr.decode()
    for line in err.split("\n"):
        if "Duration:" in line:
            h, m, s = line.split("Duration:")[1].split(",")[0].strip().split(":")
            return int(h) * 3600 + int(m) * 60 + float(s)
    return 0.0


def asr_pcm(path, x):
    """把 PCM 写成临时 wav 再转写（临时文件名带 pid，避免并行互相覆盖）。"""
    wav = os.path.join(tempfile.gettempdir(), f"adcheck-{os.getpid()}.wav")
    subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le",
                    "-ar", str(SR), "-ac", "1", "-i", "pipe:0", wav],
                   input=(x * 32767).astype(np.int16).tobytes(), capture_output=True)
    try:
        segs, _ = _MODEL.transcribe(wav, language="zh", beam_size=1, vad_filter=False,
                                    condition_on_previous_text=False)
        return [{"b": round(s.start, 1), "e": round(s.end, 1), "t": s.text.strip()} for s in segs]
    finally:
        if os.path.exists(wav):
            os.remove(wav)


HEAD_ASR, TAIL_ASR, PAD = 220.0, 320.0, 15.0


def asr_windows(x, dur, foreign, full=False):
    """只转写必要的窗口：片头、片尾、以及声纹离群区（含两侧余量）。

    全篇转写要 400 小时音频，CPU 上跑不完；而广告只出现在片头片尾与「异声」区。
    代价：正文中间那段广告若与正文同声同环境、又不在片头片尾，会漏掉（可事后 --full-asr 补）。
    """
    if full:
        return asr_pcm("", x), [(0.0, dur)]
    wins = [(0.0, min(HEAD_ASR, dur))]
    if dur > HEAD_ASR + TAIL_ASR:
        wins.append((dur - TAIL_ASR, dur))
    for a, b, _, _ in foreign:
        if a > HEAD_ASR - PAD and b < dur - TAIL_ASR + PAD:
            wins.append((max(0.0, a - PAD), min(dur, b + PAD)))
    wins = sorted(wins)
    merged = []
    for s, e in wins:
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    segs = []
    for s, e in merged:
        part = asr_pcm("", x[int(s * SR):int(e * SR)])
        segs += [{"b": round(p["b"] + s, 1), "e": round(p["e"] + s, 1), "t": p["t"]} for p in part]
    return sorted(segs, key=lambda p: p["b"]), [(s, e) for s, e in merged]


def job(path):
    try:
        return analyze(path, use_asr=_MODEL is not None,
                       transcribe=(lambda x, dur, fr: asr_windows(x, dur, fr, full=FULL_ASR))
                       if _MODEL is not None else None)
    except Exception as ex:                      # 单章失败不拖垮整轮
        return dict(file=os.path.relpath(path, ROOT), error=str(ex)[:200])


def _lsc(name):
    parts = re.split(r"(\d+)", unicodedata.normalize("NFKC", name).casefold())
    return [int(p) if p.isdigit() else p for p in parts]


def book_files(root, book=None):
    out = []
    for b in sorted(os.listdir(root)):
        d = os.path.join(root, b)
        if not os.path.isdir(d) or (book and book != b):
            continue
        for name in sorted(os.listdir(d), key=_lsc):
            if name.lower().endswith((".mp3", ".m4a", ".m4b", ".aac")):
                out.append(os.path.join(d, name))
    return out


def load_rows(out):
    rows = []
    if os.path.exists(out):
        for line in open(out):
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    return rows


def report(out=OUT_JSONL):
    rows = load_rows(out)
    ok = [r for r in rows if "cuts" in r]
    err = [r for r in rows if "error" in r]
    print(f"已分析 {len(ok)} 章，失败 {len(err)}")
    if not ok:
        return
    tot_cut = sum(r["cut_sec"] for r in ok)
    tot_dur = sum(r["dur"] for r in ok)
    nmid = sum(1 for r in ok if r["mid_cuts"])
    print(f"非正文合计 {tot_cut/3600:.1f}h / {tot_dur/3600:.1f}h = {100*tot_cut/tot_dur:.1f}%，"
          f"平均每章 {tot_cut/len(ok):.0f}s；正文中间有插播 {nmid} 章（{100*nmid/len(ok):.0f}%）；"
          f"需复核 {sum(r['needs_review'] for r in ok)} 章；ASR 空结果 "
          f"{sum(1 for r in ok if not r['asr'])} 章")
    by = {}
    for r in ok:
        d = by.setdefault(r["file"].split("/")[1], dict(n=0, cut=0.0, dur=0.0, mid=0, rev=0))
        d["n"] += 1
        d["cut"] += r["cut_sec"]
        d["dur"] += r["dur"]
        d["mid"] += r["mid_cuts"]
        d["rev"] += r["needs_review"]
    print("\n按书（每章平均切除秒数 / 中间插播处数 / 需复核章数）：")
    for b, d in sorted(by.items(), key=lambda kv: -kv[1]["cut"] / kv[1]["n"]):
        print(f"  {b[:26]:28s} {d['cut']/d['n']:5.0f}s  mid {d['mid']:4d}  复核 {d['rev']:3d}")
    if err:
        print("\n失败样本：")
        for r in err[:5]:
            print("  ", r["file"], r["error"])


def timeline(path):
    """逐句打印标签与证据（用 ASR 缓存，不重新转写），用于人工审阅。"""
    global FF
    p = path if os.path.isabs(path) else os.path.join(ROOT, path)
    x = decode(p)
    dur = len(x) / SR
    f = acoustics(x)
    foreign = foreign_regions(f)
    cache = cache_path(p)
    segs = json.load(open(cache)) if os.path.exists(cache) else []
    book_dir = os.path.basename(os.path.dirname(p))
    labels = label_segments(segs, f, foreign, chapter_keys(book_dir, os.path.basename(p)))
    ref = [s["db"] for s in labels if s["lab"] == "body" and s["nchar"] >= 8]
    f["refdb"] = float(np.median(ref)) if ref else -99.0
    cuts, notes, review = plan_cuts(dur, labels, foreign, silence_mids(f), f)
    print(f"# {os.path.relpath(p, ROOT)}  {dur:.0f}s  正文电平参考 {f['refdb']:.1f}dB")
    print("# 声纹离群区:", [[round(a), round(b)] for a, b, _, _ in foreign])
    print("# 切除区间:", cuts, "需复核" if review else "")
    for s in labels:
        mark = "  ❌" if s["lab"] != "body" else ""
        print(f"{s['a']:7.1f}-{s['b']:7.1f} {s['lab']:5s} n={s['nchar']:3d} "
              f"cov={s['cov']:.2f} db={s['db']:6.1f} {s['t'][:44]}{mark}")


def audit(out=OUT_JSONL, n=12):
    """列出最值得人工看的章：切最多 / 一剪未切 / 只有单信号的中间切口。"""
    rows = [r for r in load_rows(out) if "cuts" in r]
    if not rows:
        print("还没有结果")
        return
    print(f"共 {len(rows)} 章。\n\n【切除比例最高】")
    for r in sorted(rows, key=lambda r: -r["cut_pct"])[:n]:
        print(f"  {r['cut_pct']:5.1f}%  {r['file']}  {r['cuts']}")
    print("\n【完全没切（可能漏检）】")
    none = [r for r in rows if not r["cuts"]]
    print(f"  共 {len(none)} 章")
    for r in none[:n]:
        print(f"  {r['file']}  声纹离群 {len(r['foreign'])} 处  句数 {r['nseg']}")
    print("\n【需人工复核 / 中间切口】")
    mid = [r for r in rows if r["mid_cuts"] or r["needs_review"]]
    print(f"  共 {len(mid)} 章")
    for r in sorted(mid, key=lambda r: -r["mid_cuts"])[:n]:
        print(f"  {r['file']}  mid={r['mid_cuts']} 复核={r['needs_review']}")
        for e in r["evidence"]:
            try:
                at = float(e.split("]")[0].lstrip("[").split("-")[0])
            except ValueError:
                continue
            if 25 < at < r["dur"] - 25:
                print("      ", e[:120])


def main():
    global OUT_JSONL, FULL_ASR
    ap = argparse.ArgumentParser(description="定位有声书里的台呼/广告/信息卡区间")
    ap.add_argument("--root", default=os.path.join(ROOT, "TestBooks"))
    ap.add_argument("--book")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--no-asr", action="store_true")
    ap.add_argument("--full-asr", action="store_true",
                    help="整篇转写（慢得多；默认只转片头/片尾/声纹离群区）")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--audit", type=int, nargs="?", const=12, default=None, help="列出待人工看的样本")
    ap.add_argument("--timeline", help="逐句打印某章的判定过程（用缓存，不重跑 ASR）")
    ap.add_argument("--fresh", action="store_true", help="不跳过已分析的章")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--out", default=OUT_JSONL)
    args = ap.parse_args()
    OUT_JSONL = args.out
    FULL_ASR = args.full_asr

    if args.report:
        report(args.out)
        return
    if args.audit is not None:
        audit(args.out, args.audit)
        return
    if args.timeline:
        timeline(args.timeline)
        return
    if args.files:
        files = args.files
    elif args.book:
        files = book_files(args.root, args.book)
    elif args.all:
        files = book_files(args.root)
    else:
        ap.error("需要 --all / --book 书名 / --files 文件列表 / --report 之一")

    done = {r["file"] for r in load_rows(args.out) if "error" not in r}
    todo = [p for p in files if os.path.relpath(p, ROOT) not in done] if not args.fresh else files
    if args.limit:
        todo = todo[:args.limit]
    print(f"共 {len(files)} 章，跳过已分析 {len(files)-len(todo)}，本轮 {len(todo)} 章，"
          f"并行 {args.jobs}，ASR {'关' if args.no_asr else '开'}", flush=True)

    import multiprocessing as mp
    pool = mp.Pool(args.jobs) if args.no_asr else mp.Pool(args.jobs, initializer=init_worker)
    n = 0
    with open(args.out, "w" if args.fresh else "a") as fh:
        for r in pool.imap_unordered(job, todo, chunksize=1 if not args.no_asr else 4):
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
            fh.flush()
            n += 1
            if n % 20 == 0 or n == len(todo):
                print(f"  {n}/{len(todo)}", flush=True)
    pool.close()
    pool.join()
    print("→", args.out)
    report(args.out)


if __name__ == "__main__":
    main()
