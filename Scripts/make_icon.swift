import AppKit

// Renders a 1024×1024 app icon: a gradient rounded tile with a white "photo"
// card showing a sun and mountains — clearly a photo app.

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let blue = NSColor(calibratedRed: 0.30, green: 0.47, blue: 0.96, alpha: 1)
let purple = NSColor(calibratedRed: 0.56, green: 0.30, blue: 0.93, alpha: 1)

// Background gradient tile
let bgRect = NSRect(x: 76, y: 76, width: size - 152, height: size - 152)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 210, yRadius: 210)
NSGradient(colors: [blue, purple])!.draw(in: bg, angle: -50)

// White photo card
let card = NSRect(x: 250, y: 286, width: 524, height: 452)
let cardPath = NSBezierPath(roundedRect: card, xRadius: 58, yRadius: 58)
NSColor.white.setFill()
cardPath.fill()

NSGraphicsContext.saveGraphicsState()
cardPath.addClip()

// Sun (top-right inside the card)
NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.23, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: card.maxX - 190, y: card.maxY - 190, width: 116, height: 116)).fill()

// Back mountain
let back = NSBezierPath()
back.move(to: NSPoint(x: card.minX - 20, y: card.minY))
back.line(to: NSPoint(x: card.minX + 250, y: card.minY + 250))
back.line(to: NSPoint(x: card.minX + 470, y: card.minY))
back.close()
purple.withAlphaComponent(0.85).setFill()
back.fill()

// Front mountain
let front = NSBezierPath()
front.move(to: NSPoint(x: card.minX + 180, y: card.minY))
front.line(to: NSPoint(x: card.minX + 360, y: card.minY + 190))
front.line(to: NSPoint(x: card.maxX + 20, y: card.minY))
front.close()
blue.setFill()
front.fill()

NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render icon\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
