#if os(iOS)
import SwiftUI

// MARK: - AdInfoReportOverlay

/// Persistent in-ad info ("i") affordance + report sheet — required ad disclosure on every ad
/// surface (Apple/Google expectations; advertisers expect a working report path). The small "i"
/// sits in a corner; tapping it opens a sheet with "Why this ad?", "About this advertiser", and a
/// report flow whose submission posts to `POST /impressions/{adId}/report`, tagged by impression id.
///
/// Reusable across surfaces — drop it into any ad's `ZStack` (last, so the sheet covers the rest).
struct AdInfoReportOverlay: View {
    let adId: String
    /// Optional override; falls back to the initialized SDK key when nil.
    var apiKey: String?
    /// Advertiser descriptor (e.g. the creative bundle URL) shown under "About this advertiser".
    var advertiser: String?
    /// Set when the close button also lives bottom-left: keeps the "i" hit area vertical-only so it
    /// doesn't swallow taps meant for the close button sitting right beside it.
    var closeAtBottomLeft: Bool = false
    /// Inset of the "i" from the corner. Larger on full-screen overlays that ignore the safe area
    /// (e.g. the post-game / fallback ad), so the glyph clears the screen's rounded corner.
    var cornerInset: CGFloat = 6

    @State private var sheetVisible = false
    private let api = SimulaAPI()

    var body: some View {
        ZStack {
            // Persistent "i"-in-a-circle — bottom-left corner (AdChoices convention), tight to the edge.
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sheetVisible = true } }) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.5))
                    Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    Text("i").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                }
                .frame(width: 16, height: 16)
                // Visible glyph stays 16; the hit area is enlarged (up, plus right when there's room)
                // with the glyph pinned to the corner so it keeps hugging the edge.
                .frame(width: closeAtBottomLeft ? 16 : 44, height: 44, alignment: .bottomLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ad info and report")
            .padding(cornerInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            if sheetVisible {
                AdReportSheet(
                    advertiser: advertiser,
                    onSubmit: { reason, note in
                        let api = self.api
                        let adId = self.adId
                        let apiKey = self.apiKey ?? SimulaAds.shared?.apiKey ?? ""
                        let flag = reason.flag
                        Task { await api.reportAd(adId: adId, flag: flag, note: note, apiKey: apiKey) }
                    },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { sheetVisible = false } }
                )
                .transition(.opacity)
            }
        }
    }
}

// MARK: - AdReportSheet

/// The modal shown when the "i" is tapped: ad info, then a report reason picker, then a confirmation.
private struct AdReportSheet: View {
    var advertiser: String?
    let onSubmit: (AdReportReason, String?) -> Void
    let onClose: () -> Void

    private enum Phase { case info, reasons, done }
    @State private var phase: Phase = .info

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            card
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(hex: "#1C1C1E")))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)

            switch phase {
            case .info:
                Text("About this ad")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                infoRow(
                    title: "Why this ad?",
                    body: "This ad was selected for you by Simula based on the app you're using."
                )
                infoRow(
                    title: "About this advertiser",
                    body: (advertiser?.isEmpty == false ? advertiser : nil)
                        ?? "Advertiser details aren't available for this ad."
                )
                actionRow(icon: "flag", text: "Report this ad", chevron: true) { phase = .reasons }
            case .reasons:
                HStack(spacing: 8) {
                    Button(action: { phase = .info }) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    Text("Report this ad").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                }
                ForEach(AdReportReason.allCases, id: \.self) { reason in
                    actionRow(icon: nil, text: reason.label, chevron: false) {
                        onSubmit(reason, nil)
                        phase = .done
                    }
                }
            case .done:
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundColor(.green)
                    Text("Report received").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    Text("Thanks — our team will review this ad.")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                    Button(action: onClose) {
                        Text("Done").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .animation(.easeInOut(duration: 0.15), value: phase)
    }

    private func infoRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            Text(body).font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
        }
    }

    private func actionRow(icon: String?, text: String, chevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(text).font(.system(size: 15, weight: .semibold))
                Spacer()
                if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).opacity(0.6) }
            }
            .foregroundColor(.white)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
#endif
