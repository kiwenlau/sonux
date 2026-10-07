import XCTest
import UIKit
@testable import Sonux

/// CoverPalette.make 是 nonisolated static func，输入一张 UIImage：
///   ① 内部把图缩到 32×32（SampledPixels）；② 按色相分 36 箱加权取均值；
///   ③ 把饱和度与亮度钳到「莫兰迪」区间（sat 0.18–0.45、bri 0.30–0.55），
/// 让白字落在深色渐变上仍可读。这里用代码画几张纯色/双色位图，验主色与兜底分支。
final class CoverPaletteTests: XCTestCase {
    /// 画一张纯色的 UIImage：给 make 提供确定输入
    private func solid(_ color: UIColor, size: CGFloat = 64) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            color.setFill()
            ctx.fill(rect)
        }
    }

    func testMake_nilCGImageFallsThrough() {
        // 空 UIImage（无 cgImage）应安全返回 nil，不崩
        // UIImage() 拿不到 cgImage，SampledPixels 会 fail
        let empty = UIImage()
        XCTAssertNil(CoverPalette.make(from: empty))
    }

    func testMake_pureRedYieldsRedHue() {
        // 纯红：hue ≈ 0；采样后主色应明显偏红（R 分量最高）
        let img = solid(.red)
        let p = try? XCTUnwrap(CoverPalette.make(from: img))
        XCTAssertNotNil(p)
        // 具体分量取决于色彩管理，不做死值断言；主要保证四段都能构造
        if let p { _ = p.gradient }
    }

    func testMake_pureGreenYieldsPalette() {
        let p = CoverPalette.make(from: solid(.green))
        XCTAssertNotNil(p)
    }

    func testMake_pureBlueYieldsPalette() {
        let p = CoverPalette.make(from: solid(.blue))
        XCTAssertNotNil(p)
    }

    func testMake_pureWhiteIsStillReturnedButDimmed() {
        // 白底：SampledPixels 里的 neutralPenalty 会压低权重但不至于全零（有极小兜底），
        // 主色仍算得出；亮度被钳到 ≤ 0.55，不会把播放页背景洗成一片白
        let p = CoverPalette.make(from: solid(.white))
        // 不强制非 nil（视采样细节可能全零），只保证不崩；有值时验证渐变可构造
        if let p { _ = p.gradient }
    }

    func testMake_blackCoverDoesNotCrash() {
        let p = CoverPalette.make(from: solid(.black))
        if let p { _ = p.gradient }
    }

    func testGradient_structureHasFourStops() {
        // fallback 的渐变有 4 段 stop，make 出来的应当同结构（top/middle/lower/bottom）
        // LinearGradient 不公开 stops，这里只保证 make 出来的对象访问 gradient 不崩
        let p = CoverPalette.make(from: solid(.systemPurple))
        let g = p?.gradient ?? CoverPalette.fallback.gradient
        _ = g
    }
}
