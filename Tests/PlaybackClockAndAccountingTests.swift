import XCTest
import Combine
@testable import Sonux

/// 「性能：每秒一次的全局重绘」这一条的落点测试。
///
/// 两件事要钉住：
///   1. 每秒都在走的读数（本章内已播秒、定时关闭剩余秒）住在 PlaybackClock 上，不再挂在
///      PlayerService 的 @Published 上——否则观察 PlayerService 的每一页每秒都要重算 body，
///      而 SwiftUI 观察 ObservableObject 不分键路径，躲不开。
///   2. 向书库结账（记位置 + 攒下的收听秒数 + 落盘）按 30 秒节流，暂停/停止/切章/拖进度当场结清，
///      账没动时一趟都不写。
///
/// 与 PlayerAdvanceAndSleepTests 同一纪律：只跑不建 AVPlayerItem、不 activateAudioSession、
/// 不起 Timer 的路径，所以节流判据走 `shouldAccountProgress` 这条纯函数。
@MainActor
final class PlaybackClockAndAccountingTests: XCTestCase {
    private func prepared(time: TimeInterval = 0) -> PlayerService {
        let p = PlayerService()
        let bookId = "clock-\(UUID().uuidString)"
        let chapter = Chapter(id: "\(bookId)-c0", bookId: bookId, index: 0, title: "第一章",
                              duration: 600, fileURL: URL(fileURLWithPath: "/tmp/clock.mp3"))
        let book = Book(id: bookId, title: "T", author: nil, chapters: [chapter], storagePath: bookId)
        p.prepareToResume(book: book, chapter: chapter, at: time)
        return p
    }

    /// 数一数某个观察对象发布了几次
    private func publisher(_ target: some ObservableObject) -> (count: () -> Int, cancel: () -> Void) {
        var count = 0
        let cancellable = target.objectWillChange.sink { _ in count += 1 }
        return ({ count }, { cancellable.cancel() })
    }

    // MARK: - PlaybackClock 自身契约

    func testClock_publishesOnNewValue() {
        let clock = PlaybackClock()
        let watch = publisher(clock)
        clock.setCurrentTime(42)
        XCTAssertEqual(watch.count(), 1, "读数变了要发布，跟着秒跳的界面才知道")
        watch.cancel()
    }

    func testClock_doesNotPublishSameValue() {
        let clock = PlaybackClock()
        clock.setCurrentTime(42)
        let watch = publisher(clock)
        clock.setCurrentTime(42)
        XCTAssertEqual(watch.count(), 0, "同值不发布：进度计时器每秒都走这一趟")
        watch.cancel()
    }

    func testClock_keepsBothReadings() {
        let clock = PlaybackClock()
        clock.setCurrentTime(7)
        clock.setSleepRemaining(1_800)
        XCTAssertEqual(clock.currentTime, 7)
        XCTAssertEqual(clock.sleepRemaining, 1_800)
    }

    // MARK: - 会走的读数不再惊动 PlayerService

    func testClockTick_doesNotPublishPlayerService() {
        let p = prepared(time: 10)
        let watchPlayer = publisher(p)
        let watchClock = publisher(p.clock)

        p.clock.setCurrentTime(99)

        XCTAssertEqual(watchPlayer.count(), 0,
                       "每秒一跳的秒数不能发布 PlayerService，否则每一页每秒重算一次 body")
        XCTAssertEqual(watchClock.count(), 1, "同一个值只惊动观察时钟的那几块界面")
        XCTAssertEqual(p.currentTime, 99, "读侧仍从 player 取值，界面与测试都不用改口径")
        watchPlayer.cancel()
        watchClock.cancel()
    }

    func testSleepRemainingLivesOnClock() {
        let p = prepared()
        p.clock.setSleepRemaining(600)
        XCTAssertEqual(p.sleepSecondsLeft, 600, "分钟定时的读数由时钟带着，换算仍走 player")
        XCTAssertEqual(p.clock.sleepRemaining, 600)

        let watchPlayer = publisher(p)
        p.clock.setSleepRemaining(599)
        XCTAssertEqual(watchPlayer.count(), 0, "秒表每秒减一不该重绘全体视图")
        watchPlayer.cancel()
    }

