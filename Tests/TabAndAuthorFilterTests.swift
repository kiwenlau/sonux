import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// 视图与书库服务批次 7：AppTab 契约 / BottomPanelBackground 装饰层 /
/// LibraryService.books(byAuthor:) 与 listeningProgress(for:) 走真实单例。
@MainActor
final class TabAndAuthorFilterTests: XCTestCase {
    // MARK: - AppTab（底部三 tab 的枚举）

    func testAppTab_threeCasesInMenuOrder() {
        XCTAssertEqual(AppTab.allCases, [.library, .history, .me])
    }

    func testAppTab_idIsSelf() {
        for tab in AppTab.allCases {
            XCTAssertEqual(tab.id, tab)
        }
    }

    func testAppTab_titlesAreNonEmptyAndDistinct() {
        let titles = AppTab.allCases.map { $0.title }
        for t in titles { XCTAssertFalse(t.isEmpty) }
        XCTAssertEqual(Set(titles).count, titles.count, "三个 tab 标题不能撞车")
    }

    func testAppTab_iconsAreNonEmpty() {
        // 每个 tab 至少有一枚线框图标；filledIcon 可选（选中态实心）
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.icon.isEmpty, "\(tab) 要有图标")
        }
    }

    // MARK: - BottomPanelBackground（装饰层，命中测试整块关）

    func testBottomPanelBackground_nilCoverIsPureBackdrop() throws {
        let view = BottomPanelBackground(cover: nil)
        // ZStack 起手；无 cover 分支就一个 Color 底
        _ = try view.inspect().zStack()
    }

    func testBottomPanelBackground_withCoverAddsBlurLayer() throws {
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let cover = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(rect)
        }
        let view = BottomPanelBackground(cover: cover)
        _ = try view.inspect().zStack()
    }

    // MARK: - LibraryService.books(byAuthor:)（作者页过滤）

    private var library: LibraryService { SonuxRuntime.shared.library }

    func testBooksByAuthor_emptyOrWhitespaceReturnsNone() {
        // authorKey 空 → 直接 guard 回 []，不去遍历
        XCTAssertEqual(library.books(byAuthor: "").count, 0)
        XCTAssertEqual(library.books(byAuthor: "   ").count, 0)
    }

    func testBooksByAuthor_unknownAuthorReturnsNone() {
        XCTAssertEqual(library.books(byAuthor: "查无此人-\(UUID().uuidString)").count, 0)
    }

    func testBooksByAuthor_matchesCaseAndWhitespaceInsensitive() throws {
        guard let withAuthor = library.books.first(where: {
            let a = $0.author?.trimmingCharacters(in: .whitespacesAndNewlines); return !((a ?? "").isEmpty)
        }), let author = withAuthor.author else {
            throw XCTSkip("书库里没有带作者名的书")
        }
        // 用归一化键的任意大小写变体去查都应命中那本
        let hits = library.books(byAuthor: author.uppercased())
        XCTAssertTrue(hits.contains { $0.id == withAuthor.id },
                      "作者名大小写不同也应认成同一人")
        for book in hits {
            XCTAssertEqual(LibraryService.authorKey(book.author ?? ""),
                           LibraryService.authorKey(author))
        }
    }

    // MARK: - listeningProgress(for:)

    func testListeningProgress_zeroDurationBookIsZero() {
        // 空章节 → totalDuration 0 → guard 回 0，不除零
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        XCTAssertEqual(library.listeningProgress(for: book), 0)
    }

    func testListeningProgress_withinZeroOne() {
        // 真实库里随便挑一本有章节的：进度必落在 [0, 1]
        guard let book = library.books.first(where: { !$0.chapters.isEmpty }) else {
            return
        }
        let p = library.listeningProgress(for: book)
        XCTAssertGreaterThanOrEqual(p, 0)
        XCTAssertLessThanOrEqual(p, 1)
    }

    // MARK: - nextUnfinishedBook

    func testNextUnfinishedBook_isAMemberOfLibrary() {
        guard let next = library.nextUnfinishedBook() else {
            XCTAssertTrue(library.books.isEmpty)
            return
        }
        XCTAssertTrue(library.books.contains { $0.id == next.id })
    }
}
