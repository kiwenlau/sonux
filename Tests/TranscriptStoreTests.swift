import XCTest
@testable import Sonux

/// TranscriptStore 里三块 pure static（nonisolated）：
///   - transcriptURL(for:in:) 从 storagePath 推字幕包路径
///   - localStart(of:in:of:) 判某句在不在本章区间内、换算成章内秒
///   - lines(for:of:in:) 从 TranscriptFile 拿某章的字幕行
/// 都不依赖 @MainActor 状态、也不读盘（TranscriptFile 是入参），最适合直接跑断言。
final class TranscriptStoreTests: XCTestCase {
    private func chapter(_ id: String, index: Int, file: String,
                        fileStart: TimeInterval, duration: TimeInterval) -> Chapter {
        Chapter(id: id, bookId: "b", index: index, title: id, duration: duration,
                fileURL: URL(fileURLWithPath: "/tmp/\(file)"), fileStart: fileStart)
    }

    private func transcript(_ pairs: [(start: TimeInterval, end: TimeInterval, text: String)],
                            fileKey: String) -> TranscriptFile {
        let data = try! JSONSerialization.data(withJSONObject: [
            "v": 1,
            "chapters": [fileKey: pairs.map { [$0.start, $0.end, $0.text] as [Any] }]
        ])
        return try! JSONDecoder().decode(TranscriptFile.self, from: data)
    }

    // MARK: - transcriptURL

    func testTranscriptURL_folderStoragePath_usesFolderName() {
        let book = Book(id: "b", title: "T", author: nil, chapters: [],
                        storagePath: "一路走来一路读")
        let url = TranscriptStore.transcriptURL(for: book,
            in: URL(fileURLWithPath: "/Documents/transcripts", isDirectory: true))
        XCTAssertEqual(url.lastPathComponent, "一路走来一路读.json")
    }

    func testTranscriptURL_singleAudioFile_stripsExtension() {
        // 单文件书：storagePath 是文件名带扩展，字幕包要把扩展去掉
        let book = Book(id: "b", title: "T", author: nil, chapters: [],
                        storagePath: "book.m4b")
        let url = TranscriptStore.transcriptURL(for: book,
            in: URL(fileURLWithPath: "/Documents/transcripts", isDirectory: true))
        XCTAssertEqual(url.lastPathComponent, "book.json")
    }

    func testTranscriptURL_nestedPath_usesTopComponent() {
        // 外部引用（书签）的书：storagePath 是相对父目录的路径，取最上层条目名
        let book = Book(id: "b", title: "T", author: nil, chapters: [],
                        storagePath: "SomeFolder/song.mp3")
        let url = TranscriptStore.transcriptURL(for: book,
            in: URL(fileURLWithPath: "/Documents/transcripts", isDirectory: true))
        // 首段 SomeFolder 不是音频扩展，因此直接当名字（不去扩展）
        XCTAssertEqual(url.lastPathComponent, "SomeFolder.json")
    }

    func testTranscriptURL_supportedExtensionAtTop_isStripped() {
        // 顶段本身就是 mp3/m4a/m4b/aac/wav/wave 才剥扩展
        for ext in ["mp3", "m4a", "m4b", "aac", "wav", "wave"] {
            let book = Book(id: "b", title: "T", author: nil, chapters: [],
                            storagePath: "sample.\(ext)")
            let url = TranscriptStore.transcriptURL(for: book,
                in: URL(fileURLWithPath: "/x", isDirectory: true))
            XCTAssertEqual(url.lastPathComponent, "sample.json", "\(ext) 应当被剥掉")
        }
    }

    func testTranscriptURL_unsupportedExtension_keepsIt() {
        // .txt / .pdf 等不在支持列表，不能误当成音频文件剥扩展
        let book = Book(id: "b", title: "T", author: nil, chapters: [],
                        storagePath: "readme.txt")
        let url = TranscriptStore.transcriptURL(for: book,
            in: URL(fileURLWithPath: "/x", isDirectory: true))
        XCTAssertEqual(url.lastPathComponent, "readme.txt.json")
    }

    // MARK: - localStart

    func testLocalStart_singleChapterFile_mapsFileTimeToChapterTime() {
        let ch = chapter("c1", index: 0, file: "a.mp3", fileStart: 0, duration: 100)
        let all = [ch]
        XCTAssertEqual(TranscriptStore.localStart(of: 0, in: ch, of: all), 0)
        XCTAssertEqual(TranscriptStore.localStart(of: 50, in: ch, of: all), 50)
        // 单章时不设上界（最后一章容忍转写头尾溢出）
        XCTAssertEqual(TranscriptStore.localStart(of: 200, in: ch, of: all), 200)
    }

