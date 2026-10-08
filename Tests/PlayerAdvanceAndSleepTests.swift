import XCTest
@testable import Sonux

/// PlayerService 的「切章 / 定位 / 定时换算」读侧与小动作契约——延续 Phase 4 的思路：
/// 只跑不建 AVPlayerItem、不 activateAudioSession、不起 Timer 的路径。
///
/// 注意：prepareToResume 会用 `rememberedSpeed(forBook:)` 从 UserDefaults 读回上次那本书的倍速，
/// 所以每个用例都用**唯一 bookId**，免得 setSpeed 写进去的 2.0 串染到别的用例（真实踩过一次：
/// 双速用例把 book "b" 的速度记进 UserDefaults，后面同样用 "b" 的用例 sleepMinutes 直接减半）。
@MainActor
final class PlayerAdvanceAndSleepTests: XCTestCase {
    private func uniqueBook(_ count: Int, duration: TimeInterval = 100) -> Book {
        let bookId = "b-\(UUID().uuidString)"
        let chapters = (0..<count).map {
            Chapter(id: "\(bookId)-c\($0)", bookId: bookId, index: $0, title: "第\($0)章",
                    duration: duration, fileURL: URL(fileURLWithPath: "/tmp/\($0).mp3"))
        }
        return Book(id: bookId, title: "T", author: nil, chapters: chapters, storagePath: bookId)
    }

    private func prepared(_ count: Int = 3, at chapterIndex: Int = 0,
                          time: TimeInterval = 0, speed: Float = 1.0) -> (PlayerService, Book) {
        let p = PlayerService()
        let book = uniqueBook(count)
        p.prepareToResume(book: book, chapter: book.chapters[chapterIndex], at: time)
        if speed != 1.0 { p.setSpeed(speed) }
        return (p, book)
    }

    private func chapterId(_ book: Book, _ index: Int) -> String { book.chapters[index].id }

    // MARK: - nextChapter / previousChapter（挂着未播时纯指针移动）

    func testNextChapter_advancesToFollowingChapter() {
        let (p, book) = prepared(3, at: 0)
        p.nextChapter()
        XCTAssertEqual(p.currentChapter?.id, chapterId(book, 1))
    }

    func testNextChapter_pastLastChapterStops() {
        // advance 里 offset > 0 且没有下一章 → stop()，currentBook/Chapter 被清空
        let (p, _) = prepared(3, at: 2)
        p.nextChapter()
        XCTAssertNil(p.currentChapter, "最后一章点下一章 = 整本播完，播放器放手")
        XCTAssertNil(p.currentBook)
    }

    func testPreviousChapter_withinEpsilonGoesToPrevious() {
        // 停在开头（≤ 3 秒）→ 退到上一章
        let (p, book) = prepared(3, at: 1, time: 2)
        p.previousChapter()
        XCTAssertEqual(p.currentChapter?.id, chapterId(book, 0))
    }

    func testPreviousChapter_pastEpsilonReturnsToChapterHead() {
        // 播过 3 秒 → 「上一章」先回到本章开头，不真退章（微信听书同款手感）
        let (p, book) = prepared(3, at: 1, time: 20)
        p.previousChapter()
        XCTAssertEqual(p.currentChapter?.id, chapterId(book, 1), "应留在本章")
        XCTAssertEqual(p.currentTime, 0, "回到章头")
    }

    func testPreviousChapter_atFirstChapterPastEpsilonResetsTime() {
        // 第一章且播过 3 秒 → 回本章头（seek 0），不退到不存在的上一章
        let (p, book) = prepared(3, at: 0, time: 30)
        p.previousChapter()
        XCTAssertEqual(p.currentChapter?.id, chapterId(book, 0))
        XCTAssertEqual(p.currentTime, 0)
    }

    // MARK: - seek / skip 夹紧

    func testSeek_clampsToChapterDuration() {
        let (p, _) = prepared(1, at: 0, time: 0)
        p.seek(to: 500)   // 章长 100，越上界夹到 100
        XCTAssertEqual(p.currentTime, 100)
        p.seek(to: -50)   // 越下界夹到 0
        XCTAssertEqual(p.currentTime, 0)
    }

