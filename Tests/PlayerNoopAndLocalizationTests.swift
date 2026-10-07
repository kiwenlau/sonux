import XCTest
@testable import Sonux

/// PlayerService 的读侧与小动作契约：currentPosition()、nextChapter/previousChapter
/// 在没挂书时都安全 no-op，stop() 在全新 player 上也不崩。这些路径都不建 AVPlayerItem、
/// 不 activateAudioSession、不装 Timer，因此不会像 setSleepTimer(.minutes) 那样把主
/// RunLoop 卡住。
@MainActor
final class PlayerServiceNoPlayerTests: XCTestCase {
    private func fresh() -> PlayerService { PlayerService() }

    // MARK: - currentPosition

    func testCurrentPosition_nilWhenNothingPrepared() {
        XCTAssertNil(fresh().currentPosition())
    }

    func testCurrentPosition_reflectsPreparedBookAndTime() {
        let p = fresh()
        let c = Chapter(id: "c1", bookId: "b1", index: 0, title: "T",
                        duration: 100, fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
        let b = Book(id: "b1", title: "T", author: nil, chapters: [c], storagePath: "b1")
        p.prepareToResume(book: b, chapter: c, at: 33)
        let pos = p.currentPosition()
        XCTAssertEqual(pos?.chapterId, "c1")
        XCTAssertEqual(pos?.time ?? -1, 33, accuracy: 1e-6)
    }

    // MARK: - 切章：没挂书时安全 no-op

    func testNextChapter_withoutBookDoesNotCrash() {
        let p = fresh()
        p.nextChapter()
        XCTAssertNil(p.currentChapter)
    }

    func testPreviousChapter_withoutBookDoesNotCrash() {
        let p = fresh()
        p.previousChapter()
        XCTAssertNil(p.currentChapter)
    }

    // MARK: - stop

    func testStop_onFreshPlayerIsSafe() {
        // 没装 AVPlayerItem / 没起 Timer / 没挂书时 stop 应静默 no-op
        let p = fresh()
        p.stop()
        XCTAssertNil(p.currentBook)
        XCTAssertFalse(p.isPlaying)
    }

    // MARK: - skip / seek 在无章时

    func testSkip_withoutChapterDoesNotCrash() {
        let p = fresh()
        p.skip(by: 15)
        p.skip(by: -15)
        XCTAssertEqual(p.currentTime, 0)
    }

    func testSeek_withoutChapterDoesNotCrash() {
        let p = fresh()
        p.seek(to: 30)
        XCTAssertEqual(p.currentTime, 0)
    }

    // MARK: - togglePlayPause 无播放器时

    func testTogglePlayPause_withoutBookOrPlayerIsSafe() {
        // 走 else 分支：currentBook nil → 什么也不做，不 activateAudioSession
        let p = fresh()
        p.togglePlayPause()
        XCTAssertFalse(p.isPlaying)
    }
}

/// 取词函数在测试宿主（Sonux.app）里都能拿到值——Localizable.xcstrings 已随宿主 bundle 装载。
/// 具体文案随宿主语言变，这里只钉两条最要紧的：
///   ① 键存在时函数返回非空字符串；
///   ② 未知键走 NSLocalizedString 兜底，返回值就是键本身或空但绝不崩。
final class LocalizationLookupTests: XCTestCase {
    func testL_forKnownKeyReturnsNonEmpty() {
        // 与 Support/Localizable.xcstrings 里的键对齐，任选几个常用的
        for key in ["Off", "Light", "Standard", "Heavy"] {
            XCTAssertFalse(L(key).isEmpty, "\(key) 应有取值")
        }
    }

    func testL_forUnknownKey_fallsBackToKeyItself() {
        // NSLocalizedString 对未命中的键返回键本身（或空），两种都算合法
        let unknown = "SomeKeyThatDoesNotExist-\(UUID().uuidString)"
        XCTAssertEqual(L(unknown), unknown)
    }

    func testLF_forKeyWithArgumentProducesNonEmpty() {
        // LF 用 String(format:) 组装；只要参数对得上，输出必非空
        let out = LF("%d hr", 3)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.contains("3"))
    }
}
