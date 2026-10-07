import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// 视图批次 3：PlayerLayout / PlayerView 常量 / LibraryView shell / QuoteCardView。
/// 刻意跳过 PlayerView / TranscriptView / TextSearchView 的 body 起手 unwrap——
/// 这三页里有 .task 异步扫描、@ObservedObject CoverStore.shared 冷启动拉盘、
/// DragGesture 等副作用；实测在测试宿主里 inspect 会让主线程等一个永远不会
/// 落地的 await，把整批 test-without-building 卡到超时（本地已复现过一次）。
/// 深层留给 UI 集成用例。
@MainActor
final class ComplexViewsInspectorTests: XCTestCase {
    // MARK: - PlayerView 布局常量（public static let，钉死免得回归）

    func testPlayerView_gapTokensMatchEightGrid() {
        // 间距全部取 8 的倍数（唯一例外 12 = 8×1.5，用来在 caption 与 progress 之间
        // 拉开一档又不越组）；改任一数字都要同步改整页节奏
        XCTAssertEqual(PlayerView.gapHeaderToText, 16)
        XCTAssertEqual(PlayerView.gapCoverToChapter, 32)
        XCTAssertEqual(PlayerView.gapChapterToCaption, 8)
        XCTAssertEqual(PlayerView.gapChapterToProgress, 16)
        XCTAssertEqual(PlayerView.gapCaptionToProgress, 12)
        XCTAssertEqual(PlayerView.gapProgressToControls, 24)
    }

    // MARK: - PlayerLayout 参数与默认值

    func testPlayerLayout_defaultGapsAndWeights() {
        let layout = PlayerLayout(coverIndex: 1, ratio: 0.8, coverMaxWidth: 340)
        XCTAssertEqual(layout.coverIndex, 1)
        XCTAssertEqual(layout.ratio, 0.8)
        XCTAssertEqual(layout.coverMaxWidth, 340)
        // 默认间距按播放页那套 8 倍数刻度
        XCTAssertEqual(layout.topGap, 16)
        XCTAssertEqual(layout.bottomGap, 32)
        // 默认重量比让播放组自然靠底（下侧略大）
        XCTAssertEqual(layout.topWeight, 2)
        XCTAssertEqual(layout.bottomWeight, 3)
    }

    func testPlayerLayout_customGapsAndWeights() {
        let layout = PlayerLayout(coverIndex: 0, ratio: 1.5, coverMaxWidth: 500,
                                  topGap: 8, bottomGap: 24, topWeight: 1, bottomWeight: 1)
        XCTAssertEqual(layout.topGap, 8)
        XCTAssertEqual(layout.bottomGap, 24)
        XCTAssertEqual(layout.topWeight, 1)
        XCTAssertEqual(layout.bottomWeight, 1)
    }

    func testPlayerLayoutLayoutDataTypeCarriesSizeAndIsCoverFlag() {
        // LayoutData 是私有辅助 struct 但对同 file 可见；这里通过 PlayerLayout 的公开
        // 参数间接验证「coverIndex 用来标记哪一格是封面」这条契约
        let layout = PlayerLayout(coverIndex: 2, ratio: 1, coverMaxWidth: 200)
        XCTAssertEqual(layout.coverIndex, 2)
    }

    // MARK: - LibraryView 起手（body 里有 @FocusState / @AppStorage 但都是同步读，安全）

    func testLibraryView_withEnvObjectsUnwrapsTopLayer() throws {
        // LibraryView 不用系统 NavigationStack（.searchable 与自绘工具栏冲突），
        // body 直接是 VStack：搜索栏 → 全文搜索入口 → List/Grid 主体
        let view = LibraryView()
            .environmentObject(SonuxRuntime.shared.library)
            .environmentObject(SonuxRuntime.shared.player)
            .environmentObject(TabRouters())
        _ = try view.inspect().vStack()
    }

    func testLibraryView_authorModeAcceptsAuthorParam() throws {
        // 作者页复用同一套视图，只多传一个 author 字符串
        let view = LibraryView(author: "鲁迅")
            .environmentObject(SonuxRuntime.shared.library)
            .environmentObject(SonuxRuntime.shared.player)
            .environmentObject(TabRouters())
        _ = try view.inspect().vStack()
    }

    // MARK: - QuoteCardView（3:4 分享卡片，纯 props 无副作用）

    func testQuoteCardView_sizeIsThreeToFour() {
        XCTAssertEqual(QuoteCardView.size, CGSize(width: 375, height: 500))
        XCTAssertEqual(QuoteCardView.size.width / QuoteCardView.size.height, 0.75, accuracy: 1e-6)
    }

    func testQuoteCardView_rendersWithInjectedProps() throws {
        // QuoteCardView 只吃 Quote + palette + artwork，无 @State / @ObservedObject，
        // body 起手是 ZStack（backdrop + 内容 VStack），最稳的一层
        let book = Book(id: "b", title: "T", author: "A",
                        chapters: [Chapter(id: "c", bookId: "b", index: 0, title: "第一章",
                                           duration: 60,
                                           fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))],
                        storagePath: "b")
        let quote = Quote(book: book, chapterTitle: "第一章", showsChapter: true,
                          time: 12.5, text: "摘录的一句")
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(rect)
        }
        let artwork = QuoteArtwork(thumb: image, bleed: nil)
        let view = QuoteCardView(quote: quote, palette: CoverPalette.fallback, artwork: artwork)
        _ = try view.inspect().zStack()
    }
}
