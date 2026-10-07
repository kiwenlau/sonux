import XCTest
@testable import Sonux

/// 覆盖 TimeFormat 里的纯函数：time 与 speed 都不落文案，可跨语言稳定断言。
/// duration 会走 LF/L 取词、结果随宿主语言变化，不在这里做值断言。
final class TimeFormatTests: XCTestCase {
    func testTime_subMinuteOmitsHours() {
        XCTAssertEqual(TimeFormat.time(0), "0:00")
        XCTAssertEqual(TimeFormat.time(9), "0:09")
        XCTAssertEqual(TimeFormat.time(59), "0:59")
    }

    func testTime_minuteRange() {
        XCTAssertEqual(TimeFormat.time(60), "1:00")
        XCTAssertEqual(TimeFormat.time(85), "1:25")
        XCTAssertEqual(TimeFormat.time(599), "9:59")
        XCTAssertEqual(TimeFormat.time(600), "10:00")
        XCTAssertEqual(TimeFormat.time(3599), "59:59")
    }

    func testTime_hourRangeUsesThreeSegments() {
        XCTAssertEqual(TimeFormat.time(3600), "1:00:00")
        XCTAssertEqual(TimeFormat.time(3660), "1:01:00")
        XCTAssertEqual(TimeFormat.time(3725), "1:02:05")
        XCTAssertEqual(TimeFormat.time(36000), "10:00:00")
    }

    func testTime_clampsNegativeAndRounds() {
        // 负数按 0 处理，非整秒四舍五入到最近整秒
        XCTAssertEqual(TimeFormat.time(-10), "0:00")
        XCTAssertEqual(TimeFormat.time(0.4), "0:00")
        XCTAssertEqual(TimeFormat.time(0.6), "0:01")
        XCTAssertEqual(TimeFormat.time(59.7), "1:00")
    }

    func testSpeed_integerValueDropsDecimal() {
        XCTAssertEqual(TimeFormat.speed(1.0), "1")
        XCTAssertEqual(TimeFormat.speed(2.0), "2")
        XCTAssertEqual(TimeFormat.speed(1.0), "1")
    }

    func testSpeed_keepsSingleDecimalDigit() {
        // 输入本身就是「以 0.1 为步进」的四倍速档位；实测 1.2/1.5/1.75 都保留一位小数
        XCTAssertEqual(TimeFormat.speed(1.2), "1.2")
        XCTAssertEqual(TimeFormat.speed(1.5), "1.5")
        XCTAssertEqual(TimeFormat.speed(0.9), "0.9")
        // 1.75 * 10 = 17.5，Float 精算下 .rounded() 取 18 → 1.8
        XCTAssertEqual(TimeFormat.speed(1.75), "1.8")
    }

    func testSpeed_roundsToNearestTenth() {
        XCTAssertEqual(TimeFormat.speed(1.23), "1.2")
        XCTAssertEqual(TimeFormat.speed(1.28), "1.3")
        XCTAssertEqual(TimeFormat.speed(0.95), "1")   // 0.95*10=9.5→10→1.0→整数分支
    }

    func testSpeed_x1x2x3x5x7AreCanonicalLabels() {
        // 倍速滑条常用档位（1、1.25、1.5、2、3、5、7），断言显示稳定
        XCTAssertEqual(TimeFormat.speed(1.0), "1")
        XCTAssertEqual(TimeFormat.speed(2.0), "2")
        XCTAssertEqual(TimeFormat.speed(3.0), "3")
        XCTAssertEqual(TimeFormat.speed(5.0), "5")
        XCTAssertEqual(TimeFormat.speed(7.0), "7")
    }

    // duration 依赖本地化取词，只断言「不会为空」保证不会崩；具体文案交给 UI 验收
    func testDuration_neverEmpty() {
        for seconds in [0, 30, 60, 3600, 3660.0] {
            XCTAssertFalse(TimeFormat.duration(TimeInterval(seconds)).isEmpty,
                           "duration(\(seconds)) 应该返回有内容的字符串")
        }
    }
}

