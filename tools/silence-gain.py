#!/usr/bin/env python3
"""量一把「跳过静音」到底能省多少时间：拿全库字幕的空档算，不碰音频。

算法与 Services/SilenceGaps.swift 一字对齐（同一句收尾到下一句开口之间算空档，
两端各扣 0.25 s 保护，空档原长达到阈值才跳），所以这里得到的百分比就是 App 里的行为。

分母是音频真实时长（afinfo 量的），不是「最后一句的结束点」——章尾那段留白正是最该跳的，
拿台词跨度当分母会把收益算虚。

用法：python3 tools/silence-gain.py [--langs-cache .tmp-shots/durations.json]
"""
import json
import subprocess
import sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parent.parent
TRANSCRIPTS = ROOT / "transcripts"
CACHE = ROOT / ".tmp-shots" / "durations.json"
TAIL_LEAD = 0.25  # 与 SilenceGaps.tailSlack / leadSlack 一致
MODES = [("轻度", 1.0), ("标准", 1.8), ("重度", 3.0)]


def duration(path: Path) -> float:
    out = subprocess.run(["afinfo", str(path)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(":")
        if len(parts) == 2 and parts[0] in ("estimated duration", "duration"):
            return float(parts[1].split()[0])   # afinfo 报的就是秒
    return 0.0


def load_durations() -> dict[str, float]:
    """书库里每个音频文件的时长：缓存到 .tmp-shots/durations.json，重复跑就不再量"""
    files = sorted(p for p in (ROOT / "TestBooks").rglob("*")
                   if p.suffix.lower() in {".mp3", ".m4a", ".m4b", ".wav", ".aiff", ".aac"})
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    todo = [p for p in files if str(p.relative_to(ROOT)) not in cache]
    if todo:
        print(f"量 {len(todo)} 个文件时长（首次，之后走缓存）…", file=sys.stderr)
        with ThreadPoolExecutor(max_workers=8) as pool:
            for path, seconds in zip(todo, pool.map(duration, todo)):
                cache[str(path.relative_to(ROOT))] = seconds
        CACHE.parent.mkdir(exist_ok=True)
        CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=1), encoding="utf-8")
    return cache


def gaps_of(lines: list[tuple[float, float]], total: float) -> list[float]:
    """某章所有够长的空档（跳过去的实际秒数），按原始跨度返回，供各档位分别判阈值"""
    spans: list[float] = []
    if not lines or total <= 0:
        return spans
    # 章头：文件开头到第一句开口
    first = lines[0][0]
    if first - TAIL_LEAD > 0:
        spans.append(first)
    for prev, nxt in zip(lines, lines[1:]):
        span = nxt[0] - prev[1]      # 上一句收声到下一句开口
        if span > 0:
            spans.append(span)
    # 章尾：最后一句收声到本章结束
    last = lines[-1][1]
    if total - last - TAIL_LEAD > 0:
        spans.append(total - last)
    return spans


def main() -> None:
    # 时长表按（书名, 章文件名）索引：字幕包的键是章文件名，transcripts/<书名>.json 给书名
    durations = {(Path(key).parent.name if Path(key).parent.name != "TestBooks"
                  else Path(key).stem, Path(key).name): seconds
                 for key, seconds in load_durations().items()}
    per_mode = {name: 0.0 for name, _ in MODES}
    counts = {name: 0 for name, _ in MODES}
    audio_total = 0.0
    books: dict[str, dict[str, float]] = {}
    chapters = 0

    for tf in sorted(TRANSCRIPTS.glob("*.json")):
        data = json.loads(tf.read_text(encoding="utf-8"))
        book = tf.stem
        books[book] = {name: 0.0 for name, _ in MODES}
        books[book]["音频"] = 0.0
        for chapter_file, raw in data.get("chapters", {}).items():
            total = durations.get((book, chapter_file), 0.0)
            if total <= 0:
                continue          # 这本不在书库里（或已被改名），不计入
            lines = sorted([(x[0], x[1]) for x in raw if x[2] and x[1] > x[0]])
            if not lines:
                continue
            chapters += 1
            audio_total += total
            books[book]["音频"] += total
            for span in gaps_of(lines, total):
                for name, threshold in MODES:
                    if span >= threshold:
                        # 真跳过去的秒数 = 空档原长 - 两端保护留白
                        saved = span - 2 * TAIL_LEAD
                        if saved > 0:
                            per_mode[name] += saved
                            counts[name] += 1
                            books[book][name] += saved

    print(f"字幕覆盖 {chapters} 章，音频合计 {audio_total / 3600:.1f} 小时\n")
    if audio_total <= 0:
        sys.exit("书库与 transcripts 没对上，算不了")
    print(f"{'档位':<6}{'阈值':>6}{'可省时间':>10}{'占比':>8}{'跳过次数':>10}{'每小时':>8}")
    for name, threshold in MODES:
        saved = per_mode[name]
        jumps = counts[name]
        print(f"{name:<6}{threshold:>5.1f}s{saved / 3600:>8.1f} h{saved / audio_total * 100:>7.1f}%"
              f"{jumps:>9d}{jumps / (audio_total / 3600):>8.0f}")
    print("\n（每小时跳几次决定手感：几十次以上就会听出「一卡一卡」）")

    ratios = sorted((books[b][MODES[1][0]] / books[b]["音频"], b) for b in books
                    if books[b]["音频"] > 0)
    print("\n标准档下省得最少的三本：")
    for ratio, book in ratios[:3]:
        print(f"  {ratio * 100:>5.1f}%  {book}")
    print("标准档下省得最多的三本：")
    for ratio, book in ratios[-3:]:
        print(f"  {ratio * 100:>5.1f}%  {book}（{books[book]['音频'] / 3600:.1f} h）")


if __name__ == "__main__":
    main()
