import XCTest
import SwiftUI
import ViewInspector
@testable import Sonux

/// ViewInspector 冒烟：证明「测试宿主 + @testable import + ViewInspector」三件套
/// 能把 App 里的一个真视图 body 反解出来。跑通了再往上加视图批次；跑不通就退回
/// 「只测纯逻辑」的老路子。
///
/// 挑一个最简单的：CircleGlyphButton 只吃 glyph + action 两个入参，body 里就一层
/// Button + Image(systemName:)，没有 @ObservedObject、没有 @Environment，
/// 是这套工具链的最可靠试金石。
///
/// ViewInspector 0.10.x 没有 symbolName() API，只能拿到 actualImage() 里的 SwiftUI.Image
/// 但系统不公开其 name；这里退而求其次断言「树里确实有 Image + Button」和 tap 派发即可。
final class ViewInspectorSmokeTests: XCTestCase {
    func testCircleGlyphButton_exposesButtonWithImage() throws {
        let view = CircleGlyphButton(glyph: "chevron.backward", action: {})
        // 顶层是 Button → 用 button()；再往下拿到里面那枚 Image
        let button = try view.inspect().button()
        _ = try button.labelView().image()     // 只要不 throw 就说明树里有一枚 Image
    }

    func testCircleGlyphButton_diameterConstants() {
        // 顺手把两份静态尺寸钉死，改一个视觉就崩
        XCTAssertEqual(CircleGlyphButton.diameter, 45)
        XCTAssertEqual(CircleGlyphButton.hitDiameter, 68)
        XCTAssertGreaterThan(CircleGlyphButton.hitDiameter, CircleGlyphButton.diameter,
                             "热区必须大于视觉圆，否则擦边点不中")
    }

    func testCircleGlyphButton_invokesActionOnTap() throws {
        var fired = 0
        let view = CircleGlyphButton(glyph: "plus") { fired += 1 }
        try view.inspect().button().tap()
        XCTAssertEqual(fired, 1)
    }

    func testCircleGlyphButton_tapTwiceFiresTwice() throws {
        var fired = 0
        let view = CircleGlyphButton(glyph: "plus") { fired += 1 }
        let button = try view.inspect().button()
        try button.tap()
        try button.tap()
        XCTAssertEqual(fired, 2)
    }
}
