import SwiftUI

/// Interactive crop overlay: drag the rectangle to move, drag a corner to resize.
/// `cropNorm` is normalized (0…1, top-left origin). `aspect` is the desired
/// width/height ratio in PIXELS (nil = freeform).
struct CropCanvas: View {
    let image: NSImage
    @Binding var cropNorm: CGRect
    let aspect: CGFloat?
    /// Output-content footprint relative to the crop (≤1). When set, an inset box
    /// shows how big the saved image content is versus what's shown.
    var indicatorScale: CGFloat? = nil
    var indicatorLabel: String = ""
    /// Position of the content box within the crop (0…1, top-left origin). Doubles
    /// as the image's placement inside a padded canvas when `indicatorDraggable`.
    @Binding var indicatorAnchor: CGPoint
    var indicatorDraggable = false
    /// Magnification of the fitted image (1 = fit). Lets the user zoom in to crop
    /// precisely; panning (drag outside the crop) reveals the rest.
    @Binding var zoom: CGFloat

    @State private var startRect: CGRect?
    @State private var startIndicator: CGPoint?
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var zoomBase: CGFloat = 1

    private enum Corner: CaseIterable { case tl, tr, bl, br }

    var body: some View {
        GeometryReader { geo in
            let base = Self.fit(image.size, in: geo.size)
            let fw = base.width * zoom, fh = base.height * zoom
            let f = CGRect(x: base.midX - fw / 2 + panOffset.width,
                           y: base.midY - fh / 2 + panOffset.height, width: fw, height: fh)
            let cr = viewRect(in: f)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)

                // Pan layer (only when zoomed): sits above the image but below the
                // crop move/handles, so dragging OUTSIDE the crop pans the image.
                if zoom > 1.001 {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(panGesture)
                }

                Path { p in p.addRect(f); p.addRect(cr) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                Path { $0.addRect(cr) }.stroke(Color.white, lineWidth: 1.5)
                    .allowsHitTesting(false)
                thirds(cr)

                // Move
                Color.clear
                    .frame(width: cr.width, height: cr.height)
                    .contentShape(Rectangle())
                    .position(x: cr.midX, y: cr.midY)
                    .gesture(moveGesture(f))

                // Corner handles
                ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, c in
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 1)
                        .position(point(c, cr))
                        .gesture(cornerGesture(c, f))
                }

