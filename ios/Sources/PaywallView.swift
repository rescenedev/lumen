import SwiftUI

/// Lumen Pro paywall — shown when the free daily organize quota runs out
/// (and from settings). One-time purchase, no subscription.
struct PaywallView: View {
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                LumenGlyph(size: 76)
                Text("Lumen Pro")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white).padding(.top, 18)
                Text("하루 \(OrganizeQuota.freeDailyLimit)장 한도를 모두 썼어요")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.55)).padding(.top, 6)

                VStack(spacing: 18) {
                    feature("infinity", "무제한 정리", "매일 한도 없이 원하는 만큼")
                    feature("creditcard.fill", "한 번만 결제", "구독 아님 — 평생 소장")
                    feature("person.2.fill", "가족 공유", "Apple 가족 공유 지원")
                }
                .padding(.top, 34).padding(.horizontal, 34)

                Spacer()

                Button {
                    Task { if await store.purchase() { dismiss() } }
                } label: {
                    Text(store.purchasing ? "" : buyTitle).font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .overlay { if store.purchasing { ProgressView().tint(.white) } }
                }
                .background(heroGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .disabled(store.product == nil || store.purchasing)
                .opacity(store.product == nil ? 0.5 : 1)

                Button("구매 복원") {
                    Task { await store.restore(); if store.isPro { dismiss() } }
                }
                .font(.footnote).foregroundStyle(.white.opacity(0.5)).padding(.top, 14)

                Button("나중에") { dismiss() }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 10).padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var buyTitle: String {
        if let p = store.product { return "\(p.displayPrice)에 평생 이용" }
        return "잠시 후 다시 시도해 주세요"
    }

    private func feature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
    }
}
