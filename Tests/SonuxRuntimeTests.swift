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
}
