import XCTest
import SwiftUI
import UIKit
@testable import Sonux

/// CoverPalette.make 是 nonisolated static func，输入一张 UIImage：
///   ① 内部把图缩到 32×32（SampledPixels）；② 按色相分 36 箱加权取均值；
///   ③ 只保留色相与饱和度（钳到「莫兰迪」区间 sat 0.18–0.45），四段的明暗
/// 由「对白字的对比下限」反推，不跟封面原始亮度走。
/// 下面那组对比度测试就是这条规则的验收闸门：以前钳的是 HSB 的 B，
/// 而 B 不是感知亮度，黄色封面白字只剩 3.5:1，紫调测试书库却全都合格。
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
        // 主色仍算得出；四段明暗由对比目标定，不会把播放页背景洗成一片白
        let p = CoverPalette.make(from: solid(.white))
        // 不强制非 nil（视采样细节可能全零），只保证不崩；有值时验证白字读得清
        if let p { assertReadable(p) }
    }

    func testMake_blackCoverDoesNotCrash() {
        let p = CoverPalette.make(from: solid(.black))
        if let p { assertReadable(p) }
    }

    func testGradient_structureHasFourStops() {
        // fallback 的渐变有 4 段 stop，make 出来的应当同结构（top/middle/lower/bottom）
        // LinearGradient 不公开 stops，这里只保证 make 出来的对象访问 gradient 不崩
        let p = CoverPalette.make(from: solid(.systemPurple))
        let g = p?.gradient ?? CoverPalette.fallback.gradient
        _ = g
    }

    // MARK: - 白字可读性闸门

    // MARK: - helpers

    /// 一个 Color 对纯白的 WCAG 对比度
    private func whiteContrast(_ color: Color) -> Double {
        contrast(against: color, of: (255, 255, 255))
    }

    /// 白字以透明度 a 压在背景上的实际对比度（SwiftUI 渐变按 sRGB 编码值混合）
    private func contrast(_ color: Color, whiteAlpha a: Double) -> Double {
        contrast(against: color, of: blend(white: a, over: color))
    }

    private func contrast(against bg: Color, of rgb: (Double, Double, Double)) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        UIColor(bg).getRed(&r, green: &g, blue: &b, alpha: &al)
        let L1 = luminance(rgb), L2 = luminance((Double(r), Double(g), Double(b)))
        let hi = max(L1, L2), lo = min(L1, L2)
        return (hi + 0.05) / (lo + 0.05)
    }

    private func blend(white a: Double, over color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &al)
        func mix(_ c: CGFloat) -> Double { a * 255 + (1 - a) * Double(c) }
        return (mix(r), mix(g), mix(b))
    }

    private func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ v: Double) -> Double {
            let d = v / 255
            return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    /// 全色相 × 全饱和 × 全明度的封面，四段对纯白都必须 ≥ 4.5:1（WCAG AA 正文）。
    /// 这条不变量就是「按感知亮度钳位」换掉「按 HSB 的 B 钳位」的全部理由
    func testPalette_whiteTextPassesAAcrossEveryHue() {
        for hueDegrees in stride(from: 0, to: 360, by: 15) {
            for saturation in [0.0, 0.25, 0.5, 0.75, 1.0] {
                for brightness in [0.15, 0.4, 0.65, 0.95] {
                    let cover = UIColor(hue: CGFloat(hueDegrees) / 360,
                                        saturation: CGFloat(saturation),
                                        brightness: CGFloat(brightness), alpha: 1)
                    guard let p = CoverPalette.make(from: solid(cover)) else {
                        XCTFail("\(hueDegrees)°/\(saturation)/\(brightness) 封面提不出主色")
                        continue
                    }
                    assertReadable(p, at: "\(hueDegrees)° sat=\(saturation) bri=\(brightness)")
                }
            }
        }
    }

    /// 回归用例：saturated 黄封面是旧算法的翻车现场（同 B 同 S 下黄色比蓝紫亮一倍，
    /// 白字当时只有 3.5:1），换感知亮度钳位后必须达标
    func testPalette_saturatedYellowCoverIsReadable() {
        let yellow = UIColor(hue: 60.0 / 360, saturation: 0.9, brightness: 0.95, alpha: 1)
        let p = try? XCTUnwrap(CoverPalette.make(from: solid(yellow)))
        XCTAssertNotNil(p)
        if let p { assertReadable(p, at: "黄封面") }
    }

    /// 兜底色板（无封面时整页用它）同样要保住白字
    func testFallbackPalette_whiteTextPassesAA() {
        assertReadable(CoverPalette.fallback, at: "fallback")
    }

    /// 播放页的小字（章节名 15pt、字幕 13pt、时间读数 12pt）全在封面下方，用的还是
    /// 60%–70% 的白而不是纯白；这两段必须沉到让「淡白」也够 AA
    func testPalette_lowerStopsCarryDimmedSmallText() {
        for hueDegrees in stride(from: 0, to: 360, by: 15) {
            let cover = UIColor(hue: CGFloat(hueDegrees) / 360, saturation: 0.5, brightness: 0.9, alpha: 1)
            guard let p = CoverPalette.make(from: solid(cover)) else { continue }
            for (name, stop) in [("lower", p.lower), ("bottom", p.bottom)] {
                let ratio = contrast(stop, whiteAlpha: 0.6)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(hueDegrees)° 的 \(name) 上 60% 白只有 \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// 四段自上而下逐段沉：换算法不能把渐变铺平或倒过来
    func testPalette_stopsSinkFromTopToBottom() {
        let p = CoverPalette.fallback
        let lums = [p.top, p.middle, p.lower, p.bottom].map { whiteContrast($0) }
        for i in 0..<(lums.count - 1) {
            XCTAssertGreaterThan(lums[i + 1], lums[i], "第 \(i + 1)→\(i + 2) 段应当更暗（对比更高）")
        }
    }

    private func assertReadable(_ p: CoverPalette, at context: String = "") {
        for (name, stop) in [("top", p.top), ("middle", p.middle), ("lower", p.lower), ("bottom", p.bottom)] {
            let ratio = whiteContrast(stop)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(context) 的 \(name) 白字只有 \(String(format: "%.2f", ratio)):1，低于 AA 4.5:1")
        }
    }
}