    func test_skip_forwardAndBackward() {
        let (p, _) = prepared(1, at: 0, time: 50)
        p.skip(by: 30)
        XCTAssertEqual(p.currentTime, 80)
        p.skip(by: -100)  // 80-100 = -20 → 夹到 0
        XCTAssertEqual(p.currentTime, 0)
    }

    // MARK: - sleepMinutes / sleepSecondsLeft（纯算术，不起 Timer）

    func testSleepMinutes_noBookReturnsZero() {
        XCTAssertEqual(PlayerService().sleepMinutes(forChapters: 3), 0)
    }

    func testSleepMinutes_singleChapterAtOneX() {
        // 挂了 100 s 的章、从 0 开始：听完 1 章 = 100 s 音频 = 100/60 分钟（1x）
        let (p, _) = prepared(1, at: 0, time: 0)
        XCTAssertEqual(p.sleepMinutes(forChapters: 1), 100.0 / 60.0, accuracy: 1e-6)
    }

    func testSleepMinutes_doubleSpeedHalvesWallClock() {
        let (p, _) = prepared(1, at: 0, time: 0, speed: 2.0)
        XCTAssertEqual(p.sleepMinutes(forChapters: 1), 100.0 / 60.0 / 2.0, accuracy: 1e-6)
    }

    func testSleepMinutes_accountsForAlreadyListenedPart() {
        // 100 s 的章听到 40 s → 本章还剩 60 s；听完 1 章 = 60/60 = 1 分钟
        let (p, _) = prepared(1, at: 0, time: 40)
        XCTAssertEqual(p.sleepMinutes(forChapters: 1), 1.0, accuracy: 1e-6)
    }

    func testSleepMinutes_multiChapterSumsFollowingChapters() {
        // 3 章各 100 s，从第 0 章 0 秒起听完 3 章 = 300 s 音频 = 5 分钟（1x）
        let (p, _) = prepared(3, at: 0, time: 0)
        XCTAssertEqual(p.sleepMinutes(forChapters: 3), 300.0 / 60.0, accuracy: 1e-6)
    }

    func testSleepMinutes_offEndOfChapterSkipsIt() {
        // 100 s 章听到 99.5 s → 本章剩余 < 1 s 视为已完，往后数一章；单章书没有下一章 → 0
        let (p, _) = prepared(1, at: 0, time: 99.5)
        XCTAssertEqual(p.sleepMinutes(forChapters: 1), 0, accuracy: 1e-6)
    }

    func testSleepSecondsLeft_offIsZero() {
        XCTAssertEqual(prepared().0.sleepSecondsLeft, 0)
    }

    // MARK: - currentPosition 随状态更新

    func testCurrentPosition_reflectsChapterAndTime() {
        let (p, book) = prepared(3, at: 1, time: 55)
        let pos = p.currentPosition()
        XCTAssertEqual(pos?.chapterId, chapterId(book, 1))
        XCTAssertEqual(pos?.time ?? -1, 55, accuracy: 1e-6)
    }

    // MARK: - defaultSleepChapters

    func testDefaultSleepChapters_isWithinChapterRange() {
        // 没记过就是 1；记过越界值也夹回 chapterRange（1...5）
        XCTAssertTrue(SleepTimerMode.chapterRange.contains(PlayerService().defaultSleepChapters))
    }

    // MARK: - forgetSpeed 清掉唯一 bookId 的记忆

    func testForgetSpeed_clearsRememberedSpeedForBook() {
        let (p, book) = prepared(1, at: 0, time: 0, speed: 1.5)
        // setSpeed(1.5) 已写进 UserDefaults；forgetSpeed 后重开同样 id 应回 1.0
        XCTAssertEqual(p.speed, 1.5)
        p.forgetSpeed(bookId: book.id)
        let reopened = PlayerService()
        reopened.prepareToResume(book: book, chapter: book.chapters[0], at: 0)
        XCTAssertEqual(reopened.speed, 1.0)
    }
}
