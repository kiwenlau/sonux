import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// 视图批次 4：ChapterRow / ListeningBarChart / ChapterList / MiniPlayerView。
/// 上一轮把 RootView 也拉进来试过，但它 body 里挂着 .task 会 kick CoverStore.load
/// 的异步链，测试宿主里等不到落地→跳过；深层留给 UI 集成用例（Phase C）。
@MainActor
final class MoreViewsInspectorTests: XCTestCase {
    // MARK: - ChapterRow（详情页/章节弹层共用的一行）

    private func chapter(_ i: Int, duration: TimeInterval = 60) -> Chapter {
        Chapter(id: "c\(i)", bookId: "b", index: i, title: "第\(i)章",
                duration: duration, fileURL: URL(fileURLWithPath: "/tmp/\(i).mp3"))
    }

    func testChapterRow_indexColumnIsOneBased() throws {
        let row = ChapterRow(chapter: chapter(3), isCurrent: false,
                             isPlaying: false, position: nil)
        let hStack = try row.inspect().hStack()
        // HStack 第 0 格是章号 1-based（index 3 → "4"）
        XCTAssertEqual(try hStack.text(0).string(), "4")
    }

    func testChapterRow_titleAndStateLiveInsideVStack() throws {
        let row = ChapterRow(chapter: chapter(1, duration: 3725),
                             isCurrent: false, isPlaying: false, position: nil)
        let inner = try row.inspect().hStack().vStack(1)
        // VStack 第 0 格是章名，第 1 格是 stateText
        XCTAssertEqual(try inner.text(0).string(), "第1章")
        // 无 position：stateText = TimeFormat.time(duration) = "1:02:05"
        XCTAssertEqual(try inner.text(1).string(), "1:02:05")
    }

    func testChapterRow_inProgressPositionShowsTimeSlashDuration() throws {
        let row = ChapterRow(chapter: chapter(1, duration: 3725),
                             isCurrent: false, isPlaying: false,
                             position: PlayPosition(chapterId: "c1", time: 85))
        let inner = try row.inspect().hStack().vStack(1)
        // 已听到 85 s：stateText = "1:25 / 1:02:05"
        XCTAssertEqual(try inner.text(1).string(), "1:25 / 1:02:05")
    }

    func testChapterRow_currentChapterAddsNowPlayingBars() throws {
        let row = ChapterRow(chapter: chapter(2), isCurrent: true,
                             isPlaying: true, position: nil)
        // isCurrent 时 HStack 末尾会挂上 NowPlayingBars（TimelineView 起手）；
        // 具体柱状不深 unwrap
        _ = try row.inspect().hStack()
    }

    // MARK: - ListeningBarChart（「我」页近 7 天柱状图）

    func testListeningBarChart_rendersHStackInsideGeometryReader() throws {
        let chart = ListeningBarChart(values: [100, 200, 300],
                                      peakFloor: 0, highlightIndex: 2)
        // GeometryReader 是 SingleViewContent，直接 hStack() 会穿过它拿子层
        _ = try chart.inspect().geometryReader().hStack()
    }

    func testListeningBarChart_emptyValuesDoesNotCrash() throws {
        let chart = ListeningBarChart(values: [], peakFloor: 0, highlightIndex: nil)
        _ = try chart.inspect().geometryReader()
    }

    func testListeningBarChart_propsArePreserved() {
        let chart = ListeningBarChart(values: [1, 2, 3], peakFloor: 10, highlightIndex: 1)
        XCTAssertEqual(chart.values, [1, 2, 3])
        XCTAssertEqual(chart.peakFloor, 10)
        XCTAssertEqual(chart.highlightIndex, 1)
    }

    // MARK: - ChapterList（详情页与章节弹层共用 List 内容）

    func testChapterList_rendersForEach() throws {
        let book = Book(id: "b", title: "T", author: nil,
                        chapters: (0..<3).map { chapter($0) }, storagePath: "b")
        let view = ChapterList(book: book)
            .environmentObject(SonuxRuntime.shared.library)
            .environmentObject(SonuxRuntime.shared.player)
        // body 顶层是 ForEach；具体行不深 unwrap（ChapterRow 上一节已覆盖）
        _ = try view.inspect().forEach()
    }

    // MARK: - MiniPlayerView

    func testMiniPlayerView_rendersWithEnv() throws {
        let view = MiniPlayerView(onTap: {})
            .environmentObject(SonuxRuntime.shared.player)
        // body 顶层是 HStack：左边书籍 + 右边播放按钮
        _ = try view.inspect().hStack()
    }
}
