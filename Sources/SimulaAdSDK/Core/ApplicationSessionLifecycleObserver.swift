import Foundation

#if os(iOS)
import UIKit
#endif

let applicationSessionBackgroundExpirationInterval: TimeInterval = 30 * 60

struct ApplicationSessionLifecycleState {
    private(set) var backgroundedAt: TimeInterval?

    init(backgroundedAt: TimeInterval? = nil) {
        self.backgroundedAt = backgroundedAt
    }

    mutating func didEnterBackground(at timestamp: TimeInterval) {
        if backgroundedAt == nil { backgroundedAt = timestamp }
    }

    mutating func didBecomeActive(at timestamp: TimeInterval) -> Bool {
        guard let backgroundedAt else { return false }
        self.backgroundedAt = nil
        let elapsed = timestamp - backgroundedAt
        return elapsed >= applicationSessionBackgroundExpirationInterval
    }
}

/// Observes aggregate application lifecycle notifications. `UIApplication` only posts its
/// background notification after all scenes have left the foreground, so scene churn does not
/// create extra session-expiration signals.
final class ApplicationSessionLifecycleObserver {
    private let center: NotificationCenter
    private let now: @Sendable () -> TimeInterval
    private let expire: @MainActor () -> Void
    private var state = ApplicationSessionLifecycleState()
    private var observers: [NSObjectProtocol] = []

    init(
        center: NotificationCenter,
        didEnterBackground: Notification.Name,
        didBecomeActive: Notification.Name,
        initiallyBackgrounded: Bool = false,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        expire: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.now = now
        self.expire = expire
        self.state = ApplicationSessionLifecycleState(backgroundedAt: initiallyBackgrounded ? now() : nil)
        observers = [
            center.addObserver(forName: didEnterBackground, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleBackground() }
            },
            center.addObserver(forName: didBecomeActive, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleActive() }
            }
        ]
    }

    deinit {
        observers.forEach(center.removeObserver)
    }

    @MainActor
    private func handleBackground() {
        state.didEnterBackground(at: now())
    }

    @MainActor
    private func handleActive() {
        guard state.didBecomeActive(at: now()) else { return }
        expire()
    }
}

@MainActor
func expireRegisteredApplicationSessions(
    registry: ActiveSimulaProviderRegistry,
    shared: SimulaProvider?
) {
    var providers = registry.providers()
    if let shared, !providers.contains(where: { $0 === shared }) {
        providers.append(shared)
    }
    providers.forEach { $0.markSessionStaleAfterExtendedBackground() }
}

#if os(iOS)
private let processApplicationSessionLifecycleObserver = ApplicationSessionLifecycleObserver(
    center: .default,
    didEnterBackground: UIApplication.didEnterBackgroundNotification,
    didBecomeActive: UIApplication.didBecomeActiveNotification,
    initiallyBackgrounded: UIApplication.shared.applicationState == .background
) {
    expireRegisteredApplicationSessions(
        registry: processActiveSimulaProviderRegistry,
        shared: SimulaAds.shared
    )
}

func installProcessApplicationSessionLifecycleObserver() {
    _ = processApplicationSessionLifecycleObserver
}
#endif
