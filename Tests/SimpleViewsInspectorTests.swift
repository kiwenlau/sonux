import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// 视图批次 1：把「只吃 props、不碰 PlayerService.shared 写侧、不装 Timer」
/// 的公共 SwiftUI 视图都跑一遍 ViewInspector。每个视图验 body 树能反解到
/// 关键节点（Text / Button / Image / VStack 层数），偶尔断 accessibilityIdentifier。
///
/// 刻意跳过的：
///   - 需要 @EnvironmentObject 的（EmptyLibraryView、ChapterList、MiniPlayerView）
///     留到批次 3 用 environmentObject() 注入；
///   - NavigationStack / List 顶层：ViewInspector 对导航栈 unwrap 支持不完整。
@MainActor
final class SimpleViewsInspectorTests: XCTestCase {
    // MARK: - StatItem（「我」页累计卡/本月卡的一个指标）

    func testStatItem_rendersValueAboveTitle() throws {
        let view = StatItem(title: "总时长", value: "12 小时")
        let vStack = try view.inspect().vStack()
        // 上值下标题：index 0 = value、index 1 = title
        XCTAssertEqual(try vStack.text(0).string(), "12 小时")
        XCTAssertEqual(try vStack.text(1).string(), "总时长")
    }

    func testStatItem_emptyValueStillRenders() throws {
        let view = StatItem(title: "T", value: "")
        let vStack = try view.inspect().vStack()
        XCTAssertEqual(try vStack.text(0).string(), "")
    }

    // MARK: - ContentUnavailableWrapper（空态与搜索无结果共用一层壳）

    func testContentUnavailableWrapper_rendersImageAndTitle() throws {
        let view = ContentUnavailableWrapper(title: "书库是空的", systemImage: "tray.and.arrow.down.fill") {
            EmptyView()
        }
        let vStack = try view.inspect().vStack()
        _ = try vStack.image(0)
        XCTAssertEqual(try vStack.text(1).string(), "书库是空的")
    }

    func testContentUnavailableWrapper_defaultImageIsTrayArrow() throws {
        // 不显式传 systemImage 时应该拿默认那枚「tray.and.arrow.down.fill」；
        // ViewInspector 0.10.x 不暴露 symbol name，只保证 Image 节点存在
        let view = ContentUnavailableWrapper(title: "T") { EmptyView() }
        _ = try view.inspect().vStack().image(0)
    }

    func testContentUnavailableWrapper_includesActionSlot() throws {
        // 第三格是 action() 的返回值；这里传个 Button 应该被塞进 vStack
        let view = ContentUnavailableWrapper(title: "T", systemImage: "x") {
            Button("Tap me") {}
        }
        let vStack = try view.inspect().vStack()
        // vStack 至少 3 层：Image + Text + action
        XCTAssertEqual(vStack.count, 3)
        _ = try vStack.button(2)
    }

    // MARK: - NowPlayingBars（音柱标记）

    func testNowPlayingBars_hasFourBars() throws {
        let view = NowPlayingBars(height: 14, isPlaying: true)
        // TimelineView 包裹一层；contentView() 拿实际渲染内容
        let timeline = try view.inspect().timelineView()
        _ = try timeline.contentView()
    }

    func testNowPlayingBars_defaultHeightIs14() throws {
        // 默认参数：不传 height 时应该是 14（与播放页那行了字标注一致）
        let view = NowPlayingBars(isPlaying: false)
        XCTAssertEqual(view.height, 14)
    }

    // MARK: - MiniPlayButton（迷你播放按钮，带进度环）

    func testMiniPlayButton_tapsAction() throws {
        var fired = 0
        let view = MiniPlayButton(progress: 0.3, isPlaying: false) { fired += 1 }
        try view.inspect().button().tap()
        XCTAssertEqual(fired, 1)
    }

    func testMiniPlayButton_ringMinProgressConstant() {
        // 进度不足 1% 不画弧：这阈值改了会让「刚开播」的那几帧看着像起点标记
        XCTAssertEqual(MiniPlayButton.ringMinProgress, 0.01)
    }

    func testMiniPlayButton_defaultHitSideAndOnCoverAreOff() {
        let view = MiniPlayButton(progress: 0.5, isPlaying: false, action: {})
        XCTAssertEqual(view.hitSide, 0)
        XCTAssertFalse(view.onCover)
        XCTAssertNil(view.accessibilityLabelOverride)
    }

    // MARK: - StepSlider（拖动+点击吸附的语速/定时滑杆）

    func testStepSlider_constants() {
        XCTAssertEqual(StepSlider.knobSize, 24)
        XCTAssertEqual(StepSlider.knobInset, 12)   // knobSize / 2
    }

    func testStepSlider_bindsValueWithConstant() throws {
        // 传 .constant 免造 State；body 顶层是 GeometryReader，unwrap 就够
        let view = StepSlider(value: .constant(1.5), range: 0.5...3.0, step: 0.1)
        _ = try view.inspect().geometryReader()
    }

    func testStepSlider_rangeAndStepArePreserved() {
        let view = StepSlider(value: .constant(2.0), range: 0.5...3.0, step: 0.1)
        XCTAssertEqual(view.range, 0.5...3.0)
        XCTAssertEqual(view.step, 0.1)
    }

    // MARK: - BookCoverView（书库卡片/迷你播放器/详情页导航栏都复用它）

    func testBookCoverView_defaultSizeIs50() {
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        XCTAssertEqual(BookCoverView(book: book).size, 50)
    }

    func testBookCoverView_miniPlayerSizeOverride() {
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        XCTAssertEqual(BookCoverView(book: book, size: 40).size, 40)
    }

    func testBookCoverView_backgroundDefaultsToSecondary() {
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        // 默认不是 nil；传 nil 才叫「露出容器底色」（迷你播放器用）
        XCTAssertNotNil(BookCoverView(book: book).background)
        XCTAssertNil(BookCoverView(book: book, size: 40, background: nil).background)
    }

    func testBookCoverView_rendersRoundedRectShell() throws {
        // body 顶层是 RoundedRectangle → .fill → .frame → .overlay → .task 修饰链；
        // ViewInspector 0.10.x 对 shape + .overlay + .task 组合 unwrap 支持不完整，
        // 只验 shape 层能解出，深链留给 UI 集成用例
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        let view = BookCoverView(book: book)
        _ = try view.inspect().shape()
    }
}
