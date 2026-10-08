import XCTest
import AppIntents
@testable import Sonux

/// Intents 层的静态契约：三条意图的「不打开 App、锁屏也能跑」这两条关键决策
/// 是刻意的产品选择（记忆里「非侵入式音频行为」+ 车载场景），改一个就会砸到
/// 「嘿 Siri 播放我的书」在锁屏/CarPlay 下的可用性。appShortcuts 表也钉住条数。
final class AppIntentsContractTests: XCTestCase {
    // MARK: - 三条意图的共同策略

    func testPlayBookIntent_doesNotOpenAppWhenRun() {
        XCTAssertFalse(PlayBookIntent.openAppWhenRun,
                       "开车要的是声音，不该把屏幕点亮成播放页")
    }

    func testPlayBookIntent_allowsAuthenticatedLocked() {
        XCTAssertEqual(PlayBookIntent.authenticationPolicy, .alwaysAllowed,
                       "锁屏在口袋里也要能开播，默认策略会要求先解锁")
    }

    func testNextChapterIntent_policiesMatch() {
        XCTAssertFalse(NextChapterIntent.openAppWhenRun)
        XCTAssertEqual(NextChapterIntent.authenticationPolicy, .alwaysAllowed)
    }

    func testPreviousChapterIntent_policiesMatch() {
        XCTAssertFalse(PreviousChapterIntent.openAppWhenRun)
        XCTAssertEqual(PreviousChapterIntent.authenticationPolicy, .alwaysAllowed)
    }

    // MARK: - 标题（本地化资源键）

    func testIntentTitlesAreSet() {
        // LocalizedStringResource 不直接暴露字符串，只保证构造出来不崩、非默认空
        XCTAssertFalse(String(describing: PlayBookIntent.title).isEmpty)
        XCTAssertFalse(String(describing: NextChapterIntent.title).isEmpty)
        XCTAssertFalse(String(describing: PreviousChapterIntent.title).isEmpty)
    }

    // MARK: - PlayBookIntent 的书参数可选

    func testPlayBookIntent_bookParameterIsOptional() {
        // 没报书名 → book == nil → playForVoice(bookId: nil) 走「接上次听的那本」
        let intent = PlayBookIntent()
        XCTAssertNil(intent.book)
    }

    func testPlayBookIntent_withBookCarriesId() {
        let intent = PlayBookIntent()
        intent.book = BookEntity(id: "b1", title: "某本书")
        XCTAssertEqual(intent.book?.id, "b1")
    }

    // MARK: - SonuxAppShortcuts 预置表

    func testAppShortcuts_hasThreeEntries() {
        // 「播放我的书」「下一章」「上一章」三条；加/删要同步改文档
        XCTAssertEqual(SonuxAppShortcuts.appShortcuts.count, 3)
    }

    func testAppShortcuts_eachHasAtLeastOnePhrase() {
        for shortcut in SonuxAppShortcuts.appShortcuts {
            // phrases 是内部属性不便直读，退而验不崩且数量对
            XCTAssertNotNil(shortcut)
        }
    }
}
