import SwiftUI
import Photos

private enum Decision { case keep, trash }

/// Tinder-style organize mode — full-screen photo on black. Swipe RIGHT to keep
/// (filed into the "Lumen" album), LEFT to mark for deletion. Minimal chrome:
/// only the count up top, ✕ and ♥ below.
struct OrganizeView: View {
    let assets: [PHAsset]
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var keeps: [PHAsset] = []
    @State private var trash: [PHAsset] = []
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
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
    }

    // MARK: - Photo (full-screen, swipeable)

    private var photoLayer: some View {
        OrganizeCard(asset: assets[index], library: library)
            .overlay(alignment: .topLeading) { stamp("보관", "rectangle.stack.fill", .green, p: offset.width / threshold) }
            .overlay(alignment: .topTrailing) { stamp("삭제", "trash.fill", .red, p: -offset.width / threshold) }
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 26)))
            .id(index)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { v in
                        if v.translation.width > threshold { commit(.keep, fly: CGSize(width: 1000, height: v.translation.height)) }
                        else if v.translation.width < -threshold { commit(.trash, fly: CGSize(width: -1000, height: v.translation.height)) }
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

    // MARK: - Top bar (only the count, centered)

    private var topBar: some View {
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
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Bottom controls (✕ and ♥)

    private var bottomControls: some View {
        HStack(spacing: 64) {
            control("xmark") { commit(.trash, fly: CGSize(width: -1000, height: 0)) }
            control("heart.fill") { commit(.keep, fly: CGSize(width: 1000, height: 0)) }
        }
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func control(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 72, height: 72)
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
            Text(keeps.isEmpty ? "\(assets.count)장을 모두 살펴봤어요"
                               : "보관한 \(keeps.count)장은 Lumen 앨범에 모았어요")
                .font(.subheadline).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            HStack(spacing: 40) {
                stat("보관", keeps.count, "rectangle.stack.fill")
                stat("삭제", trash.count, "trash.fill")
            }.padding(.vertical, 8)
            VStack(spacing: 12) {
                if !trash.isEmpty {
                    Button(role: .destructive) { Task { await deleteTrash() } } label: {
                        Label("삭제 후보 \(trash.count)장 삭제", systemImage: "trash").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large).tint(.white)
                }
                if !doneMsg.isEmpty {
                    Label(doneMsg, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 30)
            Spacer()
            Button("닫기") { dismiss() }.tint(.white).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ label: String, _ n: Int, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Color(red: 0.60, green: 0.64, blue: 0.70)).frame(height: 26)
            Text("\(n)").font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Decisions

    private func commit(_ decision: Decision, fly: CGSize) {
        guard index < assets.count else { return }
        let a = assets[index]
        switch decision {
        case .keep:
            keeps.append(a)
            Task { await library.addToLumen(a) }   // keep = file into Lumen, live
        case .trash:
            trash.append(a)
        }
        tick += 1
        withAnimation(.easeOut(duration: 0.26)) { offset = fly }
        Task { try? await Task.sleep(for: .milliseconds(255)); index += 1; offset = .zero }
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