    func testLocalStart_multiChapter_cutsByFileStartFileEnd() {
        // 一章 100s + 二章 200s 都在同一个文件里
        let c1 = chapter("c1", index: 0, file: "all.m4b", fileStart: 0,   duration: 100)
        let c2 = chapter("c2", index: 1, file: "all.m4b", fileStart: 100, duration: 200)
        let all = [c1, c2]
        // c1 区间：lineStart < fileEnd-0.5 = 99.5
        XCTAssertEqual(TranscriptStore.localStart(of: 50, in: c1, of: all), 50)
        XCTAssertNil(TranscriptStore.localStart(of: 100, in: c1, of: all), "c1 非最后一章，越上界的要判掉")
        // c2 是最后一章：不设上界，但下界仍留 0.5 秒容差
        XCTAssertEqual(TranscriptStore.localStart(of: 150, in: c2, of: all), 50)
        XCTAssertEqual(TranscriptStore.localStart(of: 99.6, in: c2, of: all), 0, "低于 fileStart-0.5 才拒；99.6 ≥ 99.5 且被 max(0,.) 夹到 0")
        XCTAssertNil(TranscriptStore.localStart(of: 99.4, in: c2, of: all), "早于 fileStart-0.5 归前一章")
    }

    func testLocalStart_lastChapterDoesNotCapUpper() {
        let c1 = chapter("c1", index: 0, file: "x.m4b", fileStart: 0,   duration: 100)
        let c2 = chapter("c2", index: 1, file: "x.m4b", fileStart: 100, duration: 50)
        let all = [c1, c2]
        // c2 是最后一章：lineStart 甚至可以超过 fileEnd，仍应归 c2
        XCTAssertEqual(TranscriptStore.localStart(of: 160, in: c2, of: all), 60)
        XCTAssertEqual(TranscriptStore.localStart(of: 999, in: c2, of: all), 899)
    }

    // MARK: - lines(for:of:in:)

    func testLines_forSingleChapter_returnsChapterRelativeTime() {
        let c1 = chapter("c1", index: 0, file: "a.mp3", fileStart: 0, duration: 100)
        let file = transcript([(0, 2, "一"), (5, 7, "二")], fileKey: "a.mp3")
        let lines = TranscriptStore.lines(for: c1, of: [c1], in: file)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].start, 0)
        XCTAssertEqual(lines[1].start, 5)
    }

    func testLines_forChapterInsideM4b_offsetsAndDropsForeignLines() {
        // 一本 m4b 两章：c1 从 0-100，c2 从 100-300。字幕按整本时间轴给。
        let c1 = chapter("c1", index: 0, file: "all.m4b", fileStart: 0,   duration: 100)
        let c2 = chapter("c2", index: 1, file: "all.m4b", fileStart: 100, duration: 200)
        let file = transcript([(10, 20, "开头"), (50, 60, "中段"),
                               (110, 120, "c2 首句"), (250, 260, "c2 末句")],
                              fileKey: "all.m4b")
        let l1 = TranscriptStore.lines(for: c1, of: [c1, c2], in: file)
        // c1 只吃 <99.5 的三句里前两句（第三句 110 归 c2）
        XCTAssertEqual(l1.count, 2)
        XCTAssertEqual(l1.map(\.start), [10, 50])
        let l2 = TranscriptStore.lines(for: c2, of: [c1, c2], in: file)
        XCTAssertEqual(l2.count, 2, "c2 是最后一章不设上界")
        XCTAssertEqual(l2.map(\.start), [10, 150], "章内秒 = 文件秒 - fileStart")
    }

    func testLines_endIsClampedToNotLessThanStart() {
        // 脏字幕里若 end 减掉 fileStart 会小于新的 start，取 max 保证不倒挂
        let ch = chapter("c1", index: 0, file: "x.mp3", fileStart: 50, duration: 100)
        let file = transcript([(50.5, 51, "A")], fileKey: "x.mp3")
        let lines = TranscriptStore.lines(for: ch, of: [ch], in: file)
        XCTAssertEqual(lines.first?.start, 0.5)
        XCTAssertGreaterThanOrEqual(lines.first?.end ?? 0, lines.first?.start ?? 0)
    }
}