    func testRealTransitionsStillPublishPlayerService() {
        // 反面：拆走秒数不能把真状态变化也一起拆没了——变速、切章仍要发布，界面才跟得上
        let p = prepared()
        let watch = publisher(p)
        p.setSpeed(1.5)
        XCTAssertGreaterThan(watch.count(), 0)
        watch.cancel()
    }

    // MARK: - 结账判据（30 秒窗口 + 当场结清 + 没账可结）

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func secondsAgo(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testShouldAccount_firstAccountingAlwaysWrites() {
        XCTAssertTrue(PlayerService.shouldAccountProgress(now: now, last: nil, pendingSeconds: 1,
                                                          positionChanged: false, force: false))
    }

    func testShouldAccount_insideWindowWaits() {
        XCTAssertFalse(PlayerService.shouldAccountProgress(now: now, last: secondsAgo(10),
                                                           pendingSeconds: 1, positionChanged: true,
                                                           force: false),
                       "播放中每 30 秒才结一次账，不是每秒")
    }

    func testShouldAccount_atWindowEdgeWrites() {
        XCTAssertTrue(PlayerService.shouldAccountProgress(now: now,
                                                          last: secondsAgo(PlayerService.progressAccountingInterval),
                                                          pendingSeconds: 1, positionChanged: true,
                                                          force: false))
    }

    func testShouldAccount_forcedWritesImmediately() {
        XCTAssertTrue(PlayerService.shouldAccountProgress(now: now, last: secondsAgo(1),
                                                          pendingSeconds: 0, positionChanged: true,
                                                          force: true),
                       "暂停、停止、切章、拖进度这些时刻当场落盘")
    }

    func testShouldAccount_nothingChangedNeverWrites() {
        // 暂停期间进度计时器还在每秒走这一趟，账没动就一次都不写
        XCTAssertFalse(PlayerService.shouldAccountProgress(now: now, last: secondsAgo(1),
                                                           pendingSeconds: 0, positionChanged: false,
                                                           force: true))
    }

    func testProgressAccountingIntervalIsCoarse() {
        XCTAssertGreaterThanOrEqual(PlayerService.progressAccountingInterval, 30,
                                    "落盘间隔再短就回到每秒全量写盘的老问题")
    }

    // MARK: - 历史表：一次建索引，不再逐条线性扫书库

    private func makeLibrary() throws -> (docs: URL, appSupport: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sonux-clock-\(UUID().uuidString)", isDirectory: true)
        let docs = base.appendingPathComponent("Documents", isDirectory: true)
        let appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        // Data.write 不会顺手建中间目录，AppSupport 得自己先建出来
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("MyBook", isDirectory: true),
                                                withIntermediateDirectories: true)
        try """
        [{"id":"dir:MyBook","title":"我的书","author":"某作者","storagePath":"MyBook","chapters":[
          {"path":"MyBook/01.mp3","title":"第一章","duration":100}
        ]}]
        """.data(using: .utf8)!.write(to: appSupport.appendingPathComponent("library-snapshot.json"))
        return (docs, appSupport)
    }

    func testHistoryEntries_dropsBooksNoLongerInLibrary() throws {
        let (docs, appSupport) = try makeLibrary()
        // 一本已删除的书还留在 lastPlayed 里：历史页要把它剔掉，不能崩也不能出空卡
        try """
        {"books":{"dir:MyBook":{"chapterId":"MyBook/01.mp3","time":50},
                  "dir:Gone":{"chapterId":"Gone/01.mp3","time":10}},
         "chapters":{"MyBook/01.mp3":{"chapterId":"MyBook/01.mp3","time":50}},
         "lastPlayed":{"dir:MyBook":1000,"dir:Gone":2000}}
        """.data(using: .utf8)!.write(to: appSupport.appendingPathComponent("progress.json"))

        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        let entries = lib.historyEntries()
        XCTAssertEqual(entries.map(\.book.id), ["dir:MyBook"])
        XCTAssertEqual(entries.first?.position?.time, 50)
        try? FileManager.default.removeItem(at: docs.deletingLastPathComponent())
    }

    func testHistoryEntries_newestFirst() throws {
        let (docs, appSupport) = try makeLibrary()
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        lib.recordPosition(PlayPosition(chapterId: "MyBook/01.mp3", time: 10), bookId: "dir:MyBook")
        let entries = lib.historyEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.lastPlayed, lib.lastPlayedDates["dir:MyBook"])
        try? FileManager.default.removeItem(at: docs.deletingLastPathComponent())
    }
}
