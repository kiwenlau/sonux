// Sonux App Icon renderer — deterministic CoreGraphics vector drawing.
//   swiftc tools/icon/render_icon.swift -o /tmp/sonuxicon && /tmp/sonuxicon tools/icon/out
// Shipped icons are full-bleed squares; iOS applies its own superellipse mask.
// The contact sheet applies that mask at real home-screen sizes to check legibility.

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

/// Brand background: indigo/violet diagonal ramp with a soft bloom, no hard corners.
func brandBackground(_ ctx: CGContext, _ light: Int, _ base: Int, _ deep: Int,
                     _ bloom: CGPoint, _ bloomColor: Int) {
  let square = CGPath(rect: CGRect(x: 0, y: 0, width: S, height: S), transform: nil)
  linearFill(ctx, square, [c(light), c(base), c(deep)], CGPoint(x: S * 0.1, y: 0),
             CGPoint(x: S * 0.9, y: S), [0, 0.48, 1])
  radialGlow(ctx, bloom, 780, [c(bloomColor, 0.32), c(bloomColor, 0)])
}

func capsulePath(_ r: CGRect) -> CGPath {
  let k = min(r.width, r.height) / 2
  return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
}

func roundedPath(_ r: CGRect, _ k: CGFloat) -> CGPath {
  CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
}

func fillPath(_ ctx: CGContext, _ p: CGPath, _ color: CGColor) {
  ctx.saveGState(); ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath(); ctx.restoreGState()
}

func strokePath(_ ctx: CGContext, _ p: CGPath, _ color: CGColor, _ width: CGFloat,
                cap: CGLineCap = .butt) {
  ctx.saveGState()
  ctx.addPath(p); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(cap)
  ctx.strokePath()
  ctx.restoreGState()
}

/// Sampled arc; degrees use y-up math (90 = screen up), correct under the flipped CTM.
func arcPath(_ center: CGPoint, _ radius: CGFloat, _ a0: CGFloat, _ a1: CGFloat,
             _ segments: Int = 160) -> CGPath {
  let p = CGMutablePath()
  for i in 0...segments {
    let rad = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(segments)) * .pi / 180
    let pt = CGPoint(x: center.x + radius * cos(rad), y: center.y - radius * sin(rad))
    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
  }
  return p
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

/// Mirror-symmetric pseudo-waveform amplitude in 0...1 (designed, not random).
func wave(_ i: Int, _ n: Int) -> CGFloat {
  let k = CGFloat(min(i, n - 1 - i)) / CGFloat(max(n / 2 - 1, 1))
  let s = abs(sin(k * .pi * 2.15) * 0.30 + sin(k * .pi * 4.7 + 0.7) * 0.16)
  return min(max(0.24 + k * 0.42 + s, 0.2), 1.0)
}

let cream = 0xF6F1FF
let ink = 0x35205F

// MARK: - A / F. waveform ring around a play core, in two themes

struct Theme {
  let bgLight: Int, bgBase: Int, bgDeep: Int
  let bloom: Int, bloomAt: CGPoint
  let mark: Int          // waveform bars
  let coreTop: Int, coreBottom: Int, play: Int
  let dim: CGFloat       // alpha of the shorter bars
}

let darkTheme = Theme(bgLight: 0x5B3FAA, bgBase: 0x3B2470, bgDeep: 0x180D36,
                      bloom: 0x8B6AE8, bloomAt: CGPoint(x: S * 0.5, y: S * 0.34),
                      mark: cream, coreTop: 0xFFFFFF, coreBottom: 0xD9C8FF, play: ink, dim: 0.82)

let lightTheme = Theme(bgLight: 0xFAF6EE, bgBase: 0xF0E9F6, bgDeep: 0xDFD3EE,
                       bloom: 0xFFFFFF, bloomAt: CGPoint(x: S * 0.34, y: S * 0.2),
                       mark: 0x3A2272, coreTop: 0x5B3FAA, coreBottom: 0x2A1754, play: 0xFFFFFF,
                       dim: 0.55)

