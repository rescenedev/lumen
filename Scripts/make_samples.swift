import AppKit
import ImageIO
import UniformTypeIdentifiers

// Generates sample JPEGs (with subfolders) carrying fake EXIF camera info,
// capture dates, and GPS coordinates so every feature has data to show.
// Usage: swift make_samples.swift <outputDir>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "LumenSamples"
let fm = FileManager.default

struct Place { let folder: String; let colors: [NSColor]; let camera: String; let lat: Double; let lon: Double }

let places: [Place] = [
    Place(folder: "Seoul",
          colors: [NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.25, alpha: 1),
                   NSColor(calibratedRed: 0.85, green: 0.20, blue: 0.45, alpha: 1)],
          camera: "Apple iPhone 15 Pro", lat: 37.5665, lon: 126.9780),
    Place(folder: "Tokyo",
          colors: [NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.85, alpha: 1),
                   NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.55, alpha: 1)],
          camera: "SONY ILCE-7M4", lat: 35.6762, lon: 139.6503),
    Place(folder: "NewYork",
          colors: [NSColor(calibratedRed: 0.30, green: 0.70, blue: 0.40, alpha: 1),
                   NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.25, alpha: 1)],
          camera: "Canon EOS R6", lat: 40.7128, lon: -74.0060)
]

func bitmap(label: String, colors: [NSColor], w: Int, h: Int) -> CGImage? {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    NSGradient(colors: colors)!.draw(in: rect, angle: 35)
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: Double(w) * 0.55, y: Double(h) * 0.55,
                                width: Double(w) * 0.35, height: Double(w) * 0.35)).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: CGFloat(h) * 0.12),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9)
    ]
    NSAttributedString(string: label, attributes: attrs)
        .draw(at: NSPoint(x: CGFloat(w) * 0.07, y: CGFloat(h) * 0.08))
    image.unlockFocus()
    var rectRef = CGRect(x: 0, y: 0, width: w, height: h)
    return image.cgImage(forProposedRect: &rectRef, context: nil, hints: nil)
}

func gpsDict(lat: Double, lon: Double) -> [CFString: Any] {
    [
        kCGImagePropertyGPSLatitude: abs(lat),
        kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(lon),
        kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"
    ]
}

let sizes = [(1600, 1067), (1200, 1600), (2000, 1200), (1400, 1400)]
for place in places {
    let dir = URL(fileURLWithPath: outDir).appendingPathComponent(place.folder)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 1...5 {
        let (w, h) = sizes[(i - 1) % sizes.count]
        guard let cg = bitmap(label: "\(place.folder) \(i)", colors: place.colors, w: w, h: h) else { continue }
        let url = dir.appendingPathComponent("\(place.folder.lowercased())_\(i).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { continue }
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: place.camera,
                kCGImagePropertyTIFFMake: place.camera.components(separatedBy: " ").first ?? ""
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:0\(i):1\(i) 12:30:00",
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [200]
            ],
            kCGImagePropertyGPSDictionary: gpsDict(lat: place.lat + Double(i) * 0.01, lon: place.lon + Double(i) * 0.01),
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
print("Wrote samples with EXIF/GPS to \(outDir)")
