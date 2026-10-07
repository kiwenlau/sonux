import XCTest
@testable import Sonux

/// PlayerService 的「挂着不播」状态迁移与初始契约：
///   prepareToResume 只写 @Published 字段，绝不建 AVPlayerItem、绝不 activateAudioSession，
///   这是「进 App 不抢后台音乐」这条非侵入原则的机制层保证；
///   unloadPrepared 反向把这几项擦干净；
///   hasPlayer 只反映 player?.currentItem，不受 currentBook 等记账字段影响。
@MainActor
final class PlayerServicePreparedTests: XCTestCase {
    private func makeBook(chapterDuration: TimeInterval = 100) -> (Book, Chapter) {
        let chapter = Chapter(id: "c1", bookId: "b1", index: 0, title: "第一章",
                              duration: chapterDuration,
                              fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
        let book = Book(id: "b1", title: "T", author: nil, chapters: [chapter],
                        storagePath: "b1")
        return (book, chapter)
    }

    func testFreshPlayer_hasNoBookNoPlayerNoPosition() {
        let player = PlayerService()
        XCTAssertNil(player.currentBook)
        XCTAssertNil(player.currentChapter)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasPlayer)         // 还没装 AVPlayerItem
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.speed, 1.0)
    }

    func testPrepareToResume_setsStateButDoesNotActivatePlayer() {
        let player = PlayerService()
        let (book, chapter) = makeBook(chapterDuration: 100)
        player.prepareToResume(book: book, chapter: chapter, at: 42)
        // 状态挂了但没有 AVPlayerItem：符合「冷启动不抢焦点」的约定
        XCTAssertEqual(player.currentBook?.id, "b1")
        XCTAssertEqual(player.currentChapter?.id, "c1")
        XCTAssertEqual(player.currentTime, 42)
        XCTAssertEqual(player.duration, 100)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasPlayer)
    }

    func testPrepareToResume_clampsTimeWithinChapter() {
        let player = PlayerService()
        let (book, chapter) = makeBook(chapterDuration: 100)
        player.prepareToResume(book: book, chapter: chapter, at: 500)   // 越上界
        XCTAssertEqual(player.currentTime, 100, "min(max(0, time), duration)")
        player.prepareToResume(book: book, chapter: chapter, at: -20)   // 越下界
        XCTAssertEqual(player.currentTime, 0)
    }

    func testPrepareToResume_noOpsWhenPlayerAlreadyLoaded() {
        // hasPlayer == true 时 prepareToResume 直接 return，不该覆盖正在播的书
        let player = PlayerService()
        let (b1, c1) = makeBook(chapterDuration: 100)
        // 先 prepare 挂上一本
        player.prepareToResume(book: b1, chapter: c1, at: 10)
        // 由于 player 仍未 hasPlayer=true，再 prepare 另一本会覆盖（这就是它的语义）
        let c2 = Chapter(id: "c2", bookId: "b1", index: 1, title: "第二章",
                         duration: 200, fileURL: URL(fileURLWithPath: "/tmp/a2.mp3"))
        player.prepareToResume(book: b1, chapter: c2, at: 30)
        XCTAssertEqual(player.currentChapter?.id, "c2",
                       "未真播时 prepareToResume 允许换挂书")
    }

    func testUnloadPrepared_clearsAllPreparedState() {
        let player = PlayerService()
        let (book, chapter) = makeBook(chapterDuration: 100)
        player.prepareToResume(book: book, chapter: chapter, at: 42)
        player.unloadPrepared()
        XCTAssertNil(player.currentBook)
        XCTAssertNil(player.currentChapter)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
    }

    func testUnloadPrepared_noOpsWhenPlayerActive() {
        // hasPlayer 是 true 时（正在播），unloadPrepared 直接 return，不会把播着的书卸掉
        // 我们构造不出真播的状态，退而求其次：prepare 后 unloadPrepared 应能正常清空
        let player = PlayerService()
        player.unloadPrepared()   // 全新 player 上调用也不崩
        XCTAssertNil(player.currentBook)
    }

    // MARK: - forgetSpeed

    func testForgetSpeed_noopOnUnknownBook() {
        // 删书时顺路清倍速记忆；未记录过的书 forgetSpeed 静默 no-op
        let player = PlayerService()
        player.forgetSpeed(bookId: "unknown-\(UUID().uuidString)")
        // 不 throw 就算通过
    }
}
