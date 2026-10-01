#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测试书库元数据处理的公共逻辑：目录名解析、章节名规范、ID3 标签读写。

约定（与 App 端 LibraryService 保持一致）：
- 一本书 = TestBooks/ 下的一个文件夹，文件夹名即 App 显示的书名
- 作者、封面取自音频内嵌元数据（TPE1 / APIC）
- 章节顺序由文件名的 localizedStandardCompare 决定，这里改为显式编号，避免歧义
"""

import os
import re
import stat
import unicodedata
from urllib.parse import unquote

AUDIO_EXTS = {".mp3", ".m4a", ".m4b", ".aac", ".wav", ".wave"}

# 目录名格式：分类-作者[书名]节选-全N集-朗读者
FOLDER_RE = re.compile(
    r"^(?P<category>[^-]+?)-(?P<author>.+?)\[(?P<title>.+?)\](?P<abridged>节选-)?全?(?P<episodes>\d+)集-(?P<narrator>.+)$"
)


def parse_folder_name(name):
    """把「财经-渔阳[乱世华尔街]全29集-有益」解析成结构化字段；不符合格式返回 None。"""
    m = FOLDER_RE.match(name)
    if not m:
        return None
    return {
        "category": m.group("category").strip(),
        "author": m.group("author").strip(),
        "title": m.group("title").strip(),
        "abridged": bool(m.group("abridged")),
        "episodes": int(m.group("episodes")),
        "narrator": m.group("narrator").strip(),
    }


def audio_files(book_dir):
    """列出书目录下所有音频文件（不含隐藏项与子目录里的杂项）。"""
    try:
        entries = os.listdir(book_dir)
    except OSError:
        return []
    files = [
        e for e in entries
        if not e.startswith(".")
        and os.path.splitext(e)[1].lower() in AUDIO_EXTS
        and os.path.isfile(os.path.join(book_dir, e))
    ]
    return files


def localized_key(name):
    """近似 macOS 的 localizedStandardCompare：数字按数值比较、忽略大小写与全半角。"""
    norm = unicodedata.normalize("NFKC", name).casefold()
    parts = re.split(r"(\d+)", norm)
    key = []
    for p in parts:
        if p.isdigit():
            key.append((1, int(p), ""))
        elif p:
            key.append((0, 0, p))
    return key


# 章节名解析：文件名里可能同时出现「01.」「乱世华尔街01：」「袁氏当国1：…（2）」
# 「媒体的使命（01）：古典的报纸」等写法，同一本书还可能分成两个各自编号的系列，
# 所以排序键是（系列短语出现顺序, 主序号, 括号里的子序号, 原始顺序）。
DIGIT_RE = re.compile(r"\d{1,3}")
TAIL_NUM_RE = re.compile(r"^[（(【]?\s*(\d{1,3})\s*[）)】]?\s*[：:．\.、\-—]?\s*(.*)$")
PAREN_NUM_RE = re.compile(r"[（(]\s*(\d{1,3})\s*[）)]")
PHRASE_TAIL_JUNK = "（(【：:，,、-—_.．·/ 　"


def split_chapter_number(base):
    """拆出（系列短语, 主序号, 子序号, 解码后的完整名）。

    「民主的细节：序言（3）」→ ("民主的细节：序言", 3, None, 原名)
    「袁氏当国1：孙文创制（2）」→ ("袁氏当国", 1, 2, 原名)
    """
    text = unquote(base).replace("\u200b", "").strip()
    m = DIGIT_RE.search(text)
    if not m:
        return text.strip(PHRASE_TAIL_JUNK), None, None, text
    phrase = text[: m.start()].strip().strip(PHRASE_TAIL_JUNK)
    tail = text[m.start():]
    nm = TAIL_NUM_RE.match(tail)
    if not nm:
        return phrase, None, None, text
    main, rest = int(nm.group(1)), nm.group(2)
    pm = PAREN_NUM_RE.search(rest)
    sub = int(pm.group(1)) if pm else None
    return phrase, main, sub, text


def chapter_sort_key(name, idx):
    phrase, main, sub, _ = split_chapter_number(os.path.splitext(name)[0])
    return (phrase, main if main is not None else 10 ** 6, sub if sub is not None else 0, idx)


def display_title(text, title, strip_phrases):
    """从原始文件名得到简洁章节名：去书名/系列前缀、去编号、去【完】之类标记。"""
    t = unquote(text).replace("/", "\uFF0F")   # “%2F” 解码出的 / 不能进文件名，换视觉等价的全角斜杠
    if title and t.startswith(title):
        t = t[len(title):]
    for p in sorted(strip_phrases, key=len, reverse=True):
        if p and t.startswith(p):
            t = t[len(p):]
            break
    t = re.sub(r"^[（(【]?\s*\d{1,3}\s*[）)】]?\s*[：:．\.、\-—]?\s*", "", t)
    t = PAREN_NUM_RE.sub("", t)                      # （1）这种分集号
    t = re.sub(r"【[^】]*】", "", t)                   # 【完】【全集】
    t = t.replace("【", "").replace("】", "")
    t = t.strip(" ：:．.、-—_·")
    t = re.sub(r"\s{2,}", " ", t)
    return t.strip()


def chapter_display_number(index, total):
    return str(index).zfill(3 if total >= 100 else 2)


def plan_chapters(book_dir, title):
    """给一本书生成章节重命名计划：[(旧文件名, 新文件名, 章节标题, 序号)]。"""
    files = audio_files(book_dir)
    if not files:
        return []
    # 先按 localized 顺序编号，保证解析不出序号的文件不改变相对次序
    files = sorted(files, key=lambda n: localized_key(n))
    parsed = [split_chapter_number(os.path.splitext(n)[0]) for n in files]

    # 系列短语按其在书中的出现顺序编号，两个各自编号的系列不会互相穿插
    groups = []
    for phrase, *_ in parsed:
        if phrase not in groups:
            groups.append(phrase)
    order = sorted(range(len(files)), key=lambda i: (
        groups.index(parsed[i][0]),
        parsed[i][1] if parsed[i][1] is not None else 10 ** 6,
        parsed[i][2] if parsed[i][2] is not None else 0,
        i,
    ))

    # 整本书都在用的系列短语（如「我有一个梦想」）当作书名别名一并去掉；
    # 只占一部分的（如「媒体的使命」）留着，否则章节名会看不出区别
    total = len(files)
    strip_phrases = {g for g in groups if g and g != title
                     and sum(1 for p in parsed if p[0] == g) >= total * 0.9}

    # 同一主序号拆成多集的（如「袁氏当国1：…（1）…（4）」），去掉括号会全同名，
    # 这种时候把分集号补回章节名
    cleaned = []
    for i in order:
        phrase, main, sub, text = parsed[i]
        clean = display_title(text, title, strip_phrases)
        if clean.isdigit():
            clean = ""
        cleaned.append((phrase, main, sub, clean))

    seen = {}
    for _, _, _, clean in cleaned:
        if clean:
            seen[clean] = seen.get(clean, 0) + 1

    plan = []
    occ = {}
    for slot, (phrase, main, sub, clean) in enumerate(cleaned, start=1):
        if clean and seen[clean] > 1:
            # 优先用文件名里的分集号，没有就按同名出现的次序编号
            occ[clean] = occ.get(clean, 0) + 1
            tag = sub if sub is not None else occ[clean]
            clean = f"{clean}（{tag}）"
        num = chapter_display_number(slot, total)
        ext = os.path.splitext(files[order[slot - 1]])[1]
        new_name = f"{num}{ext}" if not clean else f"{num}.{clean}{ext}"
        plan.append((files[order[slot - 1]], new_name, clean or num, slot))
    return plan


# MARK: - ID3

TAG_TEXT_FRAMES = {
    "artist": "TPE1",
    "album_artist": "TPE2",
    "album": "TALB",
    "title": "TIT2",
    "genre": "TCON",
    "publisher": "TPUB",
    "track": "TRCK",
    "composer": "TCOM",
}


def write_tags(path, tags, cover_bytes=None, cover_mime="image/jpeg"):
    """写入 UTF-8 的 ID3v2.3 标签；cover_bytes 非空时替换内嵌封面。"""
    from mutagen.id3 import ID3, ID3NoHeaderError, TCON, TALB, APIC, TIT2, TPUB, TRCK, TPE1, TPE2, error as ID3Error

    try:
        id3 = ID3(path)
    except ID3NoHeaderError:
        id3 = ID3()
    except ID3Error:
        # 标签版本过旧或损坏：重建一份
        id3 = ID3()

    id3.clear()
    frame_map = {"TPE1": TPE1, "TPE2": TPE2, "TALB": TALB, "TIT2": TIT2,
                 "TCON": TCON, "TPUB": TPUB, "TRCK": TRCK}
    for key, value in tags.items():
        fid = TAG_TEXT_FRAMES.get(key)
        if value is None or value == "" or fid not in frame_map:
            continue
        id3.add(frame_map[fid](encoding=3, text=str(value)))

    if cover_bytes:
        id3.add(APIC(encoding=3, mime=cover_mime, type=3, desc="Cover", data=cover_bytes))

    # v1=None：顺带清掉文件尾可能存在的 ID3v1 残留，避免 App 读到旧的乱码字段
    id3.save(path, v2_version=3, v1=None)
    return True


def read_tags(path):
    from mutagen import File

    f = File(path)
    if f is None or f.tags is None:
        return {}, 0
    tags = {}
    for key in ("TPE1", "TPE2", "TALB", "TIT2", "TCON", "TPUB"):
        v = f.tags.get(key)
        tags[key] = str(v[0]) if v else ""
    pics = f.tags.getall("APIC") if hasattr(f.tags, "getall") else []
    size = len(pics[0].data) if pics else 0
    return tags, size


def remove_path(path):
    """删文件或目录，必要时先解除只读位（沙盒扩展属性会导致 EPERM）。"""
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            for root, dirs, files in os.walk(path):
                for n in dirs + files:
                    try:
                        os.chmod(os.path.join(root, n), stat.S_IWUSR | stat.S_IRUSR)
                    except OSError:
                        pass
            os.chmod(path, stat.S_IWUSR | stat.S_IRUSR | stat.S_IXUSR)
            os.rmdir(path)
        else:
            os.chmod(path, stat.S_IWUSR | stat.S_IRUSR)
            os.unlink(path)
        return True
    except OSError:
        return False
