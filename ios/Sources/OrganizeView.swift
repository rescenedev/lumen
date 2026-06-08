import SwiftUI
import Photos

/// Tinder-style organize mode — the app's hero. Swipe RIGHT to keep, LEFT to mark
/// for deletion. Premium feel: progress bar, photo date, swipe stamps, haptics.
/// On finish it favorites the keeps and deletes the rejects (system confirmation).
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
        NavigationStack {
            Group {
                if index >= assets.count { summary }
                else {
                    VStack(spacing: 0) {
                        progress
                        cardArea
                        controls
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if index < assets.count {
                        Text("\(index + 1) / \(assets.count)").font(.subheadline.monospacedDigit().weight(.medium))
                    }
                }
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
    }

    // MARK: - Progress

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(heroGradient)
                    .frame(width: geo.size.width * CGFloat(index) / CGFloat(max(assets.count, 1)))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 16).padding(.top, 4)
        .animation(.easeOut, value: index)
    }

    // MARK: - Card stack

    private var cardArea: some View {
        ZStack {
            if index + 1 < assets.count {
                OrganizeCard(asset: assets[index + 1], library: library)
                    .scaleEffect(0.95).opacity(0.5).offset(y: 10)
            }
            OrganizeCard(asset: assets[index], library: library)
                .overlay(alignment: .topLeading) { stamp("보관", "heart.fill", .green, p: offset.width / threshold) }
                .overlay(alignment: .topTrailing) { stamp("삭제", "trash.fill", .red, p: -offset.width / threshold) }
                .offset(offset)
                .rotationEffect(.degrees(Double(offset.width / 22)))
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
            if history.isEmpty { hint }   // first-card guidance
        }
        .padding(.horizontal, 16).padding(.top, 10)
        .frame(maxHeight: .infinity)
    }

    private var hint: some View {
        HStack {
            Label("삭제", systemImage: "arrow.left").foregroundStyle(.red)
            Spacer()
            Label("보관", systemImage: "arrow.right").environment(\.layoutDirection, .rightToLeft).foregroundStyle(.green)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 24).padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private func stamp(_ text: String, _ icon: String, _ color: Color, p: CGFloat) -> some View {
        let v = min(max(p, 0), 1)
        return Label(text, systemImage: icon)
            .font(.headline.bold()).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color, in: Capsule())
            .shadow(color: color.opacity(0.5), radius: 8)
            .padding(22)
            .opacity(Double(v)).scaleEffect(0.85 + 0.15 * v)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 22) {
            control("xmark", "삭제", .red, big: true) { decide(keep: false) }
            control("arrow.uturn.backward", "되돌리기", .secondary, big: false) { undo() }
                .disabled(history.isEmpty).opacity(history.isEmpty ? 0.35 : 1)
            control("heart.fill", "보관", .green, big: true) { decide(keep: true) }
        }
        .padding(.top, 8).padding(.bottom, 20)
    }

    private func control(_ icon: String, _ label: String, _ color: some ShapeStyle, big: Bool,
                         _ action: @escaping () -> Void) -> some View {
        let d: CGFloat = big ? 66 : 52
        return VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: d * 0.36, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: d, height: d)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 22) {
            Spacer()
            LumenGlyph(size: 76)
            Text("정리 완료").font(.title.bold()).padding(.top, 6)
            Text("\(assets.count)장을 모두 살펴봤어요").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 40) {
                stat("보관", keeps.count, "heart.fill", .pink)
                stat("삭제 후보", trash.count, "trash.fill", .red)
            }.padding(.vertical, 8)
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
                    Label(doneMsg, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 30)
            Spacer()
            Button("닫기") { dismiss() }.padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ label: String, _ n: Int, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text("\(n)").font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
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

/// A single photo card with a date chip over a bottom scrim.
struct OrganizeCard: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.fill.tertiary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
            if let date = asset.creationDate {
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .task(id: asset.localIdentifier) { image = await library.thumbnail(asset, points: 560) }
    }
}
