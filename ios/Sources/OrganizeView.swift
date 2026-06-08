import SwiftUI
import Photos

private enum Decision { case keep, trash }

/// What the brief centered confirmation shows after an action.
private enum Flash {
    case keep, trash, favorite
    var text: String { self == .keep ? "보관" : self == .trash ? "삭제" : "즐겨찾기" }
    var icon: String { self == .keep ? "rectangle.stack.fill" : self == .trash ? "trash.fill" : "star.fill" }
}

/// Viewer + organize. You enter as a viewer: swipe LEFT/RIGHT to browse (straight
/// line), swipe UP to favorite. Tapping "정리 시작" begins organizing from the photo
/// you're on (no need to restart from the first) — ✕/♥ appear: ♥ files into "Lumen"
/// (live), ✕ marks for deletion, applied/confirmed on the summary.
struct OrganizeView: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    var startIndex: Int = 0
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var ready = false
    @State private var organizing = false                 // viewer first, then organize
    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var decisions: [Int: Decision] = [:]   // index → keep/trash
    @State private var finished = false
    @State private var flash: Flash?                      // brief action confirmation
    @State private var tick = 0
    @State private var doneMsg = ""

    private let threshold: CGFloat = 80

    private var keepCount: Int { decisions.values.filter { $0 == .keep }.count }
    private var trashAssets: [PHAsset] { decisions.compactMap { $0.value == .trash ? assets[$0.key] : nil } }

    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            if !ready {
                ProgressView().tint(.white)
            } else if finished {
                summary
            } else {
                photoLayer
                flashOverlay
                topBar
                if organizing { bottomControls } else { startBar }
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
        .task {
            assets = await library.assets(for: scope)
            index = min(max(startIndex, 0), max(assets.count - 1, 0))
            ready = true
        }
    }

    // MARK: - Photo (full-screen, swipe = navigate)

    private var photoLayer: some View {
        OrganizeCard(asset: assets[index], library: library)
            .overlay(alignment: .top) { favoriteHint }
            .offset(offset)
            .id(index)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let dx = v.translation.width, dy = v.translation.height
                        // Straight-line motion only: horizontal for navigation, and the
                        // single exception — an upward drag — for favoriting.
                        if dy < 0 && abs(dy) > abs(dx) {
                            offset = CGSize(width: 0, height: dy)
                        } else {
                            offset = CGSize(width: dx, height: 0)
                        }
                    }
                    .onEnded { v in
                        let dx = v.translation.width, dy = v.translation.height
                        if dy < -threshold && abs(dy) > abs(dx) { favorite() }
                        else if dx < -threshold { swipeTo(next: true) }
                        else if dx > threshold { swipeTo(next: false) }
                        else { withAnimation(.spring(response: 0.3)) { offset = .zero } }
                    }
            )
            .ignoresSafeArea()
    }

    /// A star that grows as you drag up — hint that releasing favorites the photo.
    @ViewBuilder private var favoriteHint: some View {
        let p = min(max(-offset.height / threshold, 0), 1)
        if p > 0.02 {
            Label("즐겨찾기", systemImage: "star.fill")
                .font(.headline.bold()).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .padding(.top, 70)
                .opacity(Double(p)).scaleEffect(0.85 + 0.15 * p)
        }
    }

    /// Short centered confirmation after ♥ / ✕ / up-swipe.
    @ViewBuilder private var flashOverlay: some View {
        if let flash {
            Label(flash.text, systemImage: flash.icon)
                .font(.headline.bold()).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    // MARK: - Top bar (count + current photo's decision state)

    private var topBar: some View {
        ZStack {
            VStack(spacing: 6) {
                Text("\(index + 1) / \(assets.count)").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                if let d = decisions[index] {
                    Text(d == .keep ? "보관됨" : "삭제 예정").font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            HStack {
                Button { trashAssets.isEmpty ? dismiss() : finish() } label: {
                    Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Viewer "정리 시작" button (starts organizing from the current photo)

    private var startBar: some View {
        Button {
            withAnimation(.spring(response: 0.35)) { organizing = true }
        } label: {
            Text("정리 시작")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 28).padding(.vertical, 13)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Bottom controls (✕ and ♥ — decide only this photo)

    private var bottomControls: some View {
        HStack {
            control("xmark") { decide(.trash) }
            Spacer()
            control("heart.fill") { decide(.keep) }
        }
        .padding(.horizontal, 52)
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
            Text(keepCount == 0 ? "정리한 사진이 없어요"
                                : "보관한 \(keepCount)장은 Lumen 앨범에 모았어요")
                .font(.subheadline).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            HStack(spacing: 40) {
                stat("보관", keepCount, "rectangle.stack.fill")
                stat("삭제", trashAssets.count, "trash.fill")
            }.padding(.vertical, 8)
            VStack(spacing: 12) {
                if !trashAssets.isEmpty {
                    Button(role: .destructive) { Task { await deleteTrash() } } label: {
                        Label("\(trashAssets.count)장 삭제", systemImage: "trash")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    }.buttonStyle(.plain)
                }
                if !doneMsg.isEmpty {
                    Label(doneMsg, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                }
            }
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

    // MARK: - Navigation (swipe) & decisions (buttons)

    /// Move to the next/previous photo. At the last photo, a forward swipe just
    /// springs back — browsing never forces you into the summary.
    private func swipeTo(next: Bool) {
        let target = next ? index + 1 : index - 1
        guard target >= 0, target < assets.count else {
            withAnimation(.spring(response: 0.3)) { offset = .zero }; return
        }
        withAnimation(.easeOut(duration: 0.2)) { offset = CGSize(width: next ? -1000 : 1000, height: 0) }
        Task { try? await Task.sleep(for: .milliseconds(195)); index = target; offset = .zero }
    }

    /// Record a decision for the current photo, then advance. Deciding the last
    /// photo wraps up into the summary.
    private func decide(_ d: Decision) {
        guard index < assets.count else { return }
        decisions[index] = d
        if d == .keep { let a = assets[index]; Task { await library.addToLumen(a) } }   // file into Lumen, live
        tick += 1
        showFlash(d == .keep ? .keep : .trash)
        flyAndAdvance(CGSize(width: -1000, height: 0))
    }

    /// Up-swipe: mark the photo as an Apple Favorite (non-destructive, lives in the
    /// system 즐겨찾기 album), then move on. Independent of keep/trash.
    private func favorite() {
        guard index < assets.count else { return }
        let a = assets[index]
        Task { try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: a).isFavorite = true } }
        tick += 1
        showFlash(.favorite)
        flyAndAdvance(CGSize(width: 0, height: -1200))
    }

    /// Fly the current card out, then step to the next photo (or finish at the end).
    private func flyAndAdvance(_ fly: CGSize) {
        withAnimation(.easeOut(duration: 0.2)) { offset = fly }
        Task {
            try? await Task.sleep(for: .milliseconds(195))
            if index < assets.count - 1 { index += 1; offset = .zero } else { offset = .zero; finish() }
        }
    }

    private func showFlash(_ f: Flash) {
        withAnimation(.spring(response: 0.3)) { flash = f }
        Task { try? await Task.sleep(for: .milliseconds(500)); if flash == f { withAnimation { flash = nil } } }
    }

    private func finish() { withAnimation { finished = true } }

    private func deleteTrash() async {
        let targets = trashAssets
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(targets as NSArray) }
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
            Color.lumenBG
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            for await img in library.imageStream(asset, points: 1200, mode: .aspectFit) { image = img }
        }
    }
}
