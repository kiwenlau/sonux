import Foundation
import QuartzCore

/// 字幕仓库：把 Documents/transcripts/《书名》.json 读进内存，
/// 供播放页查「此刻在朗读哪一句」，也供弹层的整章文本页铺出全章字幕
///
/// 数据由 tools/transcribe.py 转写生成，用 ./sync-transcripts.sh 同步进沙盒。
/// 只保留当前这本书：一本几百 KB，全库留在内存里没必要，切书时整体换掉。
@MainActor
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    /// key: 章节相对路径（与 Chapter.id 一致），value: 按时间排序的字幕行
    @Published private(set) var linesByChapter: [String: [TranscriptLine]] = [:]

    /// 字幕包目录：Documents/transcripts（书库与字幕共用同一个 Documents，靠目录名区分）
    nonisolated static let transcriptsDirectory =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transcripts", isDirectory: true)

    private let transcriptsDir: URL
    private var loadedBookId: String?
    private var loadingBookId: String?

    private init() {
        transcriptsDir = Self.transcriptsDirectory
    }

    /// 异步读取某本书的字幕；同一本不重复读，等待期间换了书则丢弃结果
    func load(book: Book) async {
        guard loadedBookId != book.id, loadingBookId != book.id else { return }
        loadingBookId = book.id
        let fileURL = Self.transcriptURL(for: book, in: transcriptsDir)
        let chapters = book.chapters
        let t0 = CACurrentMediaTime()
        let decoded = await Task.detached(priority: .userInitiated) {
            TranscriptStore.decode(fileURL: fileURL, chapters: chapters)
        }.value
        // 读盘期间可能已经切到别的书，只认最后一次调度的那本
        guard loadingBookId == book.id else { return }
        loadedBookId = book.id
        loadingBookId = nil
        linesByChapter = decoded
        let ms = (CACurrentMediaTime() - t0) * 1000
        NSLog("[sonux] transcripts: 《%@》%@ 字幕 %d 章，%.1f ms",
              book.title, decoded.isEmpty ? "无" : "有", decoded.count, ms)
    }

    /// 此刻应当显示的字幕：最后一句「已经开口」的文案
    ///
    /// 句与句之间的短停顿不清空，否则字幕会随停顿频繁闪没；
    /// 落在第一句之前（片头音乐等）才真的没有内容可显示。
    func text(forChapter id: String?, at time: TimeInterval) -> String? {
        let lines = lines(forChapter: id)
        let index = lineIndex(lines: lines, at: time)
        return index >= 0 ? lines[index].text : nil
    }

    /// 整章字幕，按时间排序；没转写出来的章是空数组（文本页据此决定要不要出现）
    func lines(forChapter id: String?) -> [TranscriptLine] {
        guard let id else { return [] }
        return linesByChapter[id] ?? []
    }

    /// 此刻正在朗读的那一句；落在第一句之前返回 nil（还没开口）
    func line(forChapter id: String?, at time: TimeInterval) -> TranscriptLine? {
        let lines = lines(forChapter: id)
        let index = lineIndex(lines: lines, at: time)
        return index >= 0 ? lines[index] : nil
    }

    /// 此刻正在朗读的那一句的下标；落在第一句之前返回 -1（文本页靠它认高亮与跟随滚动）
    func lineIndex(forChapter id: String?, at time: TimeInterval) -> Int {
        lineIndex(lines: lines(forChapter: id), at: time)
    }

    /// 某章是否有字幕（播放页据此决定要不要留出行位）
    func hasTranscript(for chapterID: String?) -> Bool {
        !lines(forChapter: chapterID).isEmpty
    }

    // MARK: - Private

    /// 二分找「起始时间 ≤ time」的最后一行；落在第一句之前返回 -1
    private func lineIndex(lines: [TranscriptLine], at time: TimeInterval) -> Int {
        guard let first = lines.first, time >= first.start else { return -1 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// 字幕包路径：书目录名（单文件书用文件名去扩展名）+ .json
    nonisolated static func transcriptURL(for book: Book, in dir: URL) -> URL {
        let top = book.storagePath.split(separator: "/").first.map(String.init) ?? book.storagePath
        let name = LibraryService.supportedExtensions.contains((top as NSString).pathExtension.lowercased())
            ? (top as NSString).deletingPathExtension
            : top
        return dir.appendingPathComponent(name).appendingPathExtension("json")
    }

    nonisolated private static func decode(fileURL: URL, chapters: [Chapter]) -> [String: [TranscriptLine]] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(TranscriptFile.self, from: data) else { return [:] }
        var result: [String: [TranscriptLine]] = [:]
        for chapter in chapters {
            let lines = lines(for: chapter, of: chapters, in: file)
            if !lines.isEmpty { result[chapter.id] = lines }
        }
        return result
    }

    /// 某章的字幕行，时间是「本章内」的秒（与播放器和界面记账口径一致）
    ///
    /// 字幕包的键是章文件名；内嵌章节的书里整本共用一份时间轴，要按本章在文件里的
    /// 区间切片再把起点归零。
    nonisolated static func lines(for chapter: Chapter, of chapters: [Chapter],
                                 in file: TranscriptFile) -> [TranscriptLine] {
        return file.lines(forChapterFile: chapter.fileURL.lastPathComponent).compactMap { line in
            guard let start = localStart(of: line.start, in: chapter, of: chapters) else { return nil }
            return TranscriptLine(start: start, end: max(start, line.end - chapter.fileStart), text: line.text)
        }
    }

    /// 文件时间轴上的一句属不属于本章？属于就换算成章内秒（不在返回 nil）
    ///
    /// 边界留 0.5 秒容差：转写的时间戳会有一点头尾溢出，最后一章则不设上界。
    /// 播放路径与全文搜索共用这一条判据，两边看到的句子才是同一批。
    nonisolated static func localStart(of lineStart: TimeInterval, in chapter: Chapter,
                                       of chapters: [Chapter]) -> TimeInterval? {
        let last = chapter.index == chapters.count - 1
        guard lineStart >= chapter.fileStart - 0.5, last || lineStart < chapter.fileEnd - 0.5 else { return nil }
        return max(0, lineStart - chapter.fileStart)
    }
}
