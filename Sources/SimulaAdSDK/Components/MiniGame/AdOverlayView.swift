import SwiftUI

// MARK: - AdOverlayView

/// Full-screen overlay that displays an ad iframe after a minigame session.
/// Translates Kotlin's `AdIframeOverlay` composable from `MiniGameMenu.kt`.
///
/// Features:
/// - Full-screen dark overlay (matching Kotlin's Color(0xCC000000))
/// - 5-second countdown timer with animated ring before close button appears
/// - Close button (top-right, dark-translucent circle with a white ✕) after countdown
/// - WKWebView loading the ad iframe URL
/// - Bottom sheet mode support (uses last game height/border color)
/// - Status bar hiding when full screen or near full screen
public struct AdOverlayView: View {
    let iframeUrl: String
    let onClose: () -> Void
    /// Height from the last game session (if bottom sheet mode). nil = fullscreen.
    var playableHeightDp: CGFloat?
    /// Border color for bottom sheet drag handle area.
    var playableBorderColor: String = "#262626"
    /// Impression id this overlay reports against (the ad that led here). Empty hides the info button.
    var adId: String = ""

    @State private var appeared = false
    /// Countdown seconds remaining (starts at 5)
    @State private var adCountdown: Int = 5
    /// Ring progress (0.0 = empty, 1.0 = full) — fills clockwise from the top
    /// (right to left) over the countdown.
    @State private var ringProgress: CGFloat = 0.0
    /// The running countdown ticker. Held so it starts once and is cancelled on disappear, so it
    /// can't outlive the overlay (or be double-started by a re-`onAppear`).
    @State private var countdownTask: Task<Void, Never>?
    /// Top safe-area inset captured once on appear (full-screen only), so the content insets below
    /// the status bar / notch without re-reading the window on every body pass.
    @State private var topSafeInset: CGFloat = 0

    private var isBottomSheet: Bool {
        guard let h = playableHeightDp else { return false }
        // Match React Native: >= 95% of screen treated as full screen (no bottom sheet UI)
        return h < screenHeight * 0.95
    }

    private var screenHeight: CGFloat {
        #if os(iOS)
        simulaScreenSize().height
        #else
        768
        #endif
    }

    private var shouldHideStatusBar: Bool {
        if isBottomSheet {
            return (playableHeightDp ?? 0) >= screenHeight * 0.95
        }
        return true
    }

    public var body: some View {
        ZStack {
            // Backdrop: fully black full-screen (so the end screen's safe area is solid
            // black, matching Android); the in-game bottom sheet keeps 80% to show the
            // paused game behind it (matching Kotlin's Color(0xCC000000)).
            Color.black.opacity(isBottomSheet ? 0.8 : 1.0)
                .ignoresSafeArea()
                .onTapGesture {
                    if adCountdown <= 0 { onClose() }
                }

            // Content: bottom sheet or fullscreen (GeometryReader layout matches GameIframeView)
            GeometryReader { geo in
                VStack(spacing: 0) {
                    // Visual-only drag handle for bottom sheet mode (no gesture, matching Kotlin)
                    if isBottomSheet {
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 40, height: 4)
                                .padding(.vertical, 12)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: playableBorderColor))
                        .clipShape(TopRoundedRectangle(radius: 16))
                    }

                    // Main content area
                    ZStack {
                        // Ad iframe
                        if let url = URL(string: iframeUrl) {
                            WebViewRepresentable(url: url)
                        }

                        // Close button / countdown ring — top right
                        VStack {
                            HStack {
                                Spacer()
                                if adCountdown <= 0 {
                                    // Compact close button, matching the interstitial/rewarded default
                                    // (a ~16pt dark-translucent circle with a white X). Visible glyph
                                    // stays small; the hit area is a full 44pt touch target.
                                    Button(action: onClose) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 16, height: 16)
                                            .background(
                                                Circle()
                                                    .fill(Color.black.opacity(0.5))
                                            )
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(CloseButtonStyle())
                                    .padding(.top, 8)
                                    .padding(.trailing, 8)
                                    .accessibilityLabel("Close ad")
                                } else {
                                    // Countdown ring, sized to the same compact footprint (16pt circle
                                    // centered in the same 44pt frame so nothing jumps when it unlocks).
                                    ZStack {
                                        Circle()
                                            .fill(Color.black.opacity(0.4))
                                            .frame(width: 16, height: 16)

                                        Circle()
                                            .trim(from: 0, to: ringProgress)
                                            .stroke(
                                                Color.white,
                                                style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                            )
                                            .frame(width: 12, height: 12)
                                            .rotationEffect(.degrees(-90))

                                        Text("\(adCountdown)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    .frame(width: 44, height: 44)
                                    .padding(.top, 8)
                                    .padding(.trailing, 8)
                                }
                            }
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // Full-screen ads inset the creative + close button below the top safe area
                    // (status bar / notch / Dynamic Island). Bottom-sheet mode keeps its own bounds.
                    .padding(.top, isBottomSheet ? 0 : topSafeInset)
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                // Height on outer VStack (handle + content) — matches GameIframeView
                .frame(height: isBottomSheet ? playableHeightDp : geo.size.height)
                // Pin to bottom of screen
                .offset(y: isBottomSheet ? geo.size.height - (playableHeightDp ?? geo.size.height) : 0)
            }
            .ignoresSafeArea()

            // Persistent ad-info "i" + report sheet (required disclosure on the fallback / post-game ad).
            // This overlay ignores the safe area, so use a larger corner inset to keep the "i" clear
            // of the screen's rounded bottom-left corner (where it would otherwise be clipped).
            #if os(iOS)
            if !adId.isEmpty {
                AdInfoReportOverlay(adId: adId, cornerInset: 18)
            }
            #endif
        }
        .ignoresSafeArea()
        .hideStatusBar(shouldHideStatusBar)
        .opacity(appeared ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: appeared)
        .onAppear {
            appeared = true
            topSafeInset = isBottomSheet ? 0 : simulaTopSafeAreaInset()
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
            countdownTask = nil
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        // Start exactly once; a re-`onAppear` (or a SwiftUI double-fire) must not restart it.
        guard countdownTask == nil else { return }

        let total = adCountdown

        // Fill the ring linearly over the countdown (matching Kotlin's tween).
        withAnimation(.linear(duration: Double(total))) {
            ringProgress = 1
        }

        // Tick once per second on the main actor. A cancellable Task (vs. fire-and-forget
        // asyncAfter) means a dismiss stops it cleanly and it can't be silently dropped.
        countdownTask = Task { @MainActor in
            for remaining in stride(from: total - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                adCountdown = remaining
            }
        }
    }
}



