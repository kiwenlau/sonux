import XCTest
@testable import Sonux

/// ListeningStats 是全 App 唯一会随时间累积的字典化状态：三张字典 daily / byBook / finished，
/// 一堆「按日/月/年分桶」的读接口，以及 add/markFinished/removeBook 三个写入接口。
/// 断言一律走固定 UTC 时区的 Calendar，避免测试随本机时区飘。
final class ListeningStatsTests: XCTestCase {
    /// 用一个 UTC 日历把「日/月/年」分桶键钉死，不随机器时区变
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        return utc.date(from: c)!
    }

    // MARK: - 分桶键

    func testDayKey_zeroPadsToISODate() {
        XCTAssertEqual(ListeningStats.dayKey(date(2026, 1, 5), calendar: utc), "2026-01-05")
        XCTAssertEqual(ListeningStats.dayKey(date(2026, 10, 12), calendar: utc), "2026-10-12")
        XCTAssertEqual(ListeningStats.dayKey(date(1999, 12, 31), calendar: utc), "1999-12-31")
    }

    func testMonthKey_yyyyMM() {
        XCTAssertEqual(ListeningStats.monthKey(date(2026, 10, 12), calendar: utc), "2026-10")
        XCTAssertEqual(ListeningStats.monthKey(date(2026, 1, 1), calendar: utc), "2026-01")
    }

    func testYearKey_yyyy() {
        XCTAssertEqual(ListeningStats.yearKey(date(2026, 10, 12), calendar: utc), "2026")
    }

    // MARK: - 累计写入

    func testAdd_accumulatesDailyAndByBook() {
        var s = ListeningStats()
        s.add(seconds: 30, bookId: "b1", at: date(2026, 10, 5), calendar: utc)
        s.add(seconds: 45, bookId: "b1", at: date(2026, 10, 5), calendar: utc)
        s.add(seconds: 20, bookId: "b2", at: date(2026, 10, 6), calendar: utc)
        XCTAssertEqual(s.daily["2026-10-05"], 75)
        XCTAssertEqual(s.daily["2026-10-06"], 20)
        XCTAssertEqual(s.byBook["b1"], 75)
        XCTAssertEqual(s.byBook["b2"], 20)
        XCTAssertEqual(s.totalSeconds, 95)
    }

    func testAdd_ignoresNonPositiveAndNaN() {
        var s = ListeningStats()
        s.add(seconds: 0, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        s.add(seconds: -5, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        s.add(seconds: .nan, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        s.add(seconds: .infinity, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        XCTAssertTrue(s.daily.isEmpty)
        XCTAssertTrue(s.byBook.isEmpty)
        XCTAssertEqual(s.totalSeconds, 0)
    }

    func testMarkFinished_onlyFirstTimeSticks() {
        var s = ListeningStats()
        s.markFinished(bookId: "b1", at: date(2026, 9, 1), calendar: utc)
        // 重听时不覆盖已有日期，否则会被算进别的月份
        s.markFinished(bookId: "b1", at: date(2026, 10, 31), calendar: utc)
        XCTAssertEqual(s.finished["b1"], "2026-09-01")
    }

    func testRemoveBook_clearsByBookAndFinishedButKeepsDaily() {
        var s = ListeningStats()
        s.add(seconds: 100, bookId: "b1", at: date(2026, 10, 5), calendar: utc)
        s.markFinished(bookId: "b1", at: date(2026, 10, 5), calendar: utc)
        s.removeBook("b1")
        XCTAssertNil(s.byBook["b1"])
        XCTAssertNil(s.finished["b1"])
        // 按天统计保留，历史总量不动
        XCTAssertEqual(s.daily["2026-10-05"], 100)
    }

    // MARK: - 读接口

    func testSeconds_onDate_returnsZeroWhenMissing() {
        var s = ListeningStats()
        s.add(seconds: 60, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        XCTAssertEqual(s.seconds(on: date(2026, 10, 5), calendar: utc), 60)
        XCTAssertEqual(s.seconds(on: date(2026, 10, 6), calendar: utc), 0)
    }

    func testSeconds_inBucket_prefixMatches() {
        var s = ListeningStats()
        s.add(seconds: 10, bookId: "b", at: date(2026, 10, 1), calendar: utc)
        s.add(seconds: 20, bookId: "b", at: date(2026, 10, 2), calendar: utc)
        s.add(seconds: 5, bookId: "b", at: date(2026, 11, 1), calendar: utc)
        XCTAssertEqual(s.seconds(in: "2026-10"), 30)   // 月桶
        XCTAssertEqual(s.seconds(in: "2026"), 35)      // 年桶（前缀匹配同一年所有月）
        XCTAssertEqual(s.seconds(in: "2025"), 0)
    }

    func testDaysListened_countsOnlyPositiveDays() {
        var s = ListeningStats()
        s.add(seconds: 5, bookId: "b", at: date(2026, 10, 1), calendar: utc)
        s.add(seconds: 3, bookId: "b", at: date(2026, 10, 2), calendar: utc)
        s.daily["2026-10-03"] = 0     // 脏数据：0 秒的一天
        s.daily["2026-10-04"] = 0.5   // <1 秒也不该算
        XCTAssertEqual(s.daysListened(in: "2026-10"), 2)
    }

    func testBooksFinished_inBucket_byCompletionDate() {
        var s = ListeningStats()
        s.markFinished(bookId: "a", at: date(2026, 10, 1), calendar: utc)
        s.markFinished(bookId: "b", at: date(2026, 10, 15), calendar: utc)
        s.markFinished(bookId: "c", at: date(2026, 11, 1), calendar: utc)
        XCTAssertEqual(s.booksFinished(in: "2026-10"), 2)
        XCTAssertEqual(s.booksFinished(in: "2026"), 3)
    }

    func testMonthlySeconds_inYear_returnsTwelveBuckets() {
        var s = ListeningStats()
        s.add(seconds: 100, bookId: "b", at: date(2026, 3, 5), calendar: utc)
        s.add(seconds: 50, bookId: "b", at: date(2026, 3, 20), calendar: utc)
        s.add(seconds: 10, bookId: "b", at: date(2026, 12, 1), calendar: utc)
        let buckets = s.monthlySeconds(inYear: 2026)
        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets[2], 150)    // 3 月下标是 2
        XCTAssertEqual(buckets[11], 10)    // 12 月
        XCTAssertEqual(buckets[0], 0)      // 1 月
    }

    func testMonthlySeconds_excludesOtherYears() {
        var s = ListeningStats()
        s.add(seconds: 10, bookId: "b", at: date(2025, 5, 1), calendar: utc)
        s.add(seconds: 20, bookId: "b", at: date(2026, 5, 1), calendar: utc)
        XCTAssertEqual(s.monthlySeconds(inYear: 2026)[4], 20)
        XCTAssertEqual(s.monthlySeconds(inYear: 2025)[4], 10)
    }

    // MARK: - recentDays / seconds(in count:)

    func testRecentDays_returnsCountDaysEndingOnNow() {
        var s = ListeningStats()
        s.add(seconds: 60, bookId: "b", at: date(2026, 10, 3), calendar: utc)
        s.add(seconds: 30, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        let days = s.recentDays(5, endingOn: date(2026, 10, 5), calendar: utc)
        XCTAssertEqual(days.count, 5)
        // 从旧到新：10-01 / 10-02 / 10-03 / 10-04 / 10-05
        XCTAssertEqual(days.map(\.seconds), [0, 0, 60, 0, 30])
        XCTAssertEqual(days.first?.date, utc.startOfDay(for: date(2026, 10, 1)))
    }

    func testRecentDays_zeroCountReturnsEmpty() {
        let s = ListeningStats()
        XCTAssertEqual(s.recentDays(0, endingOn: date(2026, 10, 5), calendar: utc), [])
    }

    func testSecondsInCount_sumsTheWindow() {
        var s = ListeningStats()
        s.add(seconds: 10, bookId: "b", at: date(2026, 10, 1), calendar: utc)
        s.add(seconds: 20, bookId: "b", at: date(2026, 10, 3), calendar: utc)
        s.add(seconds: 40, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        XCTAssertEqual(s.seconds(in: 5, endingOn: date(2026, 10, 5), calendar: utc), 70)  // 10-01..10-05
        XCTAssertEqual(s.seconds(in: 3, endingOn: date(2026, 10, 5), calendar: utc), 60)  // 10-03..10-05
    }

    // MARK: - streakDays

    func testStreakDays_countsBackFromToday() {
        var s = ListeningStats()
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 1), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 2), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 3), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 4), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        XCTAssertEqual(s.streakDays(endingOn: date(2026, 10, 5), calendar: utc), 5)
    }

    func testStreakDays_toleratesTodayNotStartedYet() {
        // 今天还没听，从昨天起算
        var s = ListeningStats()
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 4), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        XCTAssertEqual(s.streakDays(endingOn: date(2026, 10, 6), calendar: utc), 2)
    }

    func testStreakDays_zeroWhenNeitherTodayNorYesterdayListened() {
        var s = ListeningStats()
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 1), calendar: utc)
        XCTAssertEqual(s.streakDays(endingOn: date(2026, 10, 5), calendar: utc), 0)
    }

    func testStreakDays_stopsAtGap() {
        var s = ListeningStats()
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 1), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 3), calendar: utc)   // 10-02 缺
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 4), calendar: utc)
        s.add(seconds: 1, bookId: "b", at: date(2026, 10, 5), calendar: utc)
        XCTAssertEqual(s.streakDays(endingOn: date(2026, 10, 5), calendar: utc), 3)
    }

    // MARK: - Codable 兼容

    func testDecode_missingAllKeysYieldsEmptyStats() throws {
        // 老 progress.json 里可能连 daily 都没有：三份字段全部走 decodeIfPresent 兜底
        let s = try JSONDecoder().decode(ListeningStats.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(s.daily.isEmpty)
        XCTAssertTrue(s.byBook.isEmpty)
        XCTAssertTrue(s.finished.isEmpty)
        XCTAssertEqual(s.totalSeconds, 0)
    }

    func testDecode_missingFinishedKeyIsTolerated() throws {
        // 加字段之前的旧数据：只有 daily 与 byBook，finished 后加的
        let json = #"{"daily":{"2026-10-05":60},"byBook":{"b1":60}}"#
        let s = try JSONDecoder().decode(ListeningStats.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(s.daily["2026-10-05"], 60)
        XCTAssertEqual(s.byBook["b1"], 60)
        XCTAssertTrue(s.finished.isEmpty)
    }

    func testRoundtrip_preservesAllThreeBuckets() throws {
        var s = ListeningStats()
        s.add(seconds: 60, bookId: "b1", at: date(2026, 10, 5), calendar: utc)
        s.markFinished(bookId: "b1", at: date(2026, 10, 6), calendar: utc)
        let decoded = try JSONDecoder().decode(ListeningStats.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
}
