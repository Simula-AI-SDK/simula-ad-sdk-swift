import Foundation

#if os(iOS)
import UIKit
#endif

struct ApplicationSessionLifecycleState {
    private(set) var observedBackground: Bool

    init(observedBackground: Bool = false) {
        self.observedBackground = observedBackground
    }

    mutating func didEnterBackground() {
        observedBackground = true
    }

    mutating func didBecomeActive() -> Bool {
        guard observedBackground else { return false }
        observedBackground = false
        return true
    }
}

/// Observes aggregate application lifecycle notifications. `UIApplication` only posts its
/// background notification after all scenes have left the foreground, so scene churn does not
/// create extra session refreshes.
final class ApplicationSessionLifecycleObserver {
    private let center: NotificationCenter
    private let refresh: @MainActor () -> Void
    private var state = ApplicationSessionLifecycleState()
    private var observers: [NSObjectProtocol] = []

    init(
        center: NotificationCenter,
        didEnterBackground: Notification.Name,
        didBecomeActive: Notification.Name,
        initiallyBackgrounded: Bool = false,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.refresh = refresh
        self.state = ApplicationSessionLifecycleState(observedBackground: initiallyBackgrounded)
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
        state.didEnterBackground()
    }

    @MainActor
    private func handleActive() {
        guard state.didBecomeActive() else { return }
        refresh()
    }
}

#if os(iOS)
private let processApplicationSessionLifecycleObserver = ApplicationSessionLifecycleObserver(
    center: .default,
    didEnterBackground: UIApplication.didEnterBackgroundNotification,
    didBecomeActive: UIApplication.didBecomeActiveNotification,
    initiallyBackgrounded: UIApplication.shared.applicationState == .background
) {
    var providers = processActiveSimulaProviderRegistry.providers()
    if let shared = SimulaAds.shared,
       !providers.contains(where: { $0 === shared }) {
        providers.append(shared)
    }
    providers.forEach { $0.beginForegroundSessionRefresh() }
}

func installProcessApplicationSessionLifecycleObserver() {
    _ = processApplicationSessionLifecycleObserver
}
#endif
