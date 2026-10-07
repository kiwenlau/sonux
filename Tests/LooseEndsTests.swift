import XCTest
@testable import Sonux

/// 补几个前面几轮没扫到的分支：
///   - Chapter 空章节 & 极端 duration；
///   - Book 只有一章 & chapters.count == 0 时 matches 的返回；
///   - ListeningStats.recentDays 起点前于 1970 的负数窗口；
///   - ProgressPolicy.resumeTime 在 duration = 0 时不误判完成；
///   - TextMatch.Segment 全 marked / 全 marked=false 的边界；
///   - TranscriptLine 允许 start == end（虽然 lines() 会丢）。
final class LooseEndsTests: XCTestCase {
    // MARK: - Chapter 边界

    func testChapter_zeroDuration_fileEndEqualsFileStart() {
        let c = Chapter(id: "c", bookId: "b", index: 0, title: "T",
                        duration: 0, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"),
                        fileStart: 42)
        XCTAssertEqual(c.fileEnd, 42, "0 章长的 fileEnd 就等于 fileStart")
        XCTAssertEqual(c.localTime(42), 0)
        XCTAssertEqual(c.localTime(80), 38)  // 越界仍做减法，交给调用方截断
    }

    // MARK: - Book.chapters 空/单章

    func testBook_emptyChapters_totalDurationZeroAndNoChapterHit() {
        let b = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        XCTAssertEqual(b.totalDuration, 0)
        // 只有书名与作者能命中
        XCTAssertFalse(b.matches(searchText: "chapter"))
        XCTAssertTrue(b.matches(searchText: "T"))
    }

    func testBook_singleChapter_matchesChapterTitle() {
        let c = Chapter(id: "c", bookId: "b", index: 0, title: "Only",
                        duration: 10, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"))
        let b = Book(id: "b", title: "T", author: nil, chapters: [c], storagePath: "p")
        XCTAssertTrue(b.matches(searchText: "only"))
        XCTAssertTrue(b.matches(searchText: "ONLY"))
    }

    // MARK: - ListeningStats.recentDays 边界

    func testRecentDays_oneCountReturnsJustToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let s = ListeningStats()
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let days = s.recentDays(1, endingOn: today, calendar: cal)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.seconds, 0)
    }

    func testRecentDays_negativeCountReturnsEmpty() {
        // guard count > 0 → 负数与 0 都给 []
        let s = ListeningStats()
        XCTAssertEqual(s.recentDays(-3, endingOn: Date(), calendar: Calendar.current), [])
    }

    // MARK: - ProgressPolicy.resumeTime 零 duration

    func testResumeTime_zeroDurationNotTreatedAsFinished() {
        // isFinished 有 duration > 0 的守卫；0 长章不判完，回退照常
        let t = ProgressPolicy.resumeTime(time: 20, duration: 0)
        // 但 time > resumeRewind → 走回退分支
        XCTAssertEqual(t, 15)
    }

    // MARK: - TextMatch.Segment

    func testTextMatch_sentence_joinsAllSegmentsMarkedOrNot() {
        let m = TextMatch(bookID: "b", chapterID: "c", chapterTitle: "T", start: 0,
                          segments: [.init(text: "全命中", marked: true)])
        XCTAssertEqual(m.sentence, "全命中")
    }

    func testTextMatch_sentence_emptySegmentsGivesEmptyString() {
        let m = TextMatch(bookID: "b", chapterID: "c", chapterTitle: "T", start: 0, segments: [])
        XCTAssertEqual(m.sentence, "")
    }

    func testTextMatch_idComposesChapterAndRoundedStart() {
        let m = TextMatch(bookID: "b", chapterID: "c42", chapterTitle: "T", start: 12.7,
                          segments: [.init(text: "x", marked: false)])
        // id = "\(chapterID)@\(start)"，start 是 TimeInterval，会走默认 double 描述
        XCTAssertTrue(m.id.hasPrefix("c42@"))
    }

    // MARK: - TranscriptLine 允许脏数据（lines(forChapterFile:) 会丢）

    func testTranscriptLine_allowsZeroLengthSpanAtConstruction() {
        // 值类型本身不校验，交由 TranscriptFile.lines 过滤
        let line = TranscriptLine(start: 5, end: 5, text: "x")
        XCTAssertEqual(line.start, 5)
        XCTAssertEqual(line.end, 5)
    }

    // MARK: - AppLanguage Hashable

    func testAppLanguage_equalityByCodeAndName() {
        let a = AppLanguage(code: "en", nativeName: "English")
        let b = AppLanguage(code: "en", nativeName: "English")
        let c = AppLanguage(code: "en", nativeName: "English-ish")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