func waveformRing(_ ctx: CGContext, _ t: Theme) {
  brandBackground(ctx, t.bgLight, t.bgBase, t.bgDeep, t.bloomAt, t.bloom)

  let cc = CGPoint(x: S / 2, y: S / 2)
  let bars = 24
  for i in 0..<bars {
    let amp = wave(i, bars)
    ctx.saveGState()
    ctx.translateBy(x: cc.x, y: cc.y)
    ctx.rotate(by: (CGFloat(i) / CGFloat(bars) * 360 - 90) * .pi / 180)
    fillPath(ctx, capsulePath(CGRect(x: 224, y: -16, width: 48 + amp * 132, height: 32)),
             c(t.mark, amp > 0.74 ? 1 : t.dim))
    ctx.restoreGState()
  }

  strokePath(ctx, arcPath(cc, 182, 0, 360), c(t.mark, 0.26), 6)
  radialGlow(ctx, cc, 200, [c(t.mark, 0.18), c(t.mark, 0)])
  let core = CGRect(x: cc.x - 92, y: cc.y - 92, width: 184, height: 184)
  linearFill(ctx, CGPath(ellipseIn: core, transform: nil), [c(t.coreTop), c(t.coreBottom)],
             CGPoint(x: core.minX, y: core.minY), CGPoint(x: core.maxX, y: core.maxY))
  drawPlay(ctx, cc, 92, c(t.play))
}

func conceptA(_ ctx: CGContext) { waveformRing(ctx, darkTheme) }

// MARK: - B. headphones: one solid silhouette (outlined cups read as eyes at 60px)

func conceptB(_ ctx: CGContext) {
  brandBackground(ctx, 0x55399F, 0x36206A, 0x150C31, CGPoint(x: S * 0.5, y: S * 0.24), 0x8A67E6)

  let hub = CGPoint(x: S / 2, y: S * 0.46)
  let bandR: CGFloat = 262
  let endX = hub.x + bandR * cos(12 * .pi / 180)
  let endY = hub.y - bandR * sin(12 * .pi / 180)

  strokePath(ctx, arcPath(hub, bandR, 12, 168), c(cream), 74, cap: .round)
  for x in [endX, hub.x - (endX - hub.x)] {
    fillPath(ctx, roundedPath(CGRect(x: x - 86, y: endY - 40, width: 172, height: 316), 80), c(cream))
  }

  // the sound sitting between the two cups
  for (i, h) in [54.0, 108.0, 158.0, 108.0, 54.0].enumerated() {
    fillPath(ctx, capsulePath(CGRect(x: hub.x - 112 + CGFloat(i) * 56, y: hub.y + 196 - h / 2,
                                     width: 24, height: h)), c(cream, 0.9))
  }
}

// MARK: - C. liquid-glass play tile over a waveform

func conceptC(_ ctx: CGContext) {
  brandBackground(ctx, 0x6043B4, 0x3D2578, 0x180E38, CGPoint(x: S * 0.26, y: S * 0.2), 0xA07BFF)

  let tile = CGRect(x: S / 2 - 244, y: S / 2 - 244, width: 488, height: 488)
  let bars = 19
  for i in 0..<bars {
    let x = 66 + CGFloat(i) * 50
    let h = 70 + wave(i, bars) * 360
    if x + 24 > tile.minX && x < tile.maxX { continue } // stops at the tile, no bleed-through
    fillPath(ctx, capsulePath(CGRect(x: x, y: S / 2 - h / 2, width: 24, height: h)), c(cream, 0.6))
  }

  radialGlow(ctx, CGPoint(x: tile.midX, y: tile.midY + 40), 340, [c(0xFFFFFF, 0.16), c(0xFFFFFF, 0)])
  linearFill(ctx, roundedPath(tile, 112), [c(0xFFFFFF, 0.30), c(0xFFFFFF, 0.08)],
             CGPoint(x: tile.minX, y: tile.minY), CGPoint(x: tile.maxX, y: tile.maxY))
  strokePath(ctx, roundedPath(tile.insetBy(dx: 5, dy: 5), 108), c(cream, 0.72), 9)
  ctx.saveGState()
  ctx.addPath(roundedPath(tile, 112))
  ctx.clip()
  fillPath(ctx, capsulePath(CGRect(x: tile.minX + 66, y: tile.minY + 48,
                                   width: tile.width - 132, height: 14)), c(0xFFFFFF, 0.4))
  ctx.restoreGState()
  drawPlay(ctx, CGPoint(x: tile.midX, y: tile.midY), 214, c(0xFFFFFF))
}

