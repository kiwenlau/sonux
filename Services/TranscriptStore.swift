import Foundation
import QuartzCore

/// 字幕仓库：把 Documents/transcripts/《书名》.json 读进内存，供播放页查「此刻在朗读哪一句」
///
/// 数据由 tools/transcribe.py 转写生成，用 ./sync-transcripts.sh 同步进沙盒。
/// 只保留当前这本书：一本几百 KB，全库留在内存里没必要，切书时整体换掉。
@MainActor
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    /// key: 章节相对路径（与 Chapter.id 一致），value: 按时间排序的字幕行
    @Published private(set) var linesByChapter: [String: [TranscriptLine]] = [:]

    private let transcriptsDir: URL
    private var loadedBookId: String?
    private var loadingBookId: String?

    private init() {
        transcriptsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transcripts", isDirectory: true)
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
        guard let id, let lines = linesByChapter[id], let first = lines.first else { return nil }
        if time < first.start { return nil }
        return lines[lineIndex(lines: lines, at: time)].text
    }

    /// 某章是否有字幕（播放页据此决定要不要留出行位）
    func hasTranscript(for chapterID: String?) -> Bool {
        guard let chapterID else { return false }
        return !(linesByChapter[chapterID]?.isEmpty ?? true)
    }

    // MARK: - Private

    /// 二分找「起始时间 ≤ time」的最后一行；调用方保证 time 不早于首行
    private func lineIndex(lines: [TranscriptLine], at time: TimeInterval) -> Int {
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
            // 字幕包的键是章文件名；内嵌章节的书里整本共用一份时间轴，按本章区间切片
            let lines = file.lines(forChapterFile: chapter.fileURL.lastPathComponent)
            let last = chapter.index == chapters.count - 1
            let sliced = lines.compactMap { line -> TranscriptLine? in
                guard line.start >= chapter.fileStart - 0.5, last || line.start < chapter.fileEnd - 0.5 else { return nil }
                let start = max(0, line.start - chapter.fileStart)
                return TranscriptLine(start: start, end: max(start, line.end - chapter.fileStart), text: line.text)
            }
            if !sliced.isEmpty { result[chapter.id] = sliced }
        }
        return result
    }
}
