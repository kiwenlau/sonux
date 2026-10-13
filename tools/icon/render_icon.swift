// Sonux App Icon renderer — deterministic CoreGraphics vector drawing.
//   swiftc tools/icon/render_icon.swift -o /tmp/sonuxicon && /tmp/sonuxicon tools/icon/out
// Shipped icons are full-bleed squares; iOS applies its own superellipse mask.
// The legibility strip applies that mask at real home-screen sizes to check the mark survives.
//
// Mark: one solid disc + one rounded play triangle. Two shapes, nothing else —
// the first version radiated 20 waveform bars and read as a sunburst at 60px.

import CoreGraphics
import Foundation
import ImageIO

let S = 1024.0
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/icon/out"
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - colors

func c(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                         CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}

// MARK: - canvas

func newContext(_ w: Int, _ h: Int) -> CGContext {
  CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func flipped(_ ctx: CGContext, _ size: CGFloat) {
  ctx.translateBy(x: 0, y: size)
  ctx.scaleBy(x: 1, y: -1)
}

func write(_ ctx: CGContext, _ name: String) { writeTo(ctx, "\(outDir)/\(name).png") }

func writeTo(_ ctx: CGContext, _ path: String) {
  guard let img = ctx.makeImage() else { return }
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                             "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img, nil)
  CGImageDestinationFinalize(dest)
}

// MARK: - fills & shapes

func linearFill(_ ctx: CGContext, _ clip: CGPath, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint,
                _ locs: [CGFloat]? = nil) {
  let n = colors.count
  let locations = locs ?? (0..<n).map { CGFloat($0) / CGFloat(max(n - 1, 1)) }
  guard let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations) else { return }
  ctx.saveGState()
  ctx.addPath(clip)
  ctx.clip()
  ctx.drawLinearGradient(g, start: from, end: to, options: [])
  ctx.restoreGState()
}

func radialGlow(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ colors: [CGColor]) {
  let n = colors.count
  guard let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray,
                           locations: (0..<n).map { CGFloat($0) / CGFloat(max(n - 1, 1)) }) else { return }
  ctx.saveGState()
  ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                         endRadius: radius, options: [.drawsAfterEndLocation])
  ctx.restoreGState()
}

func roundedPath(_ r: CGRect, _ k: CGFloat) -> CGPath {
  CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
}

/// Solid play triangle with rounded corners, nudged right for optical centering.
func drawPlay(_ ctx: CGContext, _ center: CGPoint, _ size: CGFloat, _ color: CGColor,
              round: CGFloat = 0.15) {
  let w = size * 0.94
  let cx = center.x + w * 0.05
  let p = CGMutablePath()
  p.addLines(between: [CGPoint(x: cx - w / 2, y: center.y - size / 2),
                       CGPoint(x: cx - w / 2, y: center.y + size / 2),
                       CGPoint(x: cx + w / 2, y: center.y)])
  p.closeSubpath()
  ctx.saveGState()
  ctx.addPath(p)
  ctx.setLineJoin(.round)
  ctx.setLineWidth(size * round)
  ctx.setFillColor(color)
  ctx.setStrokeColor(color)
  ctx.drawPath(using: .fillStroke)
  ctx.restoreGState()
}

// MARK: - SHIPPED ICON — 实心圆盘 + 圆润播放三角
//
// One geometry, two palettes: the warm-white master and the iOS dark-appearance twin.

struct Palette {
  let bg: [Int]                        // three stops, top-left -> bottom-right
  let bloom: (Int, CGFloat, CGPoint)   // light source
  let corner: (Int, CGFloat, CGPoint)  // counter-weight tint in the opposite corner
  let disc: [Int]                      // badge gradient
  let play: Int                        // triangle sitting on the badge
}

let masterPalette = Palette(
  bg: [0xFCF9F3, 0xF0E9F9, 0xD8C9EE],
  bloom: (0xFFFFFF, 0.85, CGPoint(x: S * 0.30, y: S * 0.16)),
  corner: (0xB79BE8, 0.30, CGPoint(x: S * 0.78, y: S * 0.86)),
  disc: [0x5B3FAA, 0x2A1754], play: 0xFFFFFF)

