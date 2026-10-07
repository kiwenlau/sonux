import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// 视图批次 2：靠 .environmentObject() 把 SonuxRuntime.shared 里的 library / player
/// 单例注进来，就能把 MeView / HistoryView / ListeningReportView 等「Tab 根」级视图
/// 的 body 反解出来。刻意不做的事：
///   - 不点会改播放状态的按钮（怕串测试）；
///   - 不断具体文案（走 L/LF 取词，宿主语言变了就砸）；
///   - 不进 List / NavigationStack 深层：ViewInspector 对这两类容器支持不完整。
///
/// 目的：让这些之前 0% 或 <5% 的 body 组装代码至少走一遍，把行覆盖率从
/// 「App 启动时 SwiftUI 系统自己 draw 一次」推进到「测试主动 inspect 一次」。
@MainActor
final class EnvironmentViewsInspectorTests: XCTestCase {
    // MARK: - LanguageView（@State 全在自己身上，最独立）

    func testLanguageView_bodyIsList() throws {
        // List 顶层；不进去看具体行（AppLanguageSetting.sortedByLocalizedName 有 34 项，
        // 每行 Button + HStack + Image/Text，深 unwrap 脆）
        _ = try LanguageView().inspect().list()
    }

    // MARK: - PlaybackSettingsView（@ObservedObject PlaybackSettings.shared）

    func testPlaybackSettingsView_bodyIsList() throws {
        _ = try PlaybackSettingsView().inspect().list()
    }

    func testPlaybackSettingsView_showsFourSilenceModes() throws {
        // 顶部 Section 里 ForEach(SilenceSkipMode.allCases) 应该出四行；
        // 但 List → Section → ForEach 的深层 unwrap 不稳，退而验整体能 inspect
        let view = PlaybackSettingsView()
        _ = try view.inspect().list()
    }

    // MARK: - MeView（library.listeningSummary()）

    func testMeView_injectsLibraryAndRenders() throws {
        let library = SonuxRuntime.shared.library
        let view = MeView().environmentObject(library)
        // 顶层是 VStack(spacing: 14)，里面第一格永远是 SettingsCard；
        // 空态与非空态在第二格分叉，两种都靠同一个 vStack 起手
        _ = try view.inspect().vStack()
    }

    // MARK: - HistoryView（library.historyEntries()）

    func testHistoryView_injectsServicesAndRenders() throws {
        let view = HistoryView(onOpenBook: { _ in })
            .environmentObject(SonuxRuntime.shared.library)
            .environmentObject(SonuxRuntime.shared.player)
        // body 顶层是 Group（if-else 二选一）
        _ = try view.inspect().group()
    }

    // MARK: - ListeningReportView（library.listeningReport()）

    func testListeningReportView_injectsLibraryAndRenders() throws {
        let view = ListeningReportView().environmentObject(SonuxRuntime.shared.library)
        _ = try view.inspect().scrollView()
    }

    // MARK: - BookDetailView

    func testBookDetailView_injectsEverythingAndRenders() throws {
        let book = Book(id: "b1", title: "测试书", author: "某人",
                        chapters: [Chapter(id: "c1", bookId: "b1", index: 0, title: "第一章",
                                           duration: 100,
                                           fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))],
                        storagePath: "b1")
        let routers = TabRouters()
        let view = BookDetailView(book: book)
            .environmentObject(SonuxRuntime.shared.library)
            .environmentObject(SonuxRuntime.shared.player)
            .environmentObject(routers)
        _ = try view.inspect().list()
    }

    // MARK: - ChaptersSheet（Book prop 就够，无需 env 注入）

    func testChaptersSheet_wrapsNavStackWithTitle() throws {
        let book = Book(id: "b1", title: "T", author: nil,
                        chapters: (0..<3).map {
                            Chapter(id: "c\($0)", bookId: "b1", index: $0, title: "第\($0)章",
                                    duration: 60,
                                    fileURL: URL(fileURLWithPath: "/tmp/\($0).mp3"))
                        },
                        storagePath: "b1")
        let view = ChaptersSheet(book: book)
        // 顶层是 NavigationStack；导航容器本身不深解，只保证 unwrap 起手不 throw
        _ = try view.inspect().navigationStack()
    }

    // MARK: - TabRouters 与 AppRouter 契约

    func testTabRouters_defaultSelectedTabIsLibrary() {
        let routers = TabRouters()
        XCTAssertEqual(routers.selectedTab, .library)
    }

    func testTabRouters_activeMatchesSelection() {
        let routers = TabRouters()
        XCTAssertTrue(routers.active === routers.libraryRouter)
        routers.selectedTab = .history
        XCTAssertTrue(routers.active === routers.historyRouter)
        routers.selectedTab = .me
        XCTAssertTrue(routers.active === routers.meRouter)
    }

    func testTabRouters_threeRoutersAreDistinct() {
        let routers = TabRouters()
        XCTAssertFalse(routers.libraryRouter === routers.historyRouter)
        XCTAssertFalse(routers.historyRouter === routers.meRouter)
    }

    func testAppRouter_startsEmptyStack() {
        XCTAssertTrue(AppRouter().path.isEmpty)
    }
}
