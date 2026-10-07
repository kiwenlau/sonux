import XCTest
@testable import Sonux

/// SilenceGaps 是纯静态：把字幕行的空档映射成 [SilenceGap]，再用二分定位「此刻能不能跳」。
/// 三个 slack 常量（tailSlack / leadSlack / chapterTailGuard）都在断言里显式使用，改数值就能立刻反映到用例。
final class SilenceGapsTests: XCTestCase {
    private func line(_ start: TimeInterval, _ end: TimeInterval, text: String = "t") -> TranscriptLine {
        TranscriptLine(start: start, end: end, text: text)
    }

    // MARK: - 常量

    func testConstants() {
        XCTAssertEqual(SilenceGaps.tailSlack, 0.25)
        XCTAssertEqual(SilenceGaps.leadSlack, 0.25)
        XCTAssertEqual(SilenceGaps.chapterTailGuard, 0.5)
    }

    // MARK: - gaps(from:chapterDuration:)

    func testGaps_noLinesOrNoDurationReturnsEmpty() {
        XCTAssertEqual(SilenceGaps.gaps(from: [], chapterDuration: 100), [])
        XCTAssertEqual(SilenceGaps.gaps(from: [line(1, 2)], chapterDuration: 0), [])
    }

    func testGaps_leadingSilenceOnly() {
        // 章头到第一句开口之前算静音，且落地时刻要提前 leadSlack
        let gaps = SilenceGaps.gaps(from: [line(5, 8)], chapterDuration: 10)
        // 只有章头段：第一句 end=8 之后到章尾 (10-0.5)=9.5 之间 8+0.25=8.25 > 9.5 才算，此处 8.25<9.5 但 span=2 也够——
        // 实际断言：span = 10-8 = 2 > 0，from=8.25，to=9.5，所以章尾也有一段
        XCTAssertGreaterThanOrEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0], SilenceGap(from: 0, to: 5 - SilenceGaps.leadSlack, span: 5))
    }

    func testGaps_leadingSilenceSkippedWhenFirstLineStartsTooEarly() {
        // 首句几乎贴着 0 秒开始：不足 leadSlack 就不生成章头静音
        let gaps = SilenceGaps.gaps(from: [line(0.1, 5)], chapterDuration: 10)
        XCTAssertFalse(gaps.contains { $0.from == 0 })
    }

    func testGaps_interLineSilence() {
        // 两句之间有 3 秒空档，应生成一段静音
        let gaps = SilenceGaps.gaps(from: [line(0, 2), line(5, 7)], chapterDuration: 10)
        let mid = gaps.first { $0.from > 0 && $0.to < 10 - SilenceGaps.chapterTailGuard }
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid?.from, 2 + SilenceGaps.tailSlack)
        XCTAssertEqual(mid?.to, 5 - SilenceGaps.leadSlack)
        XCTAssertEqual(mid?.span, 3)
    }

    func testGaps_overlappingLinesDoNotProduceGap() {
        // 转写时间戳偶有重叠：下一句 start 早于上一句 end → span ≤ 0 → 不算静音
        let gaps = SilenceGaps.gaps(from: [line(0, 5), line(3, 8)], chapterDuration: 10)
        XCTAssertFalse(gaps.contains { $0.from == 5 + SilenceGaps.tailSlack })
    }

    func testGaps_trailingSilence() {
        let gaps = SilenceGaps.gaps(from: [line(0, 2)], chapterDuration: 100)
        // 章尾段：from=last.end+tailSlack，to=duration-chapterTailGuard
        let tail = gaps.last
        XCTAssertEqual(tail?.from, 2 + SilenceGaps.tailSlack)
        XCTAssertEqual(tail?.to, 100 - SilenceGaps.chapterTailGuard)
        XCTAssertEqual(tail?.span, 100 - 2)
    }

    func testGaps_trailingSkippedWhenChapterEndsTooClose() {
        // 章尾离最后一句收声不足 tailSlack + chapterTailGuard → 不生成 tail 段
        let gaps = SilenceGaps.gaps(from: [line(0, 10)], chapterDuration: 10.2)
        XCTAssertNotEqual(gaps.last?.from, 10 + SilenceGaps.tailSlack)
    }

    func testGaps_sortedAscendingByFrom() {
        let gaps = SilenceGaps.gaps(from: [line(3, 4), line(6, 7), line(10, 11)], chapterDuration: 20)
        XCTAssertEqual(gaps.map(\.from), gaps.map(\.from).sorted())
    }

    // MARK: - skipTarget(in:at:minGap:)

    private func sampleGaps() -> [SilenceGap] {
        [SilenceGap(from: 1, to: 3, span: 2.5),
         SilenceGap(from: 5, to: 7, span: 3),
         SilenceGap(from: 10, to: 11, span: 0.8)]
    }

    func testSkipTarget_emptyGapsAlwaysNil() {
        XCTAssertNil(SilenceGaps.skipTarget(in: [], at: 2, minGap: 1))
    }

    func testSkipTarget_beforeFirstGapReturnsNil() {
        // 落在第一段静音之前——二分会把 low 停在 0，函数必须自己识别越界
        XCTAssertNil(SilenceGaps.skipTarget(in: sampleGaps(), at: 0.5, minGap: 0.5))
    }

    func testSkipTarget_insideGapReturnsTarget() {
        XCTAssertEqual(SilenceGaps.skipTarget(in: sampleGaps(), at: 2, minGap: 1), 3)
        XCTAssertEqual(SilenceGaps.skipTarget(in: sampleGaps(), at: 6, minGap: 1), 7)
    }

    func testSkipTarget_atGapBoundaryUsesHalfOpen() {
        // from 闭、to 开：正好落在 to 上视为「已经跳完」，返回 nil
        XCTAssertNil(SilenceGaps.skipTarget(in: sampleGaps(), at: 3, minGap: 1))
        // 正好落在 from 上算进入静音
        XCTAssertEqual(SilenceGaps.skipTarget(in: sampleGaps(), at: 1, minGap: 1), 3)
    }

    func testSkipTarget_shortGapBelowMinGapReturnsNil() {
        // 第三段 span=0.8：minGap=1 时不跳；minGap=0.5 时能跳
        XCTAssertNil(SilenceGaps.skipTarget(in: sampleGaps(), at: 10.5, minGap: 1))
        XCTAssertEqual(SilenceGaps.skipTarget(in: sampleGaps(), at: 10.5, minGap: 0.5), 11)
    }

    func testSkipTarget_betweenTwoGapsReturnsNil() {
        // time=4 落在第一段之后、第二段之前，二分把它归给第一段但 time < gap.from 不成立、time ≥ gap.to 成立 → nil
        XCTAssertNil(SilenceGaps.skipTarget(in: sampleGaps(), at: 4, minGap: 1))
    }

    func testSkipTarget_afterLastGapFallsIntoLast() {
        // 落在最后一段之后的时间（比如 15）：二分会把 low 停在最后一段，但 time ≥ gap.from、time < gap.to 不成立 → nil
        XCTAssertNil(SilenceGaps.skipTarget(in: sampleGaps(), at: 15, minGap: 1))
    }
}
