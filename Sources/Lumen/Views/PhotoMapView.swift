import SwiftUI
import MapKit

/// Map presentation: drops a pin for every geotagged photo; clicking a pin
/// opens it in the viewer. For a Photos-library scope the (potentially huge)
/// location scan runs in the background and pins stream in progressively, so the
/// map shows immediately instead of freezing.
struct PhotoMapView: View {
    @Environment(AppModel.self) private var model

    private struct Pin: Identifiable {
        let id: URL
        let photo: Photo
        let coordinate: CLLocationCoordinate2D
    }

    private var isPhotosScope: Bool { model.committedSidebar.isPhotosLibrarySource }
    private var isLoading: Bool { isPhotosScope ? model.isLoadingAssetMap : model.isIndexingExif }

    private var pins: [Pin] {
        let source = isPhotosScope ? model.assetMapPins : model.geotaggedPhotos
        return source.map {
            Pin(id: $0.photo.url, photo: $0.photo,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
    }

    var body: some View {
        content.onAppear {
            if isPhotosScope {
                model.ensureAssetMapPins()          // background scan, streams pins
            } else {
                model.ensureExifIndex()             // file EXIF (NAS) index
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isPhotosScope {
            // Show the map immediately; pins appear (and cluster) as found.
            mapView
                .overlay(alignment: .top) { banner }
        } else if isLoading && pins.isEmpty {
            ProgressView("Reading photo locations…")
        } else if pins.isEmpty {
            ContentUnavailableView("No Locations", systemImage: "mappin.slash",
                description: Text("None of these photos contain GPS information."))
        } else {
            mapView
        }
    }

    private var mapView: some View {
        ClusteredPhotoMap(
            pins: isPhotosScope ? model.assetMapPins : model.geotaggedPhotos,
            onOpen: { model.openViewer($0) }
        )
    }

    @ViewBuilder
    private var banner: some View {
        let text: String? = {
            if isLoading { return "Finding locations… \(pins.count)" }
            if pins.isEmpty { return "No geotagged photos here" }
            if model.assetMapTruncated { return "Showing first \(AppModel.assetMapPinLimit) locations" }
            return nil
        }()
        if let text {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 10)
        }
    }
}