// MARK: - D. play source emitting sound

func conceptD(_ ctx: CGContext) {
  brandBackground(ctx, 0x5739A6, 0x37206E, 0x140B2F, CGPoint(x: S * 0.3, y: S * 0.5), 0x8E6BEC)

  let tip = CGPoint(x: 452, y: S / 2)
  drawPlay(ctx, CGPoint(x: 330, y: S / 2), 252, c(cream))
  for (i, r) in [CGFloat(252), 356, 458].enumerated() {
    strokePath(ctx, arcPath(tip, r, -52, 52), c(cream, [0.94, 0.58, 0.3][i]),
               [64, 52, 40][i], cap: .round)
  }
}

// MARK: - E. sound disc: grooved record with a play center

func conceptE(_ ctx: CGContext) {
  brandBackground(ctx, 0x5A3DA8, 0x38216E, 0x160C33, CGPoint(x: S * 0.5, y: S * 0.3), 0x8D6BE8)

  let cc = CGPoint(x: S / 2, y: S / 2)
  fillPath(ctx, CGPath(ellipseIn: CGRect(x: cc.x - 336, y: cc.y - 336, width: 672, height: 672),
                       transform: nil), c(0x201340, 0.8))
  for (i, r) in [CGFloat(336), 292, 248].enumerated() {
    strokePath(ctx, arcPath(cc, r, 0, 360), c(cream, [0.8, 0.34, 0.24][i]), i == 0 ? 11 : 6)
  }
  strokePath(ctx, arcPath(cc, 336, 30, 176), c(cream, 0.98), 12, cap: .round) // spinning highlight
  let core = CGRect(x: cc.x - 172, y: cc.y - 172, width: 344, height: 344)
  linearFill(ctx, CGPath(ellipseIn: core, transform: nil), [c(0xFFFFFF), c(0xD6C2FF)],
             CGPoint(x: core.minX, y: core.minY), CGPoint(x: core.maxX, y: core.maxY))
  drawPlay(ctx, cc, 164, c(ink))
}

// MARK: - F. same mark on a light icon (pops on iOS 26 translucent wallpaper)

func conceptF(_ ctx: CGContext) { waveformRing(ctx, lightTheme) }

// MARK: - SHIPPED ICON — 满幅双侧波形 + 大播放三角
//
// One geometry, two palettes: the warm-white master and the iOS dark-appearance twin.

struct Palette {
  let bg: [Int]                        // three stops, top-left -> bottom-right
  let bloom: (Int, CGFloat, CGPoint)   // colour, alpha, centre
  let corner: (Int, CGFloat, CGPoint)  // counter-weight tint in the opposite corner
  let bar: Int
  let halo: (Int, CGFloat)
  let badge: [Int]                     // play badge gradient
  let play: Int
}

let masterPalette = Palette(
  bg: [0xFCF9F3, 0xF0E9F9, 0xD8C9EE],
  bloom: (0xFFFFFF, 0.85, CGPoint(x: S * 0.30, y: S * 0.16)),
  corner: (0xB79BE8, 0.30, CGPoint(x: S * 0.78, y: S * 0.86)),
  bar: 0x3A2272,
  halo: (0x8B6AE8, 0.30),
  badge: [0x5B3FAA, 0x2A1754], play: 0xFFFFFF)

let darkPalette = Palette(
  bg: [0x5B3FAA, 0x3B2470, 0x160C33],
  bloom: (0x9B7BF0, 0.40, CGPoint(x: S * 0.30, y: S * 0.16)),
  corner: (0x0C0722, 0.55, CGPoint(x: S * 0.82, y: S * 0.88)),
  bar: 0xF6F1FF,
  halo: (0xFFFFFF, 0.26),
  badge: [0xFFFFFF, 0xDFCFFF], play: 0x3A2272)

