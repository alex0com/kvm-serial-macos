// Draw the app icon and write Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift [preview.png]
//
// Every size in the iconset is rendered from the same vector drawing (no
// downscaling), using kvm-serial's palette: burgundy, steel blue and cream. Pass a path to also save a 1024 px preview.

import AppKit
import CoreGraphics

let burgundy = CGColor(srgbRed: 107 / 255, green: 15 / 255, blue: 31 / 255, alpha: 1)
let burgundyLight = CGColor(srgbRed: 158 / 255, green: 30 / 255, blue: 52 / 255, alpha: 1)
let burgundyDark = CGColor(srgbRed: 72 / 255, green: 8 / 255, blue: 20 / 255, alpha: 1)
let steelBlue = CGColor(srgbRed: 91 / 255, green: 134 / 255, blue: 179 / 255, alpha: 1)
let steelBlueDark = CGColor(srgbRed: 45 / 255, green: 74 / 255, blue: 107 / 255, alpha: 1)
let cream = CGColor(srgbRed: 238 / 255, green: 245 / 255, blue: 219 / 255, alpha: 1)

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r,
           transform: nil)
}

func fillGradient(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor,
                  from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// Draw the icon on a 1024-unit canvas with a top-left origin.
func drawIcon(_ ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    // Tile: the standard macOS icon grid puts an 824 pt rounded square in a
    // 1024 pt canvas, with a soft shadow underneath.
    let tile = roundedRect(100, 100, 824, 824, 185)
    ctx.saveGState()
    // Shadow offsets are in device space (origin bottom-left), so negative y is down.
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
                  color: CGColor(gray: 0, alpha: 0.35))
    fill(ctx, tile, burgundy)
    ctx.restoreGState()
    fillGradient(ctx, tile, top: burgundyLight, bottom: burgundyDark, from: 100, to: 924)

    // Monitor bezel and screen.
    fill(ctx, roundedRect(212, 214, 600, 404, 44), cream)
    let screen = roundedRect(240, 242, 544, 348, 22)
    fillGradient(ctx, screen, top: steelBlue, bottom: steelBlueDark, from: 242, to: 590)

    // A window on the remote desktop, with traffic-light dots.
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    fill(ctx, roundedRect(284, 290, 290, 188, 16), CGColor(gray: 1, alpha: 0.2))
    fill(ctx, roundedRect(284, 290, 290, 34, 16), CGColor(gray: 1, alpha: 0.18))
    for (i, x) in [306.0, 332.0, 358.0].enumerated() {
        let alpha = [0.75, 0.55, 0.4][i]
        ctx.setFillColor(CGColor(srgbRed: 238 / 255, green: 245 / 255, blue: 219 / 255, alpha: alpha))
        ctx.fillEllipse(in: CGRect(x: x, y: 299, width: 16, height: 16))
    }
    ctx.restoreGState()

    // Mouse pointer, the "M" in KVM, outlined so it reads at small sizes.
    let pointer = CGMutablePath()
    let tip = CGPoint(x: 520, y: 360)
    let outline: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 170), (42, 130), (70, 192), (100, 179), (72, 118), (128, 118),
    ]
    pointer.addLines(between: outline.map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) })
    pointer.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 12 * scale,
                  color: CGColor(gray: 0, alpha: 0.35))
    fill(ctx, pointer, cream)
    ctx.restoreGState()
    ctx.addPath(pointer)
    ctx.setStrokeColor(burgundyDark)
    ctx.setLineWidth(12)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Stand.
    fill(ctx, CGPath(rect: CGRect(x: 484, y: 616, width: 56, height: 46), transform: nil), cream)
    fill(ctx, roundedRect(404, 656, 216, 24, 12), cream)

    // Keyboard.
    fill(ctx, roundedRect(236, 714, 552, 136, 28), cream)
    let keyColor = burgundy.copy(alpha: 0.85)!
    let keys = 11, gap: CGFloat = 10, inset: CGFloat = 26
    let keyWidth = (552 - 2 * inset - CGFloat(keys - 1) * gap) / CGFloat(keys)
    for row in 0..<2 {
        for k in 0..<keys {
            let x = 236 + inset + CGFloat(k) * (keyWidth + gap)
            fill(ctx, roundedRect(x, 734 + CGFloat(row) * 36, keyWidth, 26, 6), keyColor)
        }
    }
    fill(ctx, roundedRect(392, 806, 240, 24, 6), keyColor)  // space bar
}

func renderPNG(pixels: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(ctx, pixels: pixels)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let resources = scriptDir.appendingPathComponent("../Resources").standardized
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2).write(
        to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")

if CommandLine.arguments.count > 1 {
    try renderPNG(pixels: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Wrote \(CommandLine.arguments[1])")
}
