// Generates the 1024px app icon (gradient + two tilted photo cards).
// Run: swift Scripts/make_icon.swift Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Full-bleed brand gradient (iOS masks the corners).
let colors = [CGColor(red: 0.36, green: 0.42, blue: 1.0, alpha: 1),
              CGColor(red: 0.58, green: 0.36, blue: 0.98, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

func card(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat, angle: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: angle)
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.25))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

let cw: CGFloat = 400, ch: CGFloat = 510, r: CGFloat = 78
card(cx: CGFloat(S) / 2 - 60, cy: CGFloat(S) / 2 - 10, w: cw, h: ch, radius: r, angle: 0.20, alpha: 0.5)   // back
card(cx: CGFloat(S) / 2 + 58, cy: CGFloat(S) / 2 + 6,  w: cw, h: ch, radius: r, angle: -0.13, alpha: 1.0)  // front

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.lastPathComponent)")