func sonuxIcon(_ ctx: CGContext, _ p: Palette) {
  iconGround(ctx, p)

  let cc = CGPoint(x: S / 2, y: S / 2)
  // Mirrored envelope: peaks and quiet stretches, so the ring reads as a waveform
  // rather than a sunburst. One solid colour — alpha layering turns muddy at 60px.
  let amps: [CGFloat] = [0.34, 0.78, 0.44, 1.00, 0.56, 0.86, 0.38, 0.66, 0.94, 0.50]
  let bars = 20
  for i in 0..<bars {
    let a = amps[min(i, bars - 1 - i)]
    ctx.saveGState()
    ctx.translateBy(x: cc.x, y: cc.y)
    ctx.rotate(by: (CGFloat(i) / CGFloat(bars) * 360 - 90) * .pi / 180)
    fillPath(ctx, capsulePath(CGRect(x: 232, y: -20, width: 34 + a * 162, height: 40)), c(p.bar))
    ctx.restoreGState()
  }

  radialGlow(ctx, cc, 300, [c(p.halo.0, p.halo.1), c(p.halo.0, 0)])
  let core = CGRect(x: cc.x - 160, y: cc.y - 160, width: 320, height: 320)
  linearFill(ctx, CGPath(ellipseIn: core, transform: nil), p.badge.map { c($0) },
             CGPoint(x: core.minX, y: core.minY), CGPoint(x: core.maxX, y: core.maxY))
  drawPlay(ctx, cc, 176, c(p.play), round: 0.26)
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

let concepts: [(String, (CGContext) -> Void)] = [
  ("a-waveform-ring", conceptA),
  ("b-headphones", conceptB),
  ("c-glass-play", conceptC),
  ("d-broadcast", conceptD),
  ("e-sound-disc", conceptE),
  ("f-light-waveform-ring", conceptF),
]

func renderIcon(_ draw: (CGContext) -> Void) -> CGImage? {
  let ctx = newContext(Int(S), Int(S))
  flipped(ctx, CGFloat(S))
  draw(ctx)
  return ctx.makeImage()
}

// concepts: full-size squares + a masked contact sheet, kept as the record of
// the directions that were rejected
var conceptImages: [(String, CGImage)] = []
for (name, draw) in concepts {
  guard let img = renderIcon(draw) else { continue }
  let ctx = newContext(Int(S), Int(S))
  flipped(ctx, CGFloat(S))
  draw(ctx)
  write(ctx, "icon-\(name)")
  conceptImages.append((name, img))
}

let sizes = [240, 120, 60]
let pad = 56, gap = 40, cellW = 268, rowH = 300
let w = pad * 2 + conceptImages.count * cellW + (conceptImages.count - 1) * gap
let h = pad * 2 + rowH * sizes.count
let sheet = newContext(w, h)
flipped(sheet, CGFloat(h))
linearFill(sheet, CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil),
           [c(0x2A2140), c(0x100C1A)], .zero, CGPoint(x: 0, y: CGFloat(h)))
for (col, item) in conceptImages.enumerated() {
  for (row, px) in sizes.enumerated() {
    let x = CGFloat(pad + col * (cellW + gap)) + CGFloat(cellW - px) / 2
    let y = CGFloat(pad + row * rowH)
    sheet.saveGState()
    sheet.translateBy(x: x, y: y)
    sheet.addPath(roundedPath(CGRect(x: 0, y: 0, width: px, height: px), CGFloat(px) * maskRatio))
    sheet.clip()
    sheet.draw(masked(item.1, px), in: CGRect(x: 0, y: 0, width: px, height: px))
    sheet.restoreGState()
  }
}
write(sheet, "contact-sheet")

// the shipped pair: warm-white master + iOS dark-appearance twin
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



print("rendered \(concepts.count) concepts + \(shipped.count) shipped icons into \(outDir)")
