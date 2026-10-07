import XCTest
@testable import Sonux

/// ProgressPolicy 全是无副作用静态方法：三个阈值常量决定了「未开始 / 已完成 / 续播回退」的边界。
final class ProgressPolicyTests: XCTestCase {
    func testConstantsMatchDesignValues() {
        XCTAssertEqual(ProgressPolicy.epsilon, 3)
        XCTAssertEqual(ProgressPolicy.completionThreshold, 15)
        XCTAssertEqual(ProgressPolicy.resumeRewind, 5)
    }

    // MARK: - isStarted

    func testIsStarted_ignoresAnythingWithinEpsilon() {
        XCTAssertFalse(ProgressPolicy.isStarted(0))
        XCTAssertFalse(ProgressPolicy.isStarted(1))
        XCTAssertFalse(ProgressPolicy.isStarted(3))     // 边界值本身不算开始（time > epsilon 才成立）
    }

    func testIsStarted_truePastEpsilon() {
        XCTAssertTrue(ProgressPolicy.isStarted(3.0001))
        XCTAssertTrue(ProgressPolicy.isStarted(30))
    }

    // MARK: - isFinished

    func testIsFinished_requiresPositiveDuration() {
        // duration == 0 无论 time 多少都不算播完，避免刚扫到没有长度的章被判成完成
        XCTAssertFalse(ProgressPolicy.isFinished(time: 0, duration: 0))
        XCTAssertFalse(ProgressPolicy.isFinished(time: 100, duration: 0))
    }

    func testIsFinished_withinCompletionThresholdNearEnd() {
        XCTAssertTrue(ProgressPolicy.isFinished(time: 100, duration: 100))
        XCTAssertTrue(ProgressPolicy.isFinished(time: 90, duration: 100))    // 差 10 秒 ≤ 15
        XCTAssertTrue(ProgressPolicy.isFinished(time: 85, duration: 100))    // 差 15 秒 = 阈值，边界仍算完成
    }

    func testIsFinished_falseWhenFarFromEnd() {
        XCTAssertFalse(ProgressPolicy.isFinished(time: 84.9, duration: 100)) // 差 15.1 秒 > 15
        XCTAssertFalse(ProgressPolicy.isFinished(time: 0, duration: 100))
    }

    // MARK: - resumeTime

    func testResumeTime_finishedChapterRestartsFromZero() {
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 100, duration: 100), 0)
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 90, duration: 100, rewind: false), 0)
    }

    func testResumeTime_rewindsFiveSecondsWhenStarted() {
        // 停在 30 秒、章长 600 秒：既没播完也应往回退 5 秒找语感
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 30, duration: 600), 25)
    }

    func testResumeTime_doesNotRewindNearChapterHead() {
        // time ≤ 5 时不回退，否则会得到负数或 0，反而把「刚开个头」的用户拽回原点
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 0, duration: 600), 0)
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 3, duration: 600), 3)
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 5, duration: 600), 5)
    }

    func testResumeTime_rewindFalseKeepsExactPosition() {
        // 连播切章：人没离开，不该被回拽
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 30, duration: 600, rewind: false), 30)
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 300, duration: 600, rewind: false), 300)
    }

    func testResumeTime_boundaryFiveSeconds() {
        // 恰好 5 秒：条件 time > resumeRewind 为假，保持不动
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 5, duration: 600), 5)
        // 5.001 秒：进入回退分支
        XCTAssertEqual(ProgressPolicy.resumeTime(time: 5.001, duration: 600), 0.001, accuracy: 1e-6)
    }
}
