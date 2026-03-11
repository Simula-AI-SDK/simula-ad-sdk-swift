import SwiftUI

// MARK: - GameIframeView

/// Full-screen overlay that loads and displays a game in a WKWebView.
/// Translates `GameIframe.tsx` from the React SDK.
///
/// Features:
/// - Calls `getMinigame()` API to get iframe URL using the session from SimulaProvider
/// - Loading spinner and error states
/// - Close button (top-right)
/// - Bottom sheet mode when `playableHeight` is set (with draggable handle)
/// - Dragging above 95% of screen snaps to full screen and hides status bar
/// - Fade-in overlay animation
/// - PostMessage communication from game iframe (onAdIdReceived)
public struct GameIframeView: View {
    // MARK: - Props (matching React's GameIframeProps)

    let gameId: String
    let charID: String
    let charName: String
    let charImage: String
    var messages: [Message] = []
    var delegateChar: Bool = true
    let onClose: () -> Void
    var onAdIdReceived: ((String) -> Void)?
    var charDesc: String?
    var menuId: String?
    /// Controls the height of the game iframe (nil = fullscreen). Minimum 500px.
    var playableHeight: PlayableHeight?
    /// Background color for the bottom sheet border area. Default: '#262626'
    var playableBorderColor: String = "#262626"
    /// Reports final height (in points) and whether still in bottom-sheet mode on close.
    /// Matches Kotlin's `onDimensionsOnClose`.
    var onDimensionsOnClose: ((CGFloat, Bool) -> Void)?

    // MARK: - State

    @EnvironmentObject private var provider: SimulaProvider
    @State private var iframeUrl: String?
    @State private var loading = true
    @State private var error: String?
    @State private var appeared = false
    /// Current animated height for bottom sheet mode (in points)
    @State private var currentHeight: CGFloat = 0
    /// Accumulated drag offset during a gesture (auto-resets to 0 when gesture ends)
    @GestureState private var dragOffset: CGFloat = 0

    private let api = SimulaAPI()

    // MARK: - Computed

    private var isBottomSheetMode: Bool { playableHeight != nil }

    private var screenHeight: CGFloat {
        #if os(iOS)
        UIScreen.main.bounds.height
        #else
        768
        #endif
    }

    /// Calculate the initial height from the PlayableHeight enum
    private func calculateInitialHeight() -> CGFloat {
        guard let ph = playableHeight else { return screenHeight }
        switch ph {
        case .pixels(let px):
            return max(px, 500)
        case .percent(let pct):
            return max(screenHeight * CGFloat(pct), 500)
        }
    }

    /// The effective display height, accounting for drag
    private var displayHeight: CGFloat {
        let h = currentHeight - dragOffset
        return min(max(h, 500), screenHeight)
    }

    /// Whether the sheet covers >= 95% of the screen (triggers status bar hide + snap)
    private var isNearFullScreen: Bool {
        currentHeight >= screenHeight * 0.95
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Backdrop (matching React's backgroundColor: 'rgba(0, 0, 0, 0.8)')
            Color.black.opacity(0.8)
                .ignoresSafeArea()
                .onTapGesture { handleClose() }

            // Content container
            VStack(spacing: 0) {
                if isBottomSheetMode {
                    Spacer()
                }

                // Bottom sheet header with drag handle (matching React/Kotlin bottom sheet header)
                if isBottomSheetMode {
                    VStack(spacing: 0) {
                        // Drag handle
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 40, height: 4)
                            .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: playableBorderColor))
                    .clipShape(TopRoundedRectangle(radius: 16))
                    .gesture(
                        DragGesture()
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation.height
                            }
                            .onEnded { value in
                                let finalHeight = currentHeight - value.translation.height
                                let clamped = min(max(finalHeight, 500), screenHeight)

                                if clamped >= screenHeight * 0.95 {
                                    // Snap to full screen with spring animation
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        currentHeight = screenHeight
                                    }
                                } else {
                                    currentHeight = clamped
                                }
                            }
                    )
                }

                // Main content area
                ZStack {
                    if loading {
                        // Loading state (matching React)
                        VStack {
                            Spacer()
                            Text("Loading game...")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                        }
                    } else if let error = error {
                        // Error state (matching React)
                        VStack {
                            Spacer()
                            Text(error)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(20)
                            Spacer()
                        }
                    } else if let urlString = iframeUrl, let url = URL(string: urlString) {
                        // Game WebView (matching React's <iframe>)
                        WebViewRepresentable(
                            url: url,
                            onNavigationFailed: { err in
                                self.error = "Failed to load game. Please try again."
                            },
                            onMessageReceived: { message in
                                handleMessage(message)
                            }
                        )
                    }

                    // Close button — top right of content area
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                handleClose()
                            }) {
                                Text("\u{00D7}")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        Circle()
                                            .fill(Color.black.opacity(0.6))
                                    )
                            }
                            .buttonStyle(GameCloseButtonStyle())
                            .padding(.top, 16)
                            .padding(.trailing, 16)
                            .accessibilityLabel("Close game")
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: isBottomSheetMode ? displayHeight : nil)
                .frame(maxHeight: isBottomSheetMode ? nil : .infinity)
            }
        }
        .hideStatusBar(isBottomSheetMode ? isNearFullScreen : true)
        .opacity(appeared ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: appeared)
        .task {
            currentHeight = calculateInitialHeight()
            appeared = true
            await loadMinigame()
        }
    }

    // MARK: - Close Handler

    private func handleClose() {
        // Report dimensions on close (matching Kotlin's onDimensionsOnClose)
        if isBottomSheetMode {
            let isStillBottomSheet = currentHeight < screenHeight * 0.95
            onDimensionsOnClose?(currentHeight, isStillBottomSheet)
        }
        onClose()
    }

    // MARK: - Load Minigame

    /// Fetches the minigame iframe URL from the API.
    /// Translates the useEffect that calls `getMinigame()` in GameIframe.tsx.
    private func loadMinigame() async {
        guard let sessionId = provider.sessionId, !sessionId.isEmpty else {
            error = "Session invalid, cannot initialize minigame"
            loading = false
            return
        }

        #if os(iOS)
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        #else
        let screenWidth: CGFloat = 1024
        let screenHeight: CGFloat = 768
        #endif

        do {
            let request = InitMinigameRequest(
                gameType: gameId,
                sessionId: sessionId,
                currencyMode: false,
                w: screenWidth,
                h: screenHeight,
                charId: charID,
                charName: charName,
                charImage: charImage,
                charDesc: charDesc,
                messages: messages,
                delegateChar: delegateChar,
                menuId: menuId
            )

            let response = try await api.getMinigame(request)
            self.iframeUrl = response.iframeUrl

            // Callback with the ad_id for tracking (matching React's onAdIdReceived)
            if !response.adId.isEmpty {
                onAdIdReceived?(response.adId)
            }
            self.loading = false
        } catch {
            self.error = "Failed to load game. Please try again."
            self.loading = false
        }
    }

    // MARK: - Message Handling

    /// Handles postMessage from the game iframe.
    private func handleMessage(_ message: String) {
        // Games may send messages for various events
        // The React SDK doesn't explicitly handle specific messages in GameIframe,
        // but this hook is available for future use
        print("[GameIframeView] Received message from game: \(message)")
    }
}

// MARK: - GameCloseButtonStyle (matching React Native's pressed opacity)

private struct GameCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

// MARK: - TopRoundedRectangle

/// A shape with rounded top corners only (for the bottom sheet header).
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