                outputIndicator(cr)            // topmost, so its drag wins over the move area
            }
            .contentShape(Rectangle())
            .simultaneousGesture(MagnificationGesture()
                .onChanged { v in zoom = min(max(zoomBase * v, 1), 8) }
                .onEnded { _ in zoomBase = zoom })
            .onTapGesture(count: 2) { zoom = 1; zoomBase = 1; panOffset = .zero }
            .onChange(of: zoom) { _, z in
                zoomBase = z
                if z <= 1.001 { panOffset = .zero }
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                let start = panStart ?? panOffset
                if panStart == nil { panStart = start }
                panOffset = CGSize(width: start.width + v.translation.width,
                                   height: start.height + v.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    /// Box (sized to the output footprint) the user can drag to position the image
    /// inside a padded canvas. When not draggable it's just a static size preview.
    @ViewBuilder private func outputIndicator(_ cr: CGRect) -> some View {
        if let indicatorScale {
            let bw = max(4, cr.width * indicatorScale), bh = max(4, cr.height * indicatorScale)
            let travelW = max(0, cr.width - bw), travelH = max(0, cr.height - bh)
            let ox = cr.minX + indicatorAnchor.x * travelW
            let oy = cr.minY + indicatorAnchor.y * travelH
            ZStack {
                Rectangle().fill(Color.accentColor.opacity(0.30))
                    .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                    .frame(width: bw, height: bh)
                Text(indicatorLabel)
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white).fixedSize()
                    .offset(y: -bh / 2 - 9)
            }
            .frame(width: bw, height: bh)
            .position(x: ox + bw / 2, y: oy + bh / 2)
            .allowsHitTesting(indicatorDraggable)
            .gesture(indicatorDraggable ? indicatorGesture(travelW, travelH) : nil)
        }
    }

    private func indicatorGesture(_ travelW: CGFloat, _ travelH: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = startIndicator ?? indicatorAnchor
                if startIndicator == nil { startIndicator = start }
                let nx = travelW > 0 ? start.x + v.translation.width / travelW : start.x
                let ny = travelH > 0 ? start.y + v.translation.height / travelH : start.y
                indicatorAnchor = CGPoint(x: min(max(0, nx), 1), y: min(max(0, ny), 1))
            }
            .onEnded { _ in startIndicator = nil }
    }

    @ViewBuilder private func thirds(_ cr: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = cr.minX + cr.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: cr.minY)); p.addLine(to: CGPoint(x: x, y: cr.maxY))
                let y = cr.minY + cr.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: cr.minX, y: y)); p.addLine(to: CGPoint(x: cr.maxX, y: y))
            }
        }.stroke(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
    }

    private func viewRect(in f: CGRect) -> CGRect {
        CGRect(x: f.minX + cropNorm.minX * f.width, y: f.minY + cropNorm.minY * f.height,
               width: cropNorm.width * f.width, height: cropNorm.height * f.height)
    }
    private func point(_ c: Corner, _ r: CGRect) -> CGPoint {
        switch c {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func moveGesture(_ f: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = startRect ?? cropNorm; if startRect == nil { startRect = start }
                var o = CGPoint(x: start.minX + v.translation.width / f.width,
                                y: start.minY + v.translation.height / f.height)
                o.x = min(max(0, o.x), 1 - start.width)
                o.y = min(max(0, o.y), 1 - start.height)
                cropNorm = CGRect(origin: o, size: start.size)
            }
            .onEnded { _ in startRect = nil }
    }

    private func cornerGesture(_ c: Corner, _ f: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = startRect ?? cropNorm; if startRect == nil { startRect = start }
                let dx = v.translation.width / f.width, dy = v.translation.height / f.height
                // Anchor = opposite corner (fixed).
                var ax = start.minX, ay = start.minY      // anchor (opposite of dragged)
                var mx = start.maxX, my = start.maxY      // moving corner
                switch c {
                case .tl: ax = start.maxX; ay = start.maxY; mx = start.minX + dx; my = start.minY + dy
                case .tr: ax = start.minX; ay = start.maxY; mx = start.maxX + dx; my = start.minY + dy
                case .bl: ax = start.maxX; ay = start.minY; mx = start.minX + dx; my = start.maxY + dy
                case .br: ax = start.minX; ay = start.minY; mx = start.maxX + dx; my = start.maxY + dy
                }
                mx = min(max(0, mx), 1); my = min(max(0, my), 1)
                var w = abs(mx - ax), h = abs(my - ay)
                if let aspect, image.size.width > 0 {
                    let k = aspect * image.size.height / image.size.width   // normalized w/h
                    // Constrain to ratio using the smaller available extent.
                    if w / max(h, 0.0001) > k { w = h * k } else { h = w / k }
                }
                w = max(0.05, w); h = max(0.05, h)
                let nx = mx >= ax ? ax : ax - w
                let ny = my >= ay ? ay : ay - h
                var r = CGRect(x: nx, y: ny, width: w, height: h)
                // Clamp inside [0,1].
                if r.minX < 0 { r.origin.x = 0 }; if r.minY < 0 { r.origin.y = 0 }
                if r.maxX > 1 { r.size.width = 1 - r.minX }
                if r.maxY > 1 { r.size.height = 1 - r.minY }
                cropNorm = r
            }
            .onEnded { _ in startRect = nil }
    }

    /// Aspect-fit `imageSize` within `container`, centered.
    static func fit(_ imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}
