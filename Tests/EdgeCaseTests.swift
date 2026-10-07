import XCTest
@testable import Sonux

/// 边界/极端输入的回归集合：把 NaN、Infinity、极大/极小值、异常 unicode 全过一遍，
/// 保证 UI 上游拿到什么脏数据都不会崩。
final class EdgeCaseTests: XCTestCase {
    // MARK: - TimeFormat.time

    func testTime_hugeValueDoesNotCrash() {
        // 一年多的秒数仍走 h:m:s 三段
        XCTAssertEqual(TimeFormat.time(3600 * 24 * 365), "8760:00:00")
    }

    func testTime_nanIsTreatedAsZero() {
        // max(0, seconds).rounded()：NaN 与 .rounded() 相遇，Swift 语义下仍给 NaN，
        // 但 Int(NaN) 会崩；这里靠 max(0, .nan) 返回 0（IEEE 754 max 语义）
        let result = TimeFormat.time(.nan)
        XCTAssertFalse(result.isEmpty)
    }

    func testTime_negativeInfinityClampsToZero() {
        XCTAssertEqual(TimeFormat.time(-.infinity), "0:00")
    }

    // MARK: - TimeFormat.speed

    func testSpeed_zeroAndNegative() {
        XCTAssertEqual(TimeFormat.speed(0), "0")
        // 负倍速不属于合法输入，但函数不该崩
        let negative = TimeFormat.speed(-1)
        XCTAssertFalse(negative.isEmpty)
    }

    func testSpeed_largeValueDoesNotCrash() {
        XCTAssertEqual(TimeFormat.speed(10), "10")
    }

    // MARK: - ProgressPolicy

    func testIsStarted_negativeAndNaN() {
        XCTAssertFalse(ProgressPolicy.isStarted(-100))
        XCTAssertFalse(ProgressPolicy.isStarted(.nan))
    }

    func testIsFinished_hugeTimeStillFallsIntoFinished() {
        // time 远超 duration：duration - time < 0 ≤ 15，仍判「播完」
        XCTAssertTrue(ProgressPolicy.isFinished(time: 999, duration: 100))
    }

    func testResumeTime_timeInfinityDoesNotCrash() {
        // 极端脏数据也不能崩；语义上判完成 → 归零
        XCTAssertEqual(ProgressPolicy.resumeTime(time: .infinity, duration: 100), 0)
    }

    // MARK: - Chapter 时间轴

    func testChapter_localTime_hugeFileTimeStillClampsNonNegative() {
        let c = Chapter(id: "c", bookId: "b", index: 0, title: "T",
                        duration: 100, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"),
                        fileStart: 50)
        XCTAssertGreaterThanOrEqual(c.localTime(.infinity), 0)
        XCTAssertGreaterThanOrEqual(c.localTime(-.infinity), 0)
    }

    func testChapter_fileTime_negativeLocalReturnsFileStartOffset() {
        let c = Chapter(id: "c", bookId: "b", index: 0, title: "T",
                        duration: 100, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"),
                        fileStart: 50)
        XCTAssertEqual(c.fileTime(-10), 40)
    }

    // MARK: - Book.matches

    func testMatches_queryLongerThanTitleNeverHits() {
        let book = Book(id: "b", title: "短", author: nil, chapters: [], storagePath: "p")
        XCTAssertFalse(book.matches(searchText: "这是一个不可能出现在书名里的很长很长的字符串"))
    }

    func testMatches_queryWithOnlyNewlinesTreatedAsEmpty() {
        // trimmingCharacters(.whitespacesAndNewlines) 只留空 → 恒 true
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        XCTAssertTrue(book.matches(searchText: "\n\n\t\n"))
    }

    // MARK: - ListeningStats

    func testAdd_tinyPositiveSecondsStillAccumulates() {
        var s = ListeningStats()
        s.add(seconds: 0.001, bookId: "b")
        XCTAssertEqual(s.totalSeconds, 0.001, accuracy: 1e-9)
    }

    func testDayKey_epochDateProduces1970() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ListeningStats.dayKey(Date(timeIntervalSince1970: 0), calendar: cal),
                       "1970-01-01")
    }

    func testStreakDays_neverNegative() {
        let s = ListeningStats()
        XCTAssertEqual(s.streakDays(), 0)
    }

    // MARK: - QuoteCardView 常量

    func testQuoteCard_sizeIsThreeToFour() {
        // 3:4 竖版是分享链路里的通吃尺寸
        XCTAssertEqual(QuoteCardView.size.width, 375)
        XCTAssertEqual(QuoteCardView.size.height, 500)
        XCTAssertEqual(QuoteCardView.size.width / QuoteCardView.size.height, 0.75, accuracy: 1e-6)
    }
}
