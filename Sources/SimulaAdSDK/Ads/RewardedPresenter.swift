#if os(iOS)
import SwiftUI
import UIKit

// MARK: - RewardedPresenter

/// Presents the imperative rewarded minigame full-screen in a dedicated `UIWindow`,
/// independent of the host app's view-controller stack (mirrors `InterstitialPresenter`).
///
/// Hosting in its own window (above `.normal`) lets the imperative API present from
/// anywhere — SwiftUI or UIKit hosts alike.
@MainActor
final class RewardedPresenter {
    private var window: UIWindow?
    /// Fired once on teardown with whether the reward was earned and the measured
    /// play time, so the caller can verify the play server-side.
    private var onClose: ((Bool, Double) -> Void)?
    /// The host's key window, captured before we take key. Restored on dismiss so the
    /// host regains touch/keyboard focus (a new key window doesn't auto-revert).
    private weak var originalKeyWindow: UIWindow?

    /// Presents the playable minigame iframe. `onClose` fires once the window has been
    /// torn down, carrying `(rewardEarned, elapsedPlayTime)`.
    ///
    /// - Returns: `true` if presented; `false` if no window scene was available (in
    ///   which case `onClose` is never called).
    @discardableResult
    func present(
        iframeUrl: String,
        durationSeconds: Int,
        onClose: @escaping (Bool, Double) -> Void
    ) -> Bool {
        guard let scene = Self.activeWindowScene() else {
            return false
        }
        self.onClose = onClose

        let root = RewardedGameView(
            iframeUrl: iframeUrl,
            durationSeconds: durationSeconds,
            onFinish: { [weak self] earned, elapsed in
                self?.dismiss(earned: earned, elapsedPlayTime: elapsed)
            }
        )

        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear

        originalKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// Tears down the presentation window and fires the close callback once.
    private func dismiss(earned: Bool, elapsedPlayTime: Double) {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        originalKeyWindow?.makeKey()
        originalKeyWindow = nil
        let callback = onClose
        onClose = nil
        callback?(earned, elapsedPlayTime)
    }

    /// Finds a foreground window scene to attach the overlay window to.
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }
}

// MARK: - RewardedGameView

/// Full-screen playable minigame: the creative iframe in a pooled `WKWebView`, a
/// top-left close button (always available) and a top-right status pill counting
/// down the remaining play time. The reward is earned once `durationSeconds` of play
/// elapse; closing earlier prompts an exit confirmation so the user doesn't lose the
/// reward by accident. On a qualifying close, `onFinish(earned, elapsedPlayTime)`
/// fires after the dismiss fade.
private struct RewardedGameView: View {
    let iframeUrl: String
    let durationSeconds: Int
    let onFinish: (Bool, Double) -> Void

    @State private var elapsedPlayTime: Double = 0
    @State private var rewardEarned = false
    @State private var visible = true
    @State private var showExitConfirmation = false
    @State private var timerTask: Task<Void, Never>?

    /// Matches the dismiss fade before the window is removed.
    private let dismissAnimationDuration: TimeInterval = 0.25

    private var secondsLeft: Int {
        max(0, durationSeconds - Int(elapsedPlayTime))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url = URL(string: iframeUrl) {
                WebViewRepresentable(url: url)
                    .ignoresSafeArea()
            }

            // Top bar: close (left) + reward status pill (right).
            VStack {
                HStack(alignment: .top) {
                    Button(action: handleCloseAttempt) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")

                    Spacer()

                    statusPill
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .opacity(visible ? 1 : 0)
        // Opacity 0 does not stop hit-testing during the fade; disable touches so a
        // second close tap can't double-fire.
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: dismissAnimationDuration), value: visible)
        .hideStatusBar(true)
        .alert(isPresented: $showExitConfirmation) {
            Alert(
                title: Text("Exit game?"),
                message: Text("You haven't played long enough to earn your reward. If you exit now, you'll lose it."),
                primaryButton: .destructive(Text("Exit anyway")) { finish(earned: false) },
                secondaryButton: .cancel(Text("Keep playing"))
            )
        }
        .onAppear { startTimer() }
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        Group {
            if rewardEarned {
                Text("🎁 Reward unlocked!")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.green)
            } else {
                Text("🎮 Play to earn: \(secondsLeft)s")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.75))
                .overlay(
                    Capsule().stroke(
                        rewardEarned ? Color.green.opacity(0.6) : Color.white.opacity(0.2),
                        lineWidth: 1
                    )
                )
        )
        .animation(.default, value: rewardEarned)
    }

    // MARK: Timer

    private func startTimer() {
        guard timerTask == nil else { return }
        // A zero/negative duration is earned immediately (no gate).
        guard durationSeconds > 0 else {
            rewardEarned = true
            return
        }
        timerTask = Task { @MainActor in
            while elapsedPlayTime < Double(durationSeconds) && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                elapsedPlayTime += 1
                if elapsedPlayTime >= Double(durationSeconds) {
                    rewardEarned = true
                }
            }
        }
    }

    // MARK: Close

    private func handleCloseAttempt() {
        if rewardEarned {
            finish(earned: true)
        } else {
            showExitConfirmation = true
        }
    }

    private func finish(earned: Bool) {
        let elapsed = elapsedPlayTime
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            onFinish(earned, elapsed)
        }
    }
}
#endif
