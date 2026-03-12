import SwiftUI

// MARK: - AdOverlayView

/// Full-screen overlay that displays an ad iframe after a minigame session.
/// Translates Kotlin's `AdIframeOverlay` composable from `MiniGameMenu.kt`.
///
/// Features:
/// - Full-screen dark overlay (matching Kotlin's Color(0xCC000000))
/// - 5-second countdown timer with animated ring before close button appears
/// - Close button (top-right, white circle with × symbol) after countdown
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

    @State private var appeared = false
    /// Countdown seconds remaining (starts at 5)
    @State private var adCountdown: Int = 5
    /// Ring progress (1.0 = full, 0.0 = empty)
    @State private var ringProgress: CGFloat = 1.0

    private var isBottomSheet: Bool {
        guard let h = playableHeightDp else { return false }
        // Match React Native: >= 95% of screen treated as full screen (no bottom sheet UI)
        return h < screenHeight * 0.95
    }

    private var screenHeight: CGFloat {
        #if os(iOS)
        UIScreen.main.bounds.height
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
            // Backdrop (matching Kotlin: Color(0xCC000000) = 80% black)
            Color.black.opacity(0.8)
                .ignoresSafeArea()
                .onTapGesture {
                    if adCountdown <= 0 { onClose() }
                }

            // Content: bottom sheet or fullscreen
            VStack(spacing: 0) {
                if isBottomSheet {
                    Spacer()
                }

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
                                // Close button (matching React Native's CloseButton style)
                                Button(action: onClose) {
                                    Text("\u{00D7}")
                                        .font(.system(size: 18, weight: .regular))
                                        .foregroundColor(.white)
                                        .frame(width: 32, height: 32)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.6))
                                        )
                                }
                                .buttonStyle(AdCloseButtonStyle())
                                .padding(.top, 16)
                                .padding(.trailing, 16)
                                .accessibilityLabel("Close ad")
                            } else {
                                // Countdown ring
                                ZStack {
                                    Circle()
                                        .fill(Color.black.opacity(0.4))
                                        .frame(width: 32, height: 32)

                                    Circle()
                                        .trim(from: 1 - ringProgress, to: 1)
                                        .stroke(
                                            Color.white,
                                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                        )
                                        .frame(width: 26, height: 26)
                                        .rotationEffect(.degrees(-90))

                                    Text("\(adCountdown)")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 32, height: 32)
                                .padding(.top, 16)
                                .padding(.trailing, 16)
                            }
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: isBottomSheet ? playableHeightDp : nil)
                .frame(maxHeight: isBottomSheet ? nil : .infinity)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .hideStatusBar(shouldHideStatusBar)
        .opacity(appeared ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: appeared)
        .onAppear {
            print("[AdOverlayView] playableHeightDp=\(String(describing: playableHeightDp)), screenHeight=\(screenHeight), isBottomSheet=\(isBottomSheet), shouldHideStatusBar=\(shouldHideStatusBar)")
            appeared = true
            startCountdown()
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        // Animate ring from 1.0 to 0.0 over 5 seconds (matching Kotlin's tween(5000))
        withAnimation(.linear(duration: 5.0)) {
            ringProgress = 0
        }

        // Tick the countdown every second
        for second in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(second)) {
                adCountdown = 5 - second
            }
        }
    }
}

// MARK: - AdCloseButtonStyle (matching React Native's pressed opacity)

private struct AdCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

// MARK: - TopRoundedRectangle (reused from GameIframeView)
// Note: This is defined privately in GameIframeView as well.
// For AdOverlayView to use it, we define it here too.

private struct TopRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