let darkPalette = Palette(
  bg: [0x5B3FAA, 0x3B2470, 0x160C33],
  bloom: (0x9B7BF0, 0.40, CGPoint(x: S * 0.30, y: S * 0.16)),
  corner: (0x0C0722, 0.55, CGPoint(x: S * 0.82, y: S * 0.88)),
  disc: [0xFFFFFF, 0xDFCFFF], play: 0x3A2272)

func sonuxIcon(_ ctx: CGContext, _ p: Palette) {
  iconGround(ctx, p)

  let cc = CGPoint(x: S / 2, y: S / 2)
  let disc = CGRect(x: cc.x - 318, y: cc.y - 318, width: 636, height: 636)
  linearFill(ctx, CGPath(ellipseIn: disc, transform: nil), p.disc.map { c($0) }, disc.origin,
             CGPoint(x: disc.maxX, y: disc.maxY))
  // +28: the deep rounded left edge carries more visual weight than the tip,
  // so the bbox centre has to sit right of the disc centre to look centred
  drawPlay(ctx, CGPoint(x: cc.x + 28, y: cc.y), 336, c(p.play), round: 0.24)
}

func iconGround(_ ctx: CGContext, _ p: Palette) {
  let square = CGPath(rect: CGRect(x: 0, y: 0, width: S, height: S), transform: nil)
  linearFill(ctx, square, p.bg.map { c($0) }, CGPoint(x: S * 0.08, y: 0),
             CGPoint(x: S * 0.92, y: S), [0, 0.5, 1])
  radialGlow(ctx, p.bloom.2, 700, [c(p.bloom.0, p.bloom.1), c(p.bloom.0, 0)])
  radialGlow(ctx, p.corner.2, 620, [c(p.corner.0, p.corner.1), c(p.corner.0, 0)])
}

// MARK: - preview: iOS-style mask at the real corner ratio

let maskRatio: CGFloat = 0.2237

func masked(_ src: CGImage, _ px: Int) -> CGImage {
  let ctx = newContext(px, px)
  ctx.saveGState()
  ctx.addPath(roundedPath(CGRect(x: 0, y: 0, width: px, height: px), CGFloat(px) * maskRatio))
  ctx.clip()
  ctx.draw(src, in: CGRect(x: 0, y: 0, width: px, height: px))
  ctx.restoreGState()
  return ctx.makeImage()!
}

// MARK: - main

try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir),
                                         withIntermediateDirectories: true)

let assetDir = "Support/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(at: URL(fileURLWithPath: assetDir),
                                         withIntermediateDirectories: true)

let shipped: [(String, Palette)] = [("AppIcon", masterPalette), ("AppIconDark", darkPalette)]
var finalImages: [(String, CGImage)] = []
for (file, palette) in shipped {
  let ctx = newContext(Int(S), Int(S))
  flipped(ctx, CGFloat(S))
  sonuxIcon(ctx, palette)
  write(ctx, "sonux-\(file)")
  writeTo(ctx, "\(assetDir)/\(file).png")
  if let img = ctx.makeImage() { finalImages.append((file, img)) }
}

// legibility strip: both variants masked down to 40px, the size that decides whether a mark survives
let stripSizes = [240, 120, 60, 40]
let stripPad = 40, stripGap = 34
let stripW = stripPad * 2 + stripSizes.reduce(0, +) + stripGap * (stripSizes.count - 1)
let stripH = (finalImages.count * 2 - 1) * 300
let strip = newContext(stripW, stripH)
flipped(strip, CGFloat(stripH))
linearFill(strip, CGPath(rect: CGRect(x: 0, y: 0, width: stripW, height: stripH), transform: nil),
           [c(0x2A2140), c(0x100C1A)], .zero, CGPoint(x: 0, y: CGFloat(stripH)))
for (row, item) in finalImages.enumerated() {
  var x = CGFloat(stripPad)
  for px in stripSizes {
    strip.saveGState()
    strip.translateBy(x: x, y: CGFloat(row * 300 + (300 - px) / 2))
    strip.addPath(roundedPath(CGRect(x: 0, y: 0, width: px, height: px), CGFloat(px) * maskRatio))
    strip.clip()
    strip.draw(masked(item.1, px), in: CGRect(x: 0, y: 0, width: px, height: px))
    strip.restoreGState()
    x += CGFloat(px) + CGFloat(stripGap)
  }
}
write(strip, "final-legibility")

print("rendered \(shipped.count) shipped icons into \(outDir)")
