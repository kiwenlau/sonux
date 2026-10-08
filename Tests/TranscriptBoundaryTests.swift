import XCTest
@testable import Sonux

/// 把两处「边界合并」逻辑再钉一层：
///   - TranscriptStore.lines(for:of:in:) 三章 m4b 里章内秒的换算与章尾 end 夹紧；
///   - LibraryTextSearch 多关键词命中句里「重叠区间」的合并（segments 里对
///     range.upperBound <= cursor 的重叠段要跳过，否则会切出负长度片段崩在 String 上）。
/// 都靠临时目录写一份真字幕包端到端跑，不碰任何播放器/音频状态。
final class TranscriptBoundaryTests: XCTestCase {
    private func chapter(_ id: String, index: Int, file: String,
                        start: TimeInterval, duration: TimeInterval) -> Chapter {
        Chapter(id: id, bookId: "b", index: index, title: "第\(index)章",
                duration: duration, fileURL: URL(fileURLWithPath: "/tmp/\(file)"),
                fileStart: start)
    }

    // MARK: - 三章 m4b 的文件轴→章轴换算

    func testLocalStart_threeChaptersMiddleChapterWindow() {
        // 整本一根时间轴切三章：0-100 / 100-200 / 200-300
        let c0 = chapter("c0", index: 0, file: "a.m4b", start: 0,   duration: 100)
        let c1 = chapter("c1", index: 1, file: "a.m4b", start: 100, duration: 100)
        let c2 = chapter("c2", index: 2, file: "a.m4b", start: 200, duration: 100)
        let all = [c0, c1, c2]
        // 中间章 c1：窗口 [100-0.5, 200-0.5)
        XCTAssertEqual(TranscriptStore.localStart(of: 150, in: c1, of: all), 50)
        XCTAssertNil(TranscriptStore.localStart(of: 99, in: c1, of: all), "99 < 99.5 归 c0")
        XCTAssertNil(TranscriptStore.localStart(of: 200, in: c1, of: all), "200 ≥ 199.5 归 c2")
    }

    func testLocalStart_lastChapterNoUpperBound() {
        let c0 = chapter("c0", index: 0, file: "a.m4b", start: 0,   duration: 100)
        let c1 = chapter("c1", index: 1, file: "a.m4b", start: 100, duration: 100)
        let all = [c0, c1]
        // 末章 c1：哪怕 lineStart 越过 fileEnd(200) 仍算它（转写尾部溢出兜底）
        XCTAssertEqual(TranscriptStore.localStart(of: 250, in: c1, of: all), 150)
    }

    func testLines_endIsOffsetByFileStartAndNotBelowStart() {
        // c1 fileStart=100：一句 [110, 130] → 章内 [10, 30]
        let c0 = chapter("c0", index: 0, file: "a.m4b", start: 0,   duration: 100)
        let c1 = chapter("c1", index: 1, file: "a.m4b", start: 100, duration: 200)
        let json = #"{"v":1,"chapters":{"a.m4b":[[110,130,"中"]]}}"#
        let file = try! JSONDecoder().decode(TranscriptFile.self, from: json.data(using: .utf8)!)
        let lines = TranscriptStore.lines(for: c1, of: [c0, c1], in: file)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].start, 10, accuracy: 1e-6)
        XCTAssertEqual(lines[0].end, 30, accuracy: 1e-6)   // 130 - fileStart 100
    }

    // MARK: - 文本搜索重叠关键词区间的合并

    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sonux-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func writeTranscript(name: String, chapterFile: String,
                                 lines: [(TimeInterval, TimeInterval, String)]) throws {
        var raw: [[Any]] = []
        for (s, e, t) in lines { raw.append([s, e, t]) }
        let payload: [String: Any] = ["v": 1, "chapters": [chapterFile: raw]]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: tmp.appendingPathComponent("\(name).json"))
    }

    func testSearch_overlappingKeywordTermsMergeWithoutCorruption() throws {
        // 两个关键词「宪法」与「法」在同句里区间重叠：切段时后一个词的区间落在前一个之内，
        // segments(of:terms:) 用 cursor 去重，不能崩、拼回必须等于原句
        try writeTranscript(name: "b", chapterFile: "b.mp3",
                            lines: [(0, 2, "宪法是根本大法")])
        let chapter = Chapter(id: "b-c0", bookId: "b", index: 0, title: "第一章",
                              duration: 10, fileURL: URL(fileURLWithPath: "/tmp/b.mp3"))
        let book = Book(id: "b", title: "b", author: nil, chapters: [chapter], storagePath: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "宪法 法",
                                                        transcriptsDir: tmp))
        XCTAssertEqual(hits.totalHits, 1)
        // 命中句拼回来必须等于原文（分段不能吞字或错位）
        XCTAssertEqual(hits.matches[0].sentence, "宪法是根本大法")
    }

    func testSearch_pureChineseTermSkipsFoldComparison() throws {
        // 纯汉字关键词：hasFoldableCharacter 判假，第二段折叠比对整趟跳过；
        // 只要原样命中即可（这条主要保证不走进折叠/挤空白分支也不崩）
        try writeTranscript(name: "c", chapterFile: "c.mp3",
                            lines: [(0, 2, "民主的细节")])
        let chapter = Chapter(id: "c-c0", bookId: "c", index: 0, title: "第一章",
                              duration: 10, fileURL: URL(fileURLWithPath: "/tmp/c.mp3"))
        let book = Book(id: "c", title: "c", author: nil, chapters: [chapter], storagePath: "c.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "民主",
                                                        transcriptsDir: tmp))
        XCTAssertEqual(hits.matches.first?.sentence, "民主的细节")
    }
}
