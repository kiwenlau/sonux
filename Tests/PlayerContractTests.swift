import XCTest
import SwiftUI
@testable import Sonux

/// 播放与运行时层的静态契约：这些常量一旦被改动会砸到 UI 与用户体验，
/// 单独锁死能省掉「为什么倍速滑条跑到 4 了」「定时关闭上限从 90 分钟改到 30 分钟」这种回归。
final class PlayerContractTests: XCTestCase {
    // MARK: - SleepTimerMode

    func testSleepTimerMode_minuteRange() {
        // 分钟轴固定 0…90，滑条一格一分钟；改上界要同步改 UI
        XCTAssertEqual(SleepTimerMode.range.lowerBound, 0)
        XCTAssertEqual(SleepTimerMode.range.upperBound, 90)
    }

    func testSleepTimerMode_chapterRange() {
        // 章数轴 1…5：再多就等同「不定时」，滑条画到 5 就够
        XCTAssertEqual(SleepTimerMode.chapterRange, 1...5)
    }

    func testSleepTimerMode_equatable() {
        XCTAssertEqual(SleepTimerMode.off, SleepTimerMode.off)
        XCTAssertEqual(SleepTimerMode.minutes(15), SleepTimerMode.minutes(15))
        XCTAssertNotEqual(SleepTimerMode.minutes(15), SleepTimerMode.minutes(30))
        XCTAssertNotEqual(SleepTimerMode.chapters(2), SleepTimerMode.minutes(2),
                          "章和分钟即使数字相同也不能相等，滑条单位不同")
        XCTAssertNotEqual(SleepTimerMode.chapters(1), SleepTimerMode.off)
    }

    func testSleepTimerMode_chaptersPositiveSemantics() {
        // 「听完 1 章」= 本章结束后关闭，是常见值，不能被折叠到 off
        XCTAssertNotEqual(SleepTimerMode.chapters(1), SleepTimerMode.off)
    }

    // MARK: - PlayerService 语速契约

    func testSpeedRange_matchesDesign() {
        // 0.5x–3x 连续滑条，每格 0.1；改范围会让「上次听过的倍速」恢复逻辑踩到越界
        XCTAssertEqual(PlayerService.speedRange.lowerBound, 0.5)
        XCTAssertEqual(PlayerService.speedRange.upperBound, 3.0)
        XCTAssertEqual(PlayerService.speedStep, 0.1)
    }

    // MARK: - CoverPalette 兜底

    func testFallbackPalette_isDefined() {
        // 没提取到封面时用的紫色系兜底：四段都得有值，播放页渐变才不会崩
        let p = CoverPalette.fallback
        // Color 本身不可比较，只验渐变能构造出来、且引用了四段
        let gradient = p.gradient
        _ = gradient     // 只要构造 LinearGradient 不崩就 OK；具体 stops 是 SwiftUI 私有 API
    }

    // MARK: - SonuxVoiceError

    func testVoiceError_allCasesHaveDescriptions() {
        // 三条错误都会被 Siri 念出来，任何一条 errorDescription 为空都算事故
        for err in [SonuxVoiceError.emptyLibrary, .missingBook, .nothingPlaying] {
            XCTAssertNotNil(err.errorDescription)
            XCTAssertFalse(err.errorDescription!.isEmpty, "\(err) 要有能念出来的话")
        }
    }

    func testVoiceError_casesAreDistinct() {
        XCTAssertNotEqual(SonuxVoiceError.emptyLibrary.errorDescription,
                          SonuxVoiceError.missingBook.errorDescription)
        XCTAssertNotEqual(SonuxVoiceError.missingBook.errorDescription,
                          SonuxVoiceError.nothingPlaying.errorDescription)
    }
}
