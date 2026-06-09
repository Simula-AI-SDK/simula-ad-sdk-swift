#if os(iOS)
import SwiftUI

// MARK: - AdInfoReportOverlay

/// Persistent in-ad info ("i") affordance + report sheet — required ad disclosure on every ad
/// surface (Apple/Google expectations; advertisers expect a working report path). The small "i"
/// sits in a corner; tapping it opens an AppLovin-style menu (Interested / Not interested / Report)
/// plus an "About Simula Ads" link. Feedback and report selections post to
/// `POST /impressions/{adId}/report`, tagged by impression id.
///
/// Reusable across surfaces — drop it into any ad's `ZStack` (last, so the sheet covers the rest).
struct AdInfoReportOverlay: View {
    let adId: String
    /// Optional override; falls back to the initialized SDK key when nil.
    var apiKey: String?
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
                    onReport: { flag in submit(flag: flag) },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { sheetVisible = false } }
                )
                .transition(.opacity)
            }
        }
    }

    /// Best-effort feedback/report post (silent-fail), tagged by impression id.
    private func submit(flag: String) {
        let api = self.api
        let adId = self.adId
        let apiKey = self.apiKey ?? SimulaAds.shared?.apiKey ?? ""
        Task { await api.reportAd(adId: adId, flag: flag, note: nil, apiKey: apiKey) }
    }
}

// MARK: - AdReportSheet

/// AppLovin-style ad-feedback menu shown when the "i" is tapped: Interested / Not interested /
/// Report (which expands to reason codes), plus a separate "About Simula Ads" link to simula.ad.
/// `onReport` posts the chosen flag; `onClose` dismisses.
private struct AdReportSheet: View {
    let onReport: (String) -> Void
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL
    private enum Phase { case menu, reasons, done }
    @State private var phase: Phase = .menu

    /// Where "About Simula Ads" sends the user.
    private let aboutURL = URL(string: "https://simula.ad")
    private let cardColor = Color(hex: "#2C2C2E")
    private let reportTint = Color(hex: "#FF453A")

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 10) {
                card
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).fill(cardColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                // Separate "About Simula Ads" pill (only on the top-level menu), opens simula.ad.
                if phase == .menu {
                    aboutPill
                }
            }
            // Size the menu to its widest row (+ padding), left-aligned, rather than the full width.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.15), value: phase)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch phase {
        case .menu:
            VStack(alignment: .leading, spacing: 0) {
                menuRow(icon: "checkmark", text: "Interested") {
                    onReport("interested"); phase = .done
                }
                divider
                menuRow(icon: "xmark", text: "Not interested") {
                    // "Not interested" maps to the existing `dislike` flag (BE adds `interested` later).
                    onReport("dislike"); phase = .done
                }
                divider
                menuRow(icon: "flag.fill", text: "Report", tint: reportTint) {
                    phase = .reasons
                }
            }
        case .reasons:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: { phase = .menu }) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    Text("Report this ad").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                divider
                let reasons = Array(AdReportReason.allCases.enumerated())
                ForEach(reasons, id: \.element) { index, reason in
                    menuRow(icon: nil, text: reason.label) {
                        onReport(reason.flag); phase = .done
                    }
                    if index < reasons.count - 1 { divider }
                }
            }
        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 32)).foregroundColor(.green)
                Text("Thanks for your feedback").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                Text("We use it to show you better ads.")
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button(action: onClose) {
                    Text("Done").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain).padding(.top, 6)
            }
            .padding(18)
        }
    }

    private var aboutPill: some View {
        Button(action: {
            if let aboutURL { openURL(aboutURL) }
            onClose()
        }) {
            HStack(spacing: 14) {
                Image(systemName: "info.circle").font(.system(size: 18))
                Text("About Simula Ads").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(cardColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About Simula Ads")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
    }

    private func menuRow(icon: String?, text: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(width: 22)
                Text(text).font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .foregroundColor(tint)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
