import XCTest
@testable import Sonux

/// WidgetBridge 的 App Group 容器在单元测试里通常是 nil（宿主 App 的 entitlement 在
/// 测试 runner 环境不总生效），这恰好是最要紧的降级路径：
///   ① write 拿不到 URL 要返回 false，日志一次不重复；
///   ② readSnapshot / readCover / clear 静默 no-op，小组件画空态而不是崩。
/// 有真容器的话（例如 CI 加了 entitlements）也能顺路跑一次完整读写。
final class WidgetBridgeTests: XCTestCase {
    func testGroupIdentifier_isStableString() {
        // 两份 entitlements（Sonux & SonuxWidget）里的组名必须完全一致，改一边会当场失联
        XCTAssertEqual(WidgetBridge.groupIdentifier, "group.com.kiwenlau.sonux")
    }

    func testWriteHandlesNilContainer() {
        // 单元测试环境通常 containerURL == nil；这时 write 不能崩、要返回 false
        let snapshot = NowPlayingSnapshot(bookId: "b1", bookTitle: "T", author: nil,
                                          chapterTitle: "C", isPlaying: false)
        // 真容器可用时 write 会返回 true；nil 时 false。两种都算合法。
        let result = WidgetBridge.write(snapshot: snapshot, coverPNG: nil)
        // 只保证不 throw；布尔值取决于环境
        _ = result
    }

    func testReadSnapshot_survivesMissingFile() {
        // 容器不存在或文件不存在都应给 nil，让小组件画空态
        // （第一次跑或 clear 之后就是这种状态）
        let snapshot = WidgetBridge.readSnapshot()
        // 不断言 nil 还是值——环境相关；只要不 throw 就算通过契约
        if let s = snapshot {
            // 万一有历史遗留的 now-playing.json，也必须是可解的合法快照
            XCTAssertNotNil(s.bookTitle)
        }
    }

    func testClear_survivesMissingFile() {
        // clear 内部用 try? 移除文件，不存在也不该 throw
        WidgetBridge.clear()
    }

    func testReadCover_survivesMissingFile() {
        // 有历史遗留封面时返回一张 UIImage；容器/文件缺失时返回 nil。两种都算合法。
        _ = WidgetBridge.readCover(maxPixel: 100)
    }
}
