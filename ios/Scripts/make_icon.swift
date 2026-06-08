// Generates the 1024px app icon — a clean photo card with the heart "keep" mark
// on a vibrant brand gradient. Modern, minimal, matches the in-app LumenGlyph.
// Run: swift Scripts/make_icon.swift Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let mid = CGFloat(S) / 2

// 1) Full-bleed slate gradient — matches the app's slate theme (lumenBG/lumenCard).
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.18, green: 0.21, blue: 0.28, alpha: 1),   // cool slate, lit corner
    CGColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 1),
    CGColor(red: 0.06, green: 0.075, blue: 0.105, alpha: 1), // ≈ lumenBG
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// 2) Soft highlight glow near the top for depth.
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: mid, y: CGFloat(S) * 0.78), startRadius: 0,
                       endCenter: CGPoint(x: mid, y: CGFloat(S) * 0.78), endRadius: CGFloat(S) * 0.6, options: [])

func roundedCardPath(w: CGFloat, h: CGFloat, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// A tilted white photo card with a soft drop shadow.
func card(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat,
          angle: CGFloat, alpha: CGFloat, shadow: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: angle)
    ctx.addPath(roundedCardPath(w: w, h: h, radius: radius))
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 48, color: CGColor(gray: 0, alpha: 0.28)) }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

// 3) Faint card peeking behind — the "stack / swipe" idea, kept subtle.
card(cx: mid - 96, cy: mid + 4, w: 392, h: 496, radius: 88, angle: 0.17, alpha: 0.22, shadow: false)
// 4) The front photo card.
let frontAngle: CGFloat = -0.10
card(cx: mid + 54, cy: mid - 8, w: 412, h: 516, radius: 92, angle: frontAngle, alpha: 1.0, shadow: true)

// 5) Heart, gradient-filled, centered on the front card (tilts with it).
func heartPath(w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let cusp = CGPoint(x: 0, y: 0.26 * h)      // top dip between the lobes
    let tip  = CGPoint(x: 0, y: -0.50 * h)     // bottom point
    p.move(to: cusp)
    p.addCurve(to: CGPoint(x: -0.50 * w, y: 0.30 * h),
               control1: CGPoint(x: -0.16 * w, y: 0.52 * h), control2: CGPoint(x: -0.50 * w, y: 0.52 * h))
    p.addCurve(to: tip,
               control1: CGPoint(x: -0.50 * w, y: 0.04 * h), control2: CGPoint(x: -0.20 * w, y: -0.20 * h))
    p.addCurve(to: CGPoint(x: 0.50 * w, y: 0.30 * h),
               control1: CGPoint(x: 0.20 * w, y: -0.20 * h), control2: CGPoint(x: 0.50 * w, y: 0.04 * h))
    p.addCurve(to: cusp,
               control1: CGPoint(x: 0.50 * w, y: 0.52 * h), control2: CGPoint(x: 0.16 * w, y: 0.52 * h))
    p.closeSubpath()
    return p
}

ctx.saveGState()
ctx.translateBy(x: mid + 54, y: mid - 8)
ctx.rotate(by: frontAngle)
let hw: CGFloat = 196, hh: CGFloat = 176
ctx.addPath(heartPath(w: hw, h: hh))
ctx.clip()
let heartGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.46, green: 0.50, blue: 1.00, alpha: 1),   // indigo accent (lumenAccent), lone pop of color
    CGColor(red: 0.40, green: 0.40, blue: 0.98, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(heartGrad, start: CGPoint(x: -hw / 2, y: hh / 2),
                       end: CGPoint(x: hw / 2, y: -hh / 2), options: [])
ctx.restoreGState()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.lastPathComponent)")
