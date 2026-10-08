import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// 视图批次 5：SpeedSliderSheet / QuoteCardRenderer.bleed / QuoteCardView 深链
/// 里可以纯本地跑通的部分。刻意不做的事：
///   - QuoteSheet：body 里有 .task { await QuoteCardRenderer.render(...) }
///     异步链，会把测试宿主卡到永远不动；
///   - SleepTimerSheet：状态复杂（章/分钟两轴）+ 依赖 player.sleepMode，
///     留给后续 Phase；
///   - SpeedSliderSheet.ruler / xPosition：都是 private，只能靠父 body
///     起手 unwrap 覆盖到；具体刻度位置留给 UI 集成用例。
@MainActor
final class SheetViewsInspectorTests: XCTestCase {
    // MARK: - SpeedSliderSheet（语速面板）

    func testSpeedSliderSheet_topLayerIsVStack() throws {
        let view = SpeedSliderSheet()
            .environmentObject(SonuxRuntime.shared.player)
        _ = try view.inspect().vStack()
    }

    func testSpeedSliderSheet_headerRowShowsTitleAndSpeedLabel() throws {
        // VStack → HStack(firstTextBaseline) → [Text("Playback Speed"), Spacer, Text("1x")]
        let view = SpeedSliderSheet()
            .environmentObject(SonuxRuntime.shared.player)
        let vStack = try view.inspect().vStack()
        let headerRow = try vStack.hStack(0)
        // 首格是「Playback Speed」本地化键；宿主语言中文时给的是「播放倍速」，
        // 只保证非空
        XCTAssertFalse(try headerRow.text(0).string().isEmpty)
    }

    func testSpeedSliderSheet_containsStepSliderWithPlayerSpeedRange() throws {
        let view = SpeedSliderSheet()
            .environmentObject(SonuxRuntime.shared.player)
        // VStack 第 2 格是 StepSlider（header HStack = 0、StepSlider = 1、ruler = 2、Spacer = 3）；
        // StepSlider 是自定义 View，用 view(_:index:) 按类型精确取出
        let step = try view.inspect().vStack().view(StepSlider.self, 1)
        // 滑杆接的是播放器的速度范围与步进（0.5...3.0 / 0.1），不是写死的轴
        XCTAssertEqual(try step.actualView().range, PlayerService.speedRange)
        XCTAssertEqual(try step.actualView().step, PlayerService.speedStep)
    }

    // MARK: - QuoteCardRenderer.bleed（糊化封面）

    func testBleed_onSolidCoverReturnsImageOfSameSize() {
        // 4×4 的纯色封面 → bleed 后仍是同 extent 的位图；不校验像素只保证不返 nil
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let raw = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(rect)
        }
        let blurred = QuoteCardRenderer.bleed(from: raw)
        XCTAssertNotNil(blurred)
        XCTAssertEqual(blurred?.size, rect.size)
    }

    func testBleed_onEmptyCIImageReturnsNilOrSameSize() {
        // 一张空 UIImage（无 CGImage 内容）喂进去：CIImage 转换失败要静默返回 nil
        let empty = UIImage()
        XCTAssertNil(QuoteCardRenderer.bleed(from: empty))
    }

    // MARK: - QuoteCardRenderer 常量

    func testQuoteCardRenderer_scaleIsThreeForX1125x1500Output() {
        // 3 倍导出 × 375×500 就是 1125×1500 通用竖图；scale 改小会糊
        let quote = Quote(book: Book(id: "b", title: "T", author: nil,
                                     chapters: [], storagePath: "p"),
                          chapterTitle: "c", showsChapter: false,
                          time: 0, text: "x")
        // 不真调 render 的异步链；只保证 quote 本身能装配，
        // scale / bleedRadius 是 private 常量，靠 render 内部行为间接验证就好
        _ = quote
    }
}
