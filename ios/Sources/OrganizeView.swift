import SwiftUI
import Photos

/// Tinder-style organize mode: swipe RIGHT to keep, LEFT to mark for deletion.
/// Native chrome — nav bar, system materials, SF Symbols, haptics. On finish it
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
    @State private var tick = 0          // drives haptics on each decision
    @State private var doneMsg = ""

    private let threshold: CGFloat = 110

    var body: some View {
        NavigationStack {
            Group {
                if index >= assets.count { summary }
                else {
                    VStack(spacing: 0) {
                        cardArea
                        controls
                    }
                }
            }
            .navigationTitle(index < assets.count ? "\(index + 1) / \(assets.count)" : "정리 완료")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Label("\(keeps.count)", systemImage: "heart.fill").foregroundStyle(.pink)
                        Label("\(trash.count)", systemImage: "trash.fill").foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
    }

    // MARK: - Card stack

    private var cardArea: some View {
        ZStack {
            if index + 1 < assets.count {
                OrganizeCard(asset: assets[index + 1], library: library)
                    .scaleEffect(0.95).opacity(0.6)
            }
            OrganizeCard(asset: assets[index], library: library)
                .overlay(alignment: .topLeading) { stamp("보관", "heart.fill", .green, show: offset.width, sign: 1) }
                .overlay(alignment: .topTrailing) { stamp("삭제", "trash.fill", .red, show: offset.width, sign: -1) }
                .offset(offset)
                .rotationEffect(.degrees(Double(offset.width / 20)))
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
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxHeight: .infinity)
    }

    private func stamp(_ text: String, _ icon: String, _ color: Color, show: CGFloat, sign: CGFloat) -> some View {
        let p = min(max(sign * show / threshold, 0), 1)
        return Label(text, systemImage: icon)
            .font(.headline).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color, in: Capsule())
            .padding(22)
            .opacity(Double(p))
            .scaleEffect(0.9 + 0.1 * p)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 26) {
            circle("xmark", .red, size: 64) { decide(keep: false) }
            circle("arrow.uturn.backward", .secondary, size: 50) { undo() }
                .disabled(history.isEmpty).opacity(history.isEmpty ? 0.4 : 1)
            circle("heart.fill", .green, size: 64) { decide(keep: true) }
        }
        .padding(.vertical, 18)
    }

    private func circle(_ icon: String, _ color: some ShapeStyle, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.tint)
            Text("정리 완료").font(.title.bold())
            HStack(spacing: 36) {
                stat("보관", keeps.count, "heart.fill", .pink)
                stat("삭제 후보", trash.count, "trash.fill", .secondary)
            }
            VStack(spacing: 12) {
                if !keeps.isEmpty {
                    Button { Task { await favoriteKeeps() } } label: {
                        Label("보관 \(keeps.count)장 즐겨찾기", systemImage: "heart").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large).tint(.pink)
                }
                if !trash.isEmpty {
                    Button(role: .destructive) { Task { await deleteTrash() } } label: {
                        Label("삭제 후보 \(trash.count)장 삭제", systemImage: "trash").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                }
                if !doneMsg.isEmpty {
                    Label(doneMsg, systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            Spacer()
            Button("닫기") { dismiss() }.padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ label: String, _ n: Int, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text("\(n)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Decisions

    private func decide(keep: Bool) {
        guard index < assets.count else { return }
        let a = assets[index]
        history.append((a, keep))
        if keep { keeps.append(a) } else { trash.append(a) }
        tick += 1
        withAnimation(.easeOut(duration: 0.26)) { offset.width = keep ? 1000 : -1000 }
        Task {
            try? await Task.sleep(for: .milliseconds(255))
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
        doneMsg = "즐겨찾기 \(keeps.count)장 완료"
    }

    private func deleteTrash() async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(trash as NSArray)
            }
            doneMsg = "삭제 완료"
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
            RoundedRectangle(cornerRadius: 20).fill(.fill.tertiary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        .task(id: asset.localIdentifier) { image = await library.thumbnail(asset, points: 520) }
    }
}
