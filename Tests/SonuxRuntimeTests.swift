import XCTest
@testable import Sonux

/// SonuxRuntime.shared 是宿主 App 起来时已经建好的单例：library / player 都跑过一遍 init
/// 与 bootstrap，读接口稳定可断言。这一轮只碰「不会真出声」的路径：
///   - start() 幂等
///   - playForVoice 三条错误分支（empty library / missing id）都能给出人话
///   - advanceChapterForVoice 手上没书时抛 nothingPlaying
///   - restoreContinueListening 在无书可挂时不崩
@MainActor
final class SonuxRuntimeTests: XCTestCase {
    func testShared_isSingleton() {
        XCTAssertTrue(SonuxRuntime.shared === SonuxRuntime.shared)
    }

    func testStart_isIdempotent() {
        // 装配闸门 didStart 让第二次调用直接 return，不重跑 bootstrap 与 wireProgress
        SonuxRuntime.shared.start()
        SonuxRuntime.shared.start()
        // 不 throw 就算过
    }

    func testPlayForVoice_throwsMissingBookForUnknownId() {
        let unknown = "nonexistent-\(UUID().uuidString)"
        XCTAssertThrowsError(try SonuxRuntime.shared.playForVoice(bookId: unknown)) { error in
            guard let e = error as? SonuxVoiceError else { return XCTFail("不是 SonuxVoiceError: \(error)") }
            switch e {
            case .missingBook: break
            default: XCTFail("期望 missingBook，实际 \(e)")
            }
        }
    }

    func testPlayForVoice_throwsEmptyLibraryWhenNoBooksAtAll() throws {
        // 单例的 library 从宿主 Documents 扫出来，本机有书时这条路走不到；
        // 只在书库为空时断言（模拟器全新启动/未推书的场景），有书则直接跳过
        guard SonuxRuntime.shared.library.books.isEmpty else {
            throw XCTSkip("书库里已有真书，空库分支留给 CI 全新沙盒触发")
        }
        XCTAssertThrowsError(try SonuxRuntime.shared.playForVoice(bookId: nil)) { error in
            guard let e = error as? SonuxVoiceError else { return XCTFail("不是 SonuxVoiceError: \(error)") }
            switch e {
            case .emptyLibrary: break
            default: XCTFail("期望 emptyLibrary，实际 \(e)")
            }
        }
    }

    func testAdvanceChapterForVoice_throwsNothingPlayingWhenIdle() {
        // 没在播也没挂书 → 切章没有语义落点，直接抛 nothingPlaying
        // 前提是当前 test host 手上没书；若之前有测试挂了书就先卸
        SonuxRuntime.shared.player.unloadPrepared()
        XCTAssertThrowsError(try SonuxRuntime.shared.advanceChapterForVoice(by: 1)) { error in
            guard let e = error as? SonuxVoiceError else { return XCTFail("不是 SonuxVoiceError: \(error)") }
            switch e {
            case .nothingPlaying: break
            default: XCTFail("期望 nothingPlaying，实际 \(e)")
            }
        }
    }

    func testAdvanceChapterForVoice_zeroOffsetAlsoThrows() {
        SonuxRuntime.shared.player.unloadPrepared()
        XCTAssertThrowsError(try SonuxRuntime.shared.advanceChapterForVoice(by: 0))
    }

    func testRestoreContinueListening_isSafeWhenNothingListened() {
        // 冷启动 + 播放历史空：拿不到 latest 就直接 return，不崩
        SonuxRuntime.shared.restoreContinueListening()
    }

    // MARK: - 冷启动直接落到播放页

    /// 给单例挂一本假书（走 prepareToResume，不建 AVPlayerItem、不出声），测完卸回干净状态
    private func withPreparedBook(_ body: () -> Void) {
        let player = SonuxRuntime.shared.player
        let chapter = Chapter(id: "launch-c1", bookId: "launch-b1", index: 0, title: "第一章",
                              duration: 100, fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
        let book = Book(id: "launch-b1", title: "冷启动测试书", author: nil,
                        chapters: [chapter], storagePath: "launch-b1")
        let savedShowPlayer = player.showPlayer
        player.unloadPrepared()
        player.prepareToResume(book: book, chapter: chapter, at: 30)
        body()
        player.unloadPrepared()
        player.showPlayer = savedShowPlayer
    }

    private func withWasPlayingKey(_ value: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SonuxRuntime.wasPlayingKey)
        defaults.removeObject(forKey: SonuxRuntime.wasPlayingKey)
        if let value { defaults.set(value, forKey: SonuxRuntime.wasPlayingKey) }
        body()
        if let saved { defaults.set(saved, forKey: SonuxRuntime.wasPlayingKey) }
        else { defaults.removeObject(forKey: SonuxRuntime.wasPlayingKey) }
    }

    func testRestoreNowPlayingPage_opensWhenLastSessionWasPlaying() {
        withWasPlayingKey(true) {
            withPreparedBook {
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restoreNowPlayingPage()
                XCTAssertTrue(SonuxRuntime.shared.player.showPlayer, "上次在播 → 重开落到播放页")
            }
        }
    }

    func testRestoreNowPlayingPage_staysClosedWhenLastSessionWasIdle() {
        withWasPlayingKey(false) {
            withPreparedBook {
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restoreNowPlayingPage()
                XCTAssertFalse(SonuxRuntime.shared.player.showPlayer, "上次没在播 → 照旧停在书库")
            }
        }
    }

    func testRestoreNowPlayingPage_needsABookToOpen() {
        // 书还没扫进书库（currentBook 空）时不能把播放页开着空转，等书挂上那次才算数
        let player = SonuxRuntime.shared.player
        withWasPlayingKey(true) {
            player.unloadPrepared()
            let savedShowPlayer = player.showPlayer
            player.showPlayer = false
            SonuxRuntime.shared.restoreNowPlayingPage()
            XCTAssertFalse(player.showPlayer)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: SonuxRuntime.wasPlayingKey),
                          "没开成页就不该吃掉标记")
            player.showPlayer = savedShowPlayer
        }
    }

    func testRestoreNowPlayingPage_consumesFlagSoItOpensOnlyOnce() {
        withWasPlayingKey(true) {
            withPreparedBook {
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restoreNowPlayingPage()
                XCTAssertTrue(SonuxRuntime.shared.player.showPlayer)
                // 用户手动收起后，后续再挂书（比如扫完外部引用的书）不该把人弹回播放页
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restoreNowPlayingPage()
                XCTAssertFalse(SonuxRuntime.shared.player.showPlayer)
            }
        }
    }

    func testRememberWasPlaying_storesCurrentPlayingState() {
        let defaults = UserDefaults.standard
        withWasPlayingKey(true) {
            withPreparedBook {
                // 挂着没出声 → 记 false，下次冷启动就该停在书库
                SonuxRuntime.shared.rememberWasPlaying()
                XCTAssertFalse(defaults.bool(forKey: SonuxRuntime.wasPlayingKey))
            }
        }
    }
}
