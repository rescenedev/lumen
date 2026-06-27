import SwiftUI
import MapKit

/// Map presentation: drops a pin for every geotagged photo; clicking a pin
/// opens it in the viewer. For a Photos-library scope the (potentially huge)
/// location scan runs in the background and pins stream in progressively, so the
/// map shows immediately instead of freezing.
struct PhotoMapView: View {
    @Environment(AppModel.self) private var model

    private var isPhotosScope: Bool { model.committedSidebar.isPhotosLibrarySource }
    private var isLoading: Bool { isPhotosScope ? model.isLoadingAssetMap : model.isIndexingExif }

    // Count/emptiness only — the map itself renders model.assetMapPins /
    // model.geotaggedPhotos directly, so we never build an intermediate [Pin]
    // array (which previously re-allocated the whole 60k set just to read .count).
    private var locationCount: Int { isPhotosScope ? model.assetMapPins.count : model.geotaggedPhotos.count }
    private var hasLocations: Bool { isPhotosScope ? !model.assetMapPins.isEmpty : !model.geotaggedPhotos.isEmpty }

    var body: some View {
        // Keyed on assetMapScanToken (scope + sort-settle), not onAppear: the view
        // isn't recreated when navigating between scopes, and a large scope's sort
        // lands without changing the signature — both must re-run the scan, or the
        // map stays stuck on the previous/empty pin set.
        content.task(id: model.assetMapScanToken) {
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
        } else if isLoading && !hasLocations {
            ProgressView("Reading photo locations…")
        } else if !hasLocations {
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
            if isLoading { return "Finding locations… \(locationCount)" }
            if !hasLocations { return "No geotagged photos here" }
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
