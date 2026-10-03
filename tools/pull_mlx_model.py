#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性把 MLX 版 whisper 大模型按分块并行拉到 tools/models/ 下（可断点续传）。

为什么不用 huggingface_hub 直接下：这台机器的网络对 HF 的 CDN 连接会时不时被
中间设备掐断（httpx 报 EOF），单连接重试几次就整轮失败；而走本机代理虽然稳但只有
0.2MB/s。这里按 Range 把大文件切成若干块并行下，每块自己记进度、断了从当前字节
续上，够快也够皮实。下完后 tools/transcribe.py 会优先用这个本地目录（离线可用）。
"""

import os
import sys
import threading
import time
import urllib.request

REPO = "mlx-community/whisper-large-v3-turbo"
BASE = f"https://huggingface.co/{REPO}/resolve/main"
OUT = "/Users/kiwenlau/Desktop/sonux/tools/models/whisper-large-v3-turbo"
FILES = ["config.json", "README.md", ".gitattributes", "weights.safetensors"]
CHUNKS = 6
PROXY = None            # 直连更快；要换本机代理就填 "http://127.0.0.1:7993"


def opener():
    if PROXY:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"https": PROXY, "http": PROXY}))
    return urllib.request.build_opener()


def size_of(name):
    req = urllib.request.Request(f"{BASE}/{name}", method="HEAD")
    return int(opener().open(req, timeout=30).headers["Content-Length"])


def fetch_range(name, start, end, part):
    """下 [start, end) 这一段到 part 文件；每次重连都从已下到的位置接着走。"""
    have = os.path.getsize(part) if os.path.exists(part) else 0
    pos = start + have
    with open(part, "ab") as fh:
        while pos <= end:
            req = urllib.request.Request(f"{BASE}/{name}",
                                         headers={"Range": f"bytes={pos}-{end}"})
            try:
                with opener().open(req, timeout=60) as r:
                    while True:
                        b = r.read(1 << 20)
                        if not b:
                            break
                        fh.write(b)
                        fh.flush()
                        pos += len(b)
            except Exception as ex:
                print(f"  {name} {pos - start}/{end - start} 断了（{type(ex).__name__}），续传",
                      flush=True)
                time.sleep(2)
    return pos - start


def get_file(name, total=None):
    dest = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if total is None:
        total = size_of(name)
    if os.path.exists(dest) and os.path.getsize(dest) == total:
        print(f"{name}: 已存在 {total/1e6:.1f} MB")
        return
    if total < 8 << 20:                      # 小文件没必要切
        with opener().open(f"{BASE}/{name}", timeout=60) as r, open(dest + ".part", "wb") as fh:
            fh.write(r.read())
        os.replace(dest + ".part", dest)
        print(f"{name}: {total/1e6:.1f} MB")
        return
    span = total // CHUNKS
    parts = []
    threads = []
    for i in range(CHUNKS):
        start = i * span
        end = total - 1 if i == CHUNKS - 1 else (i + 1) * span - 1
        part = f"{dest}.{i}.part"
        parts.append(part)
        t = threading.Thread(target=fetch_range, args=(name, start, end, part), daemon=True)
        t.start()
        threads.append(t)
    t0, prev = time.time(), 0
    while any(t.is_alive() for t in threads):
        time.sleep(15)
        now = sum(os.path.getsize(p) if os.path.exists(p) else 0 for p in parts)
        print(f"  {name}: {now/1e6:.0f}/{total/1e6:.0f} MB  "
              f"{(now-prev)/15/1e6:.2f} MB/s", flush=True)
        prev = now
    for t in threads:
        t.join()
    with open(dest, "wb") as out:
        for p in parts:
            with open(p, "rb") as fh:
                while True:
                    b = fh.read(1 << 20)
                    if not b:
                        break
                    out.write(b)
            os.remove(p)
    got = os.path.getsize(dest)
    print(f"{name}: {got/1e6:.1f} MB（应为 {total/1e6:.1f} MB）{'✓' if got == total else '✗ 大小不对'}")
    if got != total:
        sys.exit(1)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in FILES:
        get_file(name)
    print("→", OUT)


if __name__ == "__main__":
    main()
