import SwiftUI
import Photos

/// Tinder-style organize mode: one photo at a time, swipe RIGHT to keep, LEFT to
/// mark for deletion. Fast triage for people who hate sorting photos. At the end,
/// favorites the keeps and deletes the rejects (with the system confirmation).
struct OrganizeView: View {
    let assets: [PHAsset]
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var keeps: [PHAsset] = []
    @State private var trash: [PHAsset] = []
    @State private var history: [(asset: PHAsset, kept: Bool)] = []
    @State private var doneMsg = ""

    private let threshold: CGFloat = 110

    var body: some View {
        ZStack {
            LumenBackground()
            VStack(spacing: 0) {
                topBar
                if index >= assets.count { summary }
                else { cardArea; controls }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(.white.opacity(0.8)) }
            Spacer()
            if index < assets.count {
                Text("\(index + 1) / \(assets.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            HStack(spacing: 12) {
                Label("\(keeps.count)", systemImage: "heart.fill").foregroundStyle(.green)
                Label("\(trash.count)", systemImage: "trash.fill").foregroundStyle(.red.opacity(0.9))
            }.font(.caption.bold())
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: - Card stack

    private var cardArea: some View {
        ZStack {
            if index + 1 < assets.count {
                OrganizeCard(asset: assets[index + 1], library: library)
                    .scaleEffect(0.94).opacity(0.55)
            }
            OrganizeCard(asset: assets[index], library: library)
                .overlay(alignment: .topLeading) { stamp("보관", .green, show: offset.width > 0, p: offset.width / threshold) }
                .overlay(alignment: .topTrailing) { stamp("삭제", .red, show: offset.width < 0, p: -offset.width / threshold) }
                .offset(offset)
                .rotationEffect(.degrees(Double(offset.width / 18)))
                .gesture(
                    DragGesture()
                        .onChanged { offset = $0.translation }
                        .onEnded { v in
                            if v.translation.width > threshold { decide(keep: true) }
                            else if v.translation.width < -threshold { decide(keep: false) }
                            else { withAnimation(.spring(response: 0.3)) { offset = .zero } }
                        }
                )
                .id(index)
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    private func stamp(_ text: String, _ color: Color, show: Bool, p: CGFloat) -> some View {
        Text(text).font(.system(size: 30, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color, lineWidth: 4))
            .rotationEffect(.degrees(text == "보관" ? -16 : 16))
            .padding(28)
            .opacity(show ? Double(min(max(p, 0), 1)) : 0)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 28) {
            roundButton("xmark", .red) { decide(keep: false) }
            roundButton("arrow.uturn.backward", .gray, small: true) { undo() }.disabled(history.isEmpty)
            roundButton("heart.fill", .green) { decide(keep: true) }
        }
        .padding(.bottom, 28).padding(.top, 6)
    }

    private func roundButton(_ icon: String, _ color: Color, small: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: small ? 20 : 26, weight: .bold)).foregroundStyle(color)
                .frame(width: small ? 52 : 66, height: small ? 52 : 66)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5))
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(brandGradient)
            Text("정리 완료!").font(.title.bold()).foregroundStyle(.white)
            HStack(spacing: 28) {
                stat("보관", keeps.count, .green)
                stat("삭제 후보", trash.count, .red)
            }
            VStack(spacing: 12) {
                if !keeps.isEmpty {
                    Button { Task { await favoriteKeeps() } } label: {
                        Label("보관 \(keeps.count)장 즐겨찾기", systemImage: "heart.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.green)
                    }
                }
                if !trash.isEmpty {
                    Button { Task { await deleteTrash() } } label: {
                        Label("삭제 후보 \(trash.count)장 삭제", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.red)
                    }
                }
                if !doneMsg.isEmpty { Text(doneMsg).font(.caption).foregroundStyle(.white.opacity(0.6)) }
            }
            .padding(.horizontal, 30)
            Spacer()
            Button("닫기") { dismiss() }.foregroundStyle(.white.opacity(0.7)).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(n)").font(.system(size: 36, weight: .heavy, design: .rounded)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Decisions

    private func decide(keep: Bool) {
        guard index < assets.count else { return }
        let a = assets[index]
        history.append((a, keep))
        if keep { keeps.append(a) } else { trash.append(a) }
        withAnimation(.easeOut(duration: 0.26)) { offset.width = keep ? 1000 : -1000 }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            index += 1
            offset = .zero
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        let id = last.asset.localIdentifier
        if last.kept { keeps.removeAll { $0.localIdentifier == id } }
        else { trash.removeAll { $0.localIdentifier == id } }
        withAnimation(.spring(response: 0.3)) { index = max(0, index - 1); offset = .zero }
    }

    private func favoriteKeeps() async {
        try? await PHPhotoLibrary.shared().performChanges {
            for a in keeps { PHAssetChangeRequest(for: a).isFavorite = true }
        }
        doneMsg = "보관 \(keeps.count)장 즐겨찾기 완료 ✓"
    }

    private func deleteTrash() async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(trash as NSArray)
            }
            doneMsg = "삭제 완료 ✓"
        } catch {
            doneMsg = "삭제 취소됨"
        }
    }
}

/// A single photo card for organize mode.
struct OrganizeCard: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.05))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .task(id: asset.localIdentifier) { image = await library.thumbnail(asset, points: 520) }
    }
}
