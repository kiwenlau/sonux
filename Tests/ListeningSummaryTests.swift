import XCTest
@testable import Sonux

/// ListeningSummary 与 ListeningReport 是「我」页与收听报告页的快照 struct：
/// 字段都是 let，只带两个纯 computed property——isEmpty 与 hasMonthActivity，
/// 用来决定要不要画「近 7 天卡片」和「本月卡片」。测试把两个判据钉死。
@MainActor
final class ListeningSummaryTests: XCTestCase {
    private func day(_ seconds: TimeInterval) -> ListeningDay {
        ListeningDay(date: Date(timeIntervalSince1970: 0), seconds: seconds)
    }

    private func summary(total: TimeInterval, month: TimeInterval, monthFinished: Int) -> LibraryService.ListeningSummary {
        LibraryService.ListeningSummary(
            totalSeconds: total,
            todaySeconds: 0,
            last7Seconds: 0,
            streakDays: 0,
            recentDays: [],
            monthSeconds: month,
            monthFinished: monthFinished
        )
    }

    // MARK: - isEmpty

    func testIsEmpty_belowOneSecondCountsAsEmpty() {
        // 0 / 亚秒都算空：只听了半秒的人不该看到「累计 0 秒」卡片
        XCTAssertTrue(summary(total: 0, month: 0, monthFinished: 0).isEmpty)
        XCTAssertTrue(summary(total: 0.99, month: 0, monthFinished: 0).isEmpty)
    }

    func testIsEmpty_atLeastOneSecondCountsAsNonEmpty() {
        XCTAssertFalse(summary(total: 1, month: 0, monthFinished: 0).isEmpty)
        XCTAssertFalse(summary(total: 3600, month: 0, monthFinished: 0).isEmpty)
    }

    // MARK: - hasMonthActivity

    func testHasMonthActivity_falseWhenNoListenAndNoFinish() {
        // 一个月既没听满 1 秒、也没听完任何一本 → 页面不摆空卡
        XCTAssertFalse(summary(total: 100, month: 0, monthFinished: 0).hasMonthActivity)
        XCTAssertFalse(summary(total: 100, month: 0.5, monthFinished: 0).hasMonthActivity)
    }

    func testHasMonthActivity_trueWhenOneSecondListened() {
        XCTAssertTrue(summary(total: 100, month: 1, monthFinished: 0).hasMonthActivity)
    }

    func testHasMonthActivity_trueWhenAnyBookFinished() {
        // 即使本月一分钟没听，但把一本之前开的书在本月画上了句号，卡片也要出现
        XCTAssertTrue(summary(total: 100, month: 0, monthFinished: 1).hasMonthActivity)
        XCTAssertTrue(summary(total: 100, month: 0, monthFinished: 3).hasMonthActivity)
    }

    // MARK: - ListeningReport（struct 只带字段，无 computed）

    func testListeningReport_allFieldsRoundtrip() {
        let r = LibraryService.ListeningReport(year: 2026, totalSeconds: 3600,
                                               daysListened: 15, booksFinished: 2,
                                               monthly: [TimeInterval](repeating: 0, count: 12),
                                               currentMonth: 10)
        XCTAssertEqual(r.year, 2026)
        XCTAssertEqual(r.totalSeconds, 3600)
        XCTAssertEqual(r.daysListened, 15)
        XCTAssertEqual(r.booksFinished, 2)
        XCTAssertEqual(r.monthly.count, 12)
        XCTAssertEqual(r.currentMonth, 10)
    }
}

/// ListeningDay 是「我」页柱状图的一天，Identifiable by date；seconds 允许为 0
/// （没听的那天也要占一格）。
final class ListeningDayTests: XCTestCase {
    func testId_isDate() {
        let d = Date(timeIntervalSince1970: 12345)
        XCTAssertEqual(ListeningDay(date: d, seconds: 60).id, d)
    }

    func testZeroSecondsDayIsStillAValidEntry() {
        let d = Date()
        let day = ListeningDay(date: d, seconds: 0)
        XCTAssertEqual(day.seconds, 0)
        XCTAssertEqual(day.id, d)
    }
}
