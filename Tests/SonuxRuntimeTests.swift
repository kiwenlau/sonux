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

    private func withShowPlayerOnLaunchKey(_ value: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SonuxRuntime.showPlayerOnLaunchKey)
        defaults.removeObject(forKey: SonuxRuntime.showPlayerOnLaunchKey)
        if let value { defaults.set(value, forKey: SonuxRuntime.showPlayerOnLaunchKey) }
        body()
        if let saved { defaults.set(saved, forKey: SonuxRuntime.showPlayerOnLaunchKey) }
        else { defaults.removeObject(forKey: SonuxRuntime.showPlayerOnLaunchKey) }
    }

    func testRestorePlayerPage_opensEvenThoughNothingWasPlaying() {
        // 上次退出时播放页是开着的、但已经按了暂停 → 重开仍要落回播放页
        withShowPlayerOnLaunchKey(true) {
            withPreparedBook {
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restorePlayerPageOnLaunch()
                XCTAssertTrue(SonuxRuntime.shared.player.showPlayer, "标记为真 → 重开落到播放页")
            }
        }
    }

    func testRestorePlayerPage_staysClosedWhenLastSessionLeftTheLibrary() {
        withShowPlayerOnLaunchKey(false) {
            withPreparedBook {
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restorePlayerPageOnLaunch()
                XCTAssertFalse(SonuxRuntime.shared.player.showPlayer, "上次停在书库 → 照旧停在书库")
            }
        }
    }

    func testRestorePlayerPage_needsABookToOpen() {
        // 书还没扫进书库（currentBook 空）时不能把播放页开着空转，等书挂上那次才算数
        let player = SonuxRuntime.shared.player
        withShowPlayerOnLaunchKey(true) {
            player.unloadPrepared()
            let savedShowPlayer = player.showPlayer
            player.showPlayer = false
            SonuxRuntime.shared.restorePlayerPageOnLaunch()
            XCTAssertFalse(player.showPlayer)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: SonuxRuntime.showPlayerOnLaunchKey),
                          "没开成页就不该吃掉标记")
            player.showPlayer = savedShowPlayer
        }
    }

    func testRestorePlayerPage_consumesFlagSoItOpensOnlyOnce() {
        withShowPlayerOnLaunchKey(true) {
            withPreparedBook {
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restorePlayerPageOnLaunch()
                XCTAssertTrue(SonuxRuntime.shared.player.showPlayer)
                // 用户手动收起后，后续再挂书（比如扫完外部引用的书）不该把人弹回播放页
                SonuxRuntime.shared.player.showPlayer = false
                SonuxRuntime.shared.restorePlayerPageOnLaunch()
                XCTAssertFalse(SonuxRuntime.shared.player.showPlayer)
            }
        }
    }

    // MARK: - 退到后台时怎么记这个标记

    func testRememberPlayerPageOnLaunch_recordsOpenPageWhilePaused() {
        let defaults = UserDefaults.standard
        withShowPlayerOnLaunchKey(false) {
            withPreparedBook {
                let player = SonuxRuntime.shared.player
                player.showPlayer = true
                XCTAssertFalse(player.isPlaying, "prepareToResume 只挂书不出声")
                SonuxRuntime.shared.rememberPlayerPageOnLaunch()
                XCTAssertTrue(defaults.bool(forKey: SonuxRuntime.showPlayerOnLaunchKey),
                              "播放页开着就算，哪怕正暂停")
            }
        }
    }

    func testRememberPlayerPageOnLaunch_recordsDismissedAndPausedAsFalse() {
        let defaults = UserDefaults.standard
        withShowPlayerOnLaunchKey(true) {
            withPreparedBook {
                let player = SonuxRuntime.shared.player
                player.showPlayer = false
                XCTAssertFalse(player.isPlaying)
                SonuxRuntime.shared.rememberPlayerPageOnLaunch()
                XCTAssertFalse(defaults.bool(forKey: SonuxRuntime.showPlayerOnLaunchKey),
                               "页收起了也没在播 → 下次冷启动该停在书库")
            }
        }
    }
}
