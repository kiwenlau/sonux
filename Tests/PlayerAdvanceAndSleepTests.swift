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

    // MARK: - 秒表只在出声时走（暂停中倒计时不能继续掉）

    func testSleepCountdown_frozenWhileNotPlaying() {
        let (p, _) = prepared(1, at: 0, time: 0)
        defer { p.setSleepTimer(.off) }  // 顺带把这一秒一格的 Timer 摘掉
        p.setSleepTimer(.minutes(20))
        for _ in 0..<5 { p.tickSleepCountdown() }
        XCTAssertEqual(p.sleepSecondsLeft, 1200, "没出声就不扣：暂停着还在倒，人回来接着听没多久就被掐掉")
    }

    // MARK: - defaultSleepChapters

    func testDefaultSleepChapters_isWithinChapterRange() {
        // 没书没记过就是 1；某本书记过越界值也夹回 chapterRange（1...5）
        XCTAssertTrue(SleepTimerMode.chapterRange.contains(PlayerService().defaultSleepChapters))
    }

    // MARK: - 每本书各记各的章数（章节长短每本不一样）

    func testSleepChapters_twoBooksDoNotOverwriteEachOther() {
        let p = PlayerService()
        let novel = uniqueBook(1), business = uniqueBook(1)
        p.prepareToResume(book: novel, chapter: novel.chapters[0], at: 0)
        p.setSleepTimer(.chapters(3))
        XCTAssertEqual(p.defaultSleepChapters, 3)
        p.prepareToResume(book: business, chapter: business.chapters[0], at: 0)
        XCTAssertEqual(p.defaultSleepChapters, 1, "换到没调过章数的书，不该带着上一本的 3 章")
        p.setSleepTimer(.chapters(2))
        p.prepareToResume(book: novel, chapter: novel.chapters[0], at: 0)
        XCTAssertEqual(p.defaultSleepChapters, 3, "回到上一本应换回它自己记着的章数")
    }

    func testSleepChapters_surviveNewPlayerServiceAsOnColdLaunch() {
        // 新建 PlayerService 等价于进程重开：UserDefaults 里的 [bookId: 章数] 要读得回来
        let (p, book) = prepared(1, at: 0, time: 0)
        p.setSleepTimer(.chapters(4))
        let reopened = PlayerService()
        reopened.prepareToResume(book: book, chapter: book.chapters[0], at: 0)
        XCTAssertEqual(reopened.defaultSleepChapters, 4)
    }

    func testSleepChapters_stayAfterTurningTimerOff() {
        // 关掉定时只关掉这一次：卡片下次还得是这本书上次调的章数
        let (p, _) = prepared(1, at: 0, time: 0)
        p.setSleepTimer(.chapters(2))
        p.setSleepTimer(.off)
        XCTAssertEqual(p.sleepMode, .off)
        XCTAssertEqual(p.defaultSleepChapters, 2)
    }

    // MARK: - sleepTimerToApply（分钟定时全库一份，杀进程重开照样沿用）

    func testSleepMinutes_armedForAnyBookOnColdLaunch() {
        // setSleepTimer 把分钟数写进 UserDefaults；新建 PlayerService 等价于进程重开，
        // 换一本从没听过的书，第一次出声仍该满额挂上这 20 分钟
        let (p, _) = prepared(1, at: 0, time: 0)
        p.setSleepTimer(.minutes(20))
        let reopened = PlayerService()
        let other = uniqueBook(1)
        reopened.prepareToResume(book: other, chapter: other.chapters[0], at: 0)
        XCTAssertEqual(reopened.sleepTimerToApply?.mode, SleepTimerMode.minutes(20))
        XCTAssertEqual(reopened.sleepTimerToApply?.from ?? -1, 1200, accuracy: 1e-6)
    }

    func testSleepMinutes_turningOffClearsTheMemory() {
        let (p, _) = prepared(1, at: 0, time: 0)
        p.setSleepTimer(.minutes(20))
        p.setSleepTimer(.off)
        XCTAssertNil(PlayerService().sleepTimerToApply, "主动关掉后，下次播放什么都不开")
    }

    func testSleepChapters_neverArmedAutomatically() {
        // 章数定时只把章数留给卡片，不自动挂：自动挂就成了「每 N 章关一次」摘不掉，
        // 还会把记忆的分钟定时压住
        let (p, book) = prepared(1, at: 0, time: 0)
        p.setSleepTimer(.minutes(20))
        p.setSleepTimer(.chapters(2))
        let reopened = PlayerService()
        reopened.prepareToResume(book: book, chapter: book.chapters[0], at: 0)
        XCTAssertNil(reopened.sleepTimerToApply)
        XCTAssertEqual(reopened.defaultSleepChapters, 2, "章数还记着，点卡片就按它挂")
    }

    func testSleepMinutes_unfinishedRemainingWinsOverMemory() {
        let (p, _) = prepared(1, at: 0, time: 0)
        p.setSleepTimer(.minutes(20))
        p.stop()  // 20 分钟没走完就停了：剩下的留给下一次重播
        let later = PlayerService()
        later.setSleepTimer(.minutes(45))  // 之后在别处把记忆改成了 45 分钟
        XCTAssertEqual(p.sleepTimerToApply?.mode, SleepTimerMode.minutes(20), "该接着自己没走完的剩余走，不是按 45 分钟满额重计")
        XCTAssertEqual(PlayerService().sleepTimerToApply?.mode, SleepTimerMode.minutes(45), "手上没剩余时才用记忆的 45 分钟")
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

    // MARK: - 每本书各用各的倍速，且重启后仍是自己那档

    func testSpeed_twoBooksDoNotOverwriteEachOther() {
        let p = PlayerService()
        let novel = uniqueBook(1), business = uniqueBook(1)
        p.prepareToResume(book: novel, chapter: novel.chapters[0], at: 0)
        p.setSpeed(1.8)
        p.prepareToResume(book: business, chapter: business.chapters[0], at: 0)
        XCTAssertEqual(p.speed, 1.0, "换到没设置过的书不该带着上一本的速度")
        p.setSpeed(1.2)
        p.prepareToResume(book: novel, chapter: novel.chapters[0], at: 0)
        XCTAssertEqual(p.speed, 1.8, "回到上一本应换回它自己记着的档")
    }

    func testSpeed_survivesNewPlayerServiceAsOnColdLaunch() {
        // 新建 PlayerService 等价于进程重开：UserDefaults 里的 [bookId: 倍速] 要读得回来
        let (p, book) = prepared(1, at: 0, time: 0, speed: 2.5)
        let reopened = PlayerService()
        reopened.prepareToResume(book: book, chapter: book.chapters[0], at: 0)
        XCTAssertEqual(reopened.speed, 2.5)
    }
}
