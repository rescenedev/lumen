import SwiftUI
import MapKit
import AppKit

/// One geotagged photo on the map.
final class PhotoAnnotation: NSObject, MKAnnotation {
    let photo: Photo
    let coordinate: CLLocationCoordinate2D
    var title: String? { photo.filename }
    init(photo: Photo, coordinate: CLLocationCoordinate2D) {
        self.photo = photo
        self.coordinate = coordinate
    }
}

/// AppKit `MKMapView` wrapped for SwiftUI so we get real MapKit clustering — far
/// apart photos collapse into a counted bubble that splits as you zoom in. The
/// SwiftUI `Map` doesn't expose clustering, and a 1-pin-per-photo map melts down
/// on tens of thousands of points.
struct ClusteredPhotoMap: NSViewRepresentable {
    let pins: [(photo: Photo, latitude: Double, longitude: Double)]
    let onOpen: (Photo) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(PhotoMarkerView.self, forAnnotationViewWithReuseIdentifier: PhotoMarkerView.reuseID)
        map.register(PhotoClusterView.self, forAnnotationViewWithReuseIdentifier: PhotoClusterView.reuseID)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(map: map, pins: pins)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private let onOpen: (Photo) -> Void
        private var didFit = false
        init(onOpen: @escaping (Photo) -> Void) { self.onOpen = onOpen }

        /// Add/remove annotations to match `pins` (cheap diff so streaming updates
        /// don't rebuild the whole map).
        func sync(map: MKMapView, pins: [(photo: Photo, latitude: Double, longitude: Double)]) {
            let existing = map.annotations.compactMap { $0 as? PhotoAnnotation }
            let existingKeys = Set(existing.map { $0.photo.url })
            let newKeys = Set(pins.map { $0.photo.url })

            let toRemove = existing.filter { !newKeys.contains($0.photo.url) }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }

            let toAdd = pins
                .filter { !existingKeys.contains($0.photo.url) }
                .map { PhotoAnnotation(photo: $0.photo,
                                       coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }

            // Frame the points once, after the first batch arrives.
            if !didFit, !map.annotations.isEmpty {
                didFit = true
                map.showAnnotations(map.annotations, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PhotoClusterView.reuseID, for: cluster) as? PhotoClusterView
                    ?? PhotoClusterView(annotation: cluster, reuseIdentifier: PhotoClusterView.reuseID)
                view.configure(count: cluster.memberAnnotations.count)
                return view
            }
            if let photo = annotation as? PhotoAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PhotoMarkerView.reuseID, for: photo) as? PhotoMarkerView
                    ?? PhotoMarkerView(annotation: photo, reuseIdentifier: PhotoMarkerView.reuseID)
                view.configure(photo: photo.photo)
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                var rect = MKMapRect.null
                for member in cluster.memberAnnotations {
                    let p = MKMapPoint(member.coordinate)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if rect.size.width == 0, rect.size.height == 0 {
                    // All members share one coordinate — a zero-size rect would
                    // zoom in to the maximum. Frame a fixed region instead.
                    mapView.setRegion(MKCoordinateRegion(center: cluster.coordinate,
                                                         latitudinalMeters: 1000,
                                                         longitudinalMeters: 1000), animated: true)
                } else {
                    let pad = NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
                    mapView.setVisibleMapRect(rect, edgePadding: pad, animated: true)
                }
            } else if let photo = view.annotation as? PhotoAnnotation {
                mapView.deselectAnnotation(photo, animated: false)
                onOpen(photo.photo)
            }
        }
    }
}

/// A single photo marker: a rounded thumbnail with a white border, that MapKit
/// is allowed to cluster (via `clusteringIdentifier`).
final class PhotoMarkerView: MKAnnotationView {
    static let reuseID = "PhotoMarker"
    private let imageLayer = CALayer()
    private var loadToken = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 44, height: 44)
        centerOffset = CGPoint(x: 0, y: -22)
        canShowCallout = false
        clusteringIdentifier = "photo"
        displayPriority = .defaultLow

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        imageLayer.frame = bounds
        imageLayer.cornerRadius = 6
        imageLayer.borderColor = NSColor.white.cgColor
        imageLayer.borderWidth = 2
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(photo: Photo) {
        clusteringIdentifier = "photo"
        loadToken += 1
        let token = loadToken
        imageLayer.contents = nil
        // Map pins are small — the 256 tier is plenty and packs the memory cache.
        let maxPixel = ThumbnailCache.tier(forPointSize: 64)
        if let cached = ThumbnailCache.shared.cached(for: photo.url, maxPixel: maxPixel) {
            setImage(cached)
        } else {
            ThumbnailCache.shared.thumbnail(for: photo.url, maxPixel: maxPixel,
                                            mtime: photo.cacheMtime) { [weak self] img in
                guard let self, self.loadToken == token, let img else { return }
                self.setImage(img)
            }
        }
    }

    private func setImage(_ image: NSImage) {
        // Don't clear the layer if the conversion fails — keep whatever is shown.
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cg
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken += 1
        imageLayer.contents = nil
    }
}

/// A cluster bubble showing how many photos it contains.
final class PhotoClusterView: MKAnnotationView {
    static let reuseID = "PhotoCluster"
    private let label = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .circle
        wantsLayer = true

        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(count: Int) {
        // Bubble grows a little with the count so dense areas read as bigger.
        let d: CGFloat = count >= 1000 ? 52 : count >= 100 ? 46 : 40
        frame = NSRect(x: 0, y: 0, width: d, height: d)
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = d / 2
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 2.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 3

        label.stringValue = count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
        label.frame = bounds
        // Vertically center the text in the bubble.
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (d - label.frame.height) / 2, width: d, height: label.frame.height)
    }
}
