import SwiftUI
import MapKit

/// Map presentation: drops a pin for every geotagged photo; clicking a pin
/// opens it in the viewer.
struct PhotoMapView: View {
    @EnvironmentObject var model: AppModel

    private struct Pin: Identifiable {
        let id: URL
        let photo: Photo
        let coordinate: CLLocationCoordinate2D
    }

    private var pins: [Pin] {
        model.geotaggedPhotos.map {
            Pin(id: $0.photo.url, photo: $0.photo,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
    }

    var body: some View {
        content.onAppear { model.ensureExifIndex() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isIndexingExif && pins.isEmpty {
            ProgressView("Reading photo locations…")
        } else if pins.isEmpty {
            ContentUnavailableView("No Locations", systemImage: "mappin.slash",
                description: Text("None of these photos contain GPS information."))
        } else {
            Map(initialPosition: .automatic) {
                ForEach(pins) { pin in
                    Annotation(pin.photo.filename, coordinate: pin.coordinate) {
                        Button {
                            model.openViewer(pin.photo)
                        } label: {
                            AsyncThumbnail(url: pin.photo.url)
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2))
                                .shadow(radius: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
        }
    }
}
