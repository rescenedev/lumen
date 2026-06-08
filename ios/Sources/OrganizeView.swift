import SwiftUI
import Photos

private enum Decision: Equatable { case keep, trash, album(String) }

/// Tinder-style organize mode — full-screen photo on black. Swipe RIGHT to keep,
/// LEFT to trash, UP to file into an album. On finish it favorites the keeps,
/// adds the album picks, and deletes the rejects (system confirmation).
struct OrganizeView: View {
    let assets: [PHAsset]
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var keeps: [PHAsset] = []
    @State private var trash: [PHAsset] = []
    @State private var albumPlan: [String: [PHAsset]] = [:]   // collectionID → assets
    @State private var history: [(asset: PHAsset, decision: Decision)] = []
    @State private var showAlbumPicker = false
    @State private var tick = 0
    @State private var doneMsg = ""

    private let threshold: CGFloat = 110
    private var albumCount: Int { albumPlan.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if index >= assets.count {
                summary
            } else {
                photoLayer
                topBar
                bottomControls
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerSheet(albums: library.albums,
                             onPick: { commit(.album($0.localIdentifier), fly: CGSize(width: 0, height: -1200)) },
                             onCreate: { await library.createAlbum($0) })
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Photo (full-screen, swipeable)

    private var photoLayer: some View {
        OrganizeCard(asset: assets[index], library: library)
            .overlay(alignment: .topLeading) { stamp("보관", "heart.fill", .green, p: offset.width / threshold) }
            .overlay(alignment: .topTrailing) { stamp("삭제", "trash.fill", .red, p: -offset.width / threshold) }
            .overlay(alignment: .top) { albumStamp(p: -offset.height / threshold) }
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 26)))
            .id(index)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { v in
                        let t = v.translation
                        if t.height < -threshold, abs(t.height) > abs(t.width) {
                            withAnimation(.spring(response: 0.3)) { offset = .zero }  // hold for the picker
                            showAlbumPicker = true
                        } else if t.width > threshold { commit(.keep, fly: CGSize(width: 1000, height: t.height)) }
                        else if t.width < -threshold { commit(.trash, fly: CGSize(width: -1000, height: t.height)) }
                        else { withAnimation(.spring(response: 0.3)) { offset = .zero } }
                    }
            )
            .ignoresSafeArea()
    }

    private func stamp(_ text: String, _ icon: String, _ color: Color, p: CGFloat) -> some View {
        let v = min(max(p, 0), 1)
        return Label(text, systemImage: icon)
            .font(.headline.bold()).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color, in: Capsule()).shadow(color: color.opacity(0.6), radius: 10)
            .padding(.horizontal, 24).padding(.top, 78)
            .opacity(Double(v)).scaleEffect(0.85 + 0.15 * v)
    }

    private func albumStamp(p: CGFloat) -> some View {
        let v = min(max(p, 0), 1)
        return Label("앨범", systemImage: "rectangle.stack.badge.plus")
            .font(.headline.bold()).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.indigo, in: Capsule()).shadow(color: .indigo.opacity(0.6), radius: 10)
            .padding(.top, 110)
            .opacity(Double(v)).scaleEffect(0.85 + 0.15 * v)
    }

    // MARK: - Top bar (count is truly centered via ZStack)

    private var topBar: some View {
        VStack(spacing: 8) {
            ZStack {
                Text("\(index + 1) / \(assets.count)").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        counter("\(keeps.count)", "heart.fill", .green)
                        counter("\(albumCount)", "rectangle.stack.fill", .indigo)
                        counter("\(trash.count)", "trash.fill", .red)
                    }
                }
            }
            .padding(.horizontal, 16)
            ProgressView(value: Double(index), total: Double(max(assets.count, 1)))
                .tint(.white).padding(.horizontal, 16)
        }
        .padding(.top, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func counter(_ n: String, _ icon: String, _ color: Color) -> some View {
        Label(n, systemImage: icon).font(.caption.bold()).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        HStack(spacing: 18) {
            control("xmark", .red, d: 66) { commit(.trash, fly: CGSize(width: -1000, height: 0)) }
            control("arrow.uturn.backward", .white, d: 50) { undo() }
                .disabled(history.isEmpty).opacity(history.isEmpty ? 0.3 : 1)
            control("rectangle.stack.badge.plus", .indigo, d: 54) { showAlbumPicker = true }
            control("heart.fill", .green, d: 66) { commit(.keep, fly: CGSize(width: 1000, height: 0)) }
        }
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func control(_ icon: String, _ color: Color, d: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: d * 0.36, weight: .bold)).foregroundStyle(color)
                .frame(width: d, height: d)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 20) {
            Spacer()
            LumenGlyph(size: 76)
            Text("정리 완료").font(.title.bold()).foregroundStyle(.white).padding(.top, 6)
            Text("\(assets.count)장을 모두 살펴봤어요").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 26) {
                stat("보관", keeps.count, "heart.fill", .green)
                stat("앨범", albumCount, "rectangle.stack.fill", .indigo)
                stat("삭제", trash.count, "trash.fill", .red)
            }.padding(.vertical, 8)
            VStack(spacing: 12) {
                if !keeps.isEmpty || albumCount > 0 {
                    Button { Task { await applyNonDestructive() } } label: {
                        Label("보관·앨범 적용", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large).tint(.green)
                }
                if !trash.isEmpty {
                    Button(role: .destructive) { Task { await deleteTrash() } } label: {
                        Label("삭제 후보 \(trash.count)장 삭제", systemImage: "trash").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                }
                if !doneMsg.isEmpty {
                    Label(doneMsg, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 30)
            Spacer()
            Button("닫기") { dismiss() }.tint(.white).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ label: String, _ n: Int, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text("\(n)").font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Decisions

    private func commit(_ decision: Decision, fly: CGSize) {
        guard index < assets.count else { return }
        let a = assets[index]
        history.append((a, decision))
        switch decision {
        case .keep: keeps.append(a)
        case .trash: trash.append(a)
        case .album(let id): albumPlan[id, default: []].append(a)
        }
        tick += 1
        withAnimation(.easeOut(duration: 0.26)) { offset = fly }
        Task { try? await Task.sleep(for: .milliseconds(255)); index += 1; offset = .zero }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        let id = last.asset.localIdentifier
        switch last.decision {
        case .keep: keeps.removeAll { $0.localIdentifier == id }
        case .trash: trash.removeAll { $0.localIdentifier == id }
        case .album(let cid): albumPlan[cid]?.removeAll { $0.localIdentifier == id }
        }
        withAnimation(.spring(response: 0.3)) { index = max(0, index - 1); offset = .zero }
    }

    private func applyNonDestructive() async {
        try? await PHPhotoLibrary.shared().performChanges {
            for a in keeps { PHAssetChangeRequest(for: a).isFavorite = true }
        }
        for (id, list) in albumPlan {
            if let c = library.album(withID: id) { await library.addAssets(list, to: c) }
        }
        doneMsg = "보관·앨범 적용 완료"
    }

    private func deleteTrash() async {
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(trash as NSArray) }
            doneMsg = "삭제 완료"
        } catch { doneMsg = "삭제 취소됨" }
    }
}

/// Full-screen photo (fits the screen; black fills the rest).
struct OrganizeCard: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) { image = await library.cgImage(asset, maxPixel: 2400).map(UIImage.init) }
    }
}
