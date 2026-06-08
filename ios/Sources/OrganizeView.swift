import SwiftUI
import Photos

/// Tinder-style organize mode — full-screen immersive photo on black. Swipe RIGHT
/// to keep, LEFT to mark for deletion. The photo fits the screen (whole image,
/// black letterbox where it doesn't fill). On finish it favorites the keeps and
/// deletes the rejects (system confirmation).
struct OrganizeView: View {
    let assets: [PHAsset]
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var keeps: [PHAsset] = []
    @State private var trash: [PHAsset] = []
    @State private var history: [(asset: PHAsset, kept: Bool)] = []
    @State private var tick = 0
    @State private var doneMsg = ""

    private let threshold: CGFloat = 110

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
        .statusBarHidden(false)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
    }

    // MARK: - Photo (full-screen, swipeable)

    private var photoLayer: some View {
        OrganizeCard(asset: assets[index], library: library)
            .overlay(alignment: .topLeading) { stamp("보관", "heart.fill", .green, p: offset.width / threshold) }
            .overlay(alignment: .topTrailing) { stamp("삭제", "trash.fill", .red, p: -offset.width / threshold) }
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 26)))
            .id(index)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { v in
                        if v.translation.width > threshold { decide(keep: true) }
                        else if v.translation.width < -threshold { decide(keep: false) }
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
            .background(color, in: Capsule())
            .shadow(color: color.opacity(0.6), radius: 10)
            .padding(.horizontal, 24).padding(.top, 70)
            .opacity(Double(v)).scaleEffect(0.85 + 0.15 * v)
    }

    // MARK: - Top bar (overlaid)

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text("\(index + 1) / \(assets.count)").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                HStack(spacing: 10) {
                    counter("\(keeps.count)", "heart.fill", .green)
                    counter("\(trash.count)", "trash.fill", .red)
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

    // MARK: - Bottom controls (overlaid)

    private var bottomControls: some View {
        HStack(spacing: 24) {
            control("xmark", .red, big: true) { decide(keep: false) }
            control("arrow.uturn.backward", .white, big: false) { undo() }
                .disabled(history.isEmpty).opacity(history.isEmpty ? 0.3 : 1)
            control("heart.fill", .green, big: true) { decide(keep: true) }
        }
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func control(_ icon: String, _ color: Color, big: Bool, _ action: @escaping () -> Void) -> some View {
        let d: CGFloat = big ? 68 : 54
        return Button(action: action) {
            Image(systemName: icon).font(.system(size: d * 0.38, weight: .bold)).foregroundStyle(color)
                .frame(width: d, height: d)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 22) {
            Spacer()
            LumenGlyph(size: 76)
            Text("정리 완료").font(.title.bold()).foregroundStyle(.white).padding(.top, 6)
            Text("\(assets.count)장을 모두 살펴봤어요").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 40) {
                stat("보관", keeps.count, "heart.fill", .green)
                stat("삭제 후보", trash.count, "trash.fill", .red)
            }.padding(.vertical, 8)
            VStack(spacing: 12) {
                if !keeps.isEmpty {
                    Button { Task { await favoriteKeeps() } } label: {
                        Label("보관 \(keeps.count)장 즐겨찾기", systemImage: "heart").frame(maxWidth: .infinity)
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
            Text("\(n)").font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Decisions

    private func decide(keep: Bool) {
        guard index < assets.count else { return }
        let a = assets[index]
        history.append((a, keep)); if keep { keeps.append(a) } else { trash.append(a) }
        tick += 1
        withAnimation(.easeOut(duration: 0.26)) { offset.width = keep ? 1000 : -1000 }
        Task { try? await Task.sleep(for: .milliseconds(255)); index += 1; offset = .zero }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        let id = last.asset.localIdentifier
        if last.kept { keeps.removeAll { $0.localIdentifier == id } } else { trash.removeAll { $0.localIdentifier == id } }
        withAnimation(.spring(response: 0.3)) { index = max(0, index - 1); offset = .zero }
    }

    private func favoriteKeeps() async {
        try? await PHPhotoLibrary.shared().performChanges {
            for a in keeps { PHAssetChangeRequest(for: a).isFavorite = true }
        }
        doneMsg = "즐겨찾기 \(keeps.count)장 완료"
    }

    private func deleteTrash() async {
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(trash as NSArray) }
            doneMsg = "삭제 완료"
        } catch { doneMsg = "삭제 취소됨" }
    }
}

/// Full-screen photo (fits the screen; black fills the rest). Loads progressively.
struct OrganizeCard: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            image = await library.cgImage(asset, maxPixel: 2400).map(UIImage.init)
        }
    }
}
