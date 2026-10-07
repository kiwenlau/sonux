import XCTest
@testable import Sonux

/// LibraryTextSearch.scan 是全文搜索的最小单位（一次一本）：
///   输入一本 Book + query + transcripts 目录 → 命中句列表（含高亮片段）或 nil（无字幕包）
/// 通过写临时字幕 JSON 到 NSTemporaryDirectory，能纯本地跑完整条链路：
/// 分词 → 三段比对（原样/折叠/挤空白）→ 切段高亮 → 每本限 80 句。
final class LibraryTextSearchTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sonux-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 单文件书：storagePath = 名字.mp3，字幕包 = <tmp>/<名字>.json
    private func writeTranscript(name: String, chapterFile: String,
                                 lines: [(TimeInterval, TimeInterval, String)]) throws {
        var raw: [[Any]] = []
        for (start, end, text) in lines {
            raw.append([start, end, text])
        }
        let payload: [String: Any] = [
            "v": 1,
            "chapters": [chapterFile: raw]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: tmpDir.appendingPathComponent("\(name).json"))
    }

    private func singleChapterBook(name: String, chapterFile: String) -> Book {
        let chapter = Chapter(id: "\(name)-c0", bookId: name, index: 0, title: "第一章",
                              duration: 1000, fileURL: URL(fileURLWithPath: "/tmp/\(chapterFile)"))
        return Book(id: name, title: name, author: nil, chapters: [chapter], storagePath: chapterFile)
    }

    // MARK: - 命中判定

    func testScan_noTranscriptFile_returnsNil() throws {
        let book = singleChapterBook(name: "missing", chapterFile: "missing.mp3")
        XCTAssertNil(LibraryTextSearch.scan(book: book, query: "任意词", transcriptsDir: tmpDir))
    }

    func testScan_emptyQuery_returnsNilBecauseTermsEmpty() throws {
        // 关键词拆出来空 → 整趟扫描放弃（区别于「有字幕但一句没命中」）
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [(0, 1, "正文")])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        XCTAssertNil(LibraryTextSearch.scan(book: book, query: "   ", transcriptsDir: tmpDir))
    }

    func testScan_noMatch_returnsZeroHits() throws {
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [(0, 1, "第一句")])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "zzz", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.matches.count, 0)
        XCTAssertEqual(hits.hidden, 0)
        XCTAssertEqual(hits.totalHits, 0)
    }

    func testScan_singleTermCaseSensitiveHit() throws {
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "宪法是根本法"),
            (3, 5, "无关句子"),
            (6, 8, "另一次提到宪法的地方"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "宪法", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 2)
        XCTAssertEqual(hits.matches.map(\.start), [0, 6])
        XCTAssertFalse(hits.bookID.isEmpty)
        XCTAssertEqual(hits.bookID, "b")
    }

    func testScan_multiTermRequiresAllPresent() throws {
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "民主的细节很动人"),       // 命中两个词
            (3, 5, "只有民主"),                 // 只命中一个
            (6, 8, "另一本书讲细节"),           // 只命中另一个
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "民主 细节", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 1)
        XCTAssertTrue(hits.matches[0].sentence.contains("民主"))
        XCTAssertTrue(hits.matches[0].sentence.contains("细节"))
    }

    // MARK: - 折叠比对（大小写/全半角）

    func testScan_foldMatchForASCIICaseInsensitive() throws {
        // 关键词全小写、句里是驼峰：走折叠比对仍能命中
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "iPhone 是苹果的招牌"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "iphone", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 1)
    }

    func testScan_foldMatchForWidthInsensitive() throws {
        // 关键词是全角数字、句里是半角：靠 .widthInsensitive 折叠
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "2008 年的事"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "２００８", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 1, "全角/半角应能互认")
    }

    // MARK: - 空白挤掉再比

    func testScan_pureChineseIgnoresFoldableSkip() throws {
        // 关键词纯汉字 + 句子里没空格：走第一段原样命中就够，不该多绕折叠
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "这是一句正常的中文"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "正常", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 1)
    }

    func testScan_collapsesWhitespaceInsideText() throws {
        // 汉字之间被塞进多余空格（转写校对的常见产物）：挤掉空白再比要能命中
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "自 由 是人的权利"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "自由", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 1, "句中夹空格也要能命中「自由」")
        // 高亮片段仍指向原文（不是挤掉空白后的字符串）
        XCTAssertTrue(hits.matches[0].segments.contains { $0.marked })
    }

    // MARK: - 高亮片段

    func testScan_segmentsSplitAtKeywordKeepOriginalText() throws {
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "前段宪法后段"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "宪法", transcriptsDir: tmpDir))
        let segs = hits.matches[0].segments
        XCTAssertEqual(segs.count, 3, "前段/命中/后段")
        XCTAssertEqual(segs.map(\.text), ["前段", "宪法", "后段"])
        XCTAssertEqual(segs.map(\.marked), [false, true, false])
    }

    func testScan_segmentsRejoinIntoSentence() throws {
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: [
            (0, 2, "A 关键词 B 关键词 C"),
        ])
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "关键词", transcriptsDir: tmpDir))
        // sentence 拼回原句
        XCTAssertEqual(hits.matches[0].sentence, "A 关键词 B 关键词 C")
    }

    // MARK: - 每本上限

    func testScan_respectsPerBookLimitAndTracksHidden() throws {
        // 造 100 句全命中，perBookLimit = 80，剩下的只入 hidden 不列出来
        let lines: [(TimeInterval, TimeInterval, String)] = (0..<100).map { i in
            (Double(i) * 2, Double(i) * 2 + 1, "第 \(i) 句都有猫")
        }
        try writeTranscript(name: "b", chapterFile: "b.mp3", lines: lines)
        let book = singleChapterBook(name: "b", chapterFile: "b.mp3")
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "猫", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.matches.count, LibraryTextSearch.perBookLimit)
        XCTAssertEqual(hits.hidden, 100 - LibraryTextSearch.perBookLimit)
        XCTAssertEqual(hits.totalHits, 100)
    }

    // MARK: - 章外句子内时间戳归零

    func testScan_multiChapterOnlyMatchesLinesInsideChapterRange() throws {
        // 一本 m4b 两章共用一份字幕轴：c1 [0,100] / c2 [100,300]
        let c1 = Chapter(id: "b-c1", bookId: "b", index: 0, title: "第一章",
                         duration: 100, fileURL: URL(fileURLWithPath: "/tmp/b.m4b"), fileStart: 0)
        let c2 = Chapter(id: "b-c2", bookId: "b", index: 1, title: "第二章",
                         duration: 200, fileURL: URL(fileURLWithPath: "/tmp/b.m4b"), fileStart: 100)
        let book = Book(id: "b", title: "b", author: nil, chapters: [c1, c2], storagePath: "b.m4b")
        try writeTranscript(name: "b", chapterFile: "b.m4b", lines: [
            (10, 20, "c1 里的猫"),
            (150, 160, "c2 里的猫"),
        ])
        let hits = try XCTUnwrap(LibraryTextSearch.scan(book: book, query: "猫", transcriptsDir: tmpDir))
        XCTAssertEqual(hits.totalHits, 2)
        // start 是「本章内」的秒：c1 里 10-0=10；c2 里 150-100=50
        let starts = hits.matches.map(\.start).sorted()
        XCTAssertEqual(starts, [10, 50])
    }
}
