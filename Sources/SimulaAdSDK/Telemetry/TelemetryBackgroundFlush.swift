import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One background-flush lifecycle. Expiration can race normal completion, so finishing and
/// ending the UIKit assertion are idempotent. `isFinished` lets a deferred facade request be
/// discarded after expiration instead of triggering a pointless post-install flush.
final class BackgroundFlushRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var endAction: (@Sendable () -> Void)?
    private let onFinish: @Sendable () -> Void
    private var finished = false

    init(onFinish: @escaping @Sendable () -> Void = {}) {
        self.onFinish = onFinish
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func installEndAction(_ action: (@Sendable () -> Void)?) {
        lock.lock()
        if finished {
            lock.unlock()
            action?()
            return
        }
        endAction = action
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let action = endAction
        endAction = nil
        lock.unlock()
        action?()
        onFinish()
    }
}

/// Process-wide app-background telemetry flush hook. Persist + deliver buffered telemetry as
/// the app heads to the background — the window where the process is most likely to be killed.
/// Mirrors Kotlin's `ON_STOP` / `onActivityStopped` hooks; `TelemetryManager.flushNow` is
/// idempotent, so repeat backgrounds and duplicate installs are safe.
///
/// The notification name is injected so production can pass
/// `UIApplication.didEnterBackgroundNotification` (UIKit-only) while macOS test targets drive
/// the same code with a plain custom name.
final class TelemetryBackgroundFlush: @unchecked Sendable {
    static let shared = TelemetryBackgroundFlush()

    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    /// Coalesces repeated background notifications while one assertion/flush is still pending.
    private var activeRequest: BackgroundFlushRequest?

    /// Idempotent (first-wins, like the rest of the pipeline): a second install is a no-op.
    /// The observer token is retained for the process lifetime by design.
    func install(
        center: NotificationCenter = .default,
        name: Notification.Name,
        beginBackgroundTask: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)? = { _ in nil },
        flush: @escaping @Sendable (BackgroundFlushRequest) -> Void
    ) {
        lock.lock()
        guard observer == nil else { lock.unlock(); return }
        observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.handleBackground(beginBackgroundTask: beginBackgroundTask, flush: flush)
        }
        lock.unlock()
    }

    private func handleBackground(
        beginBackgroundTask: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?,
        flush: @escaping @Sendable (BackgroundFlushRequest) -> Void
    ) {
        let request = BackgroundFlushRequest { [weak self] in self?.clearActiveRequest() }
        lock.lock()
        guard activeRequest == nil else { lock.unlock(); return }
        activeRequest = request
        lock.unlock()

        let end = beginBackgroundTask { request.finish() }
        request.installEndAction(end)
        flush(request)
    }

    private func clearActiveRequest() {
        lock.lock(); activeRequest = nil; lock.unlock()
    }

    #if canImport(UIKit)
    /// Begins a bounded UIKit background execution assertion. The caller owns normal completion;
    /// UIKit owns expiration. Both paths invoke the same idempotent completion above.
    static func beginUIKitBackgroundTask(
        expirationHandler: @escaping @Sendable () -> Void
    ) -> (@Sendable () -> Void)? {
        // UIKit lifecycle notifications arrive on main. If a host reposts the notification
        // elsewhere, skip the assertion rather than touching UIApplication off-main.
        guard Thread.isMainThread else { return nil }
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "SimulaTelemetryFlush", expirationHandler: expirationHandler
        )
        guard identifier != .invalid else { return nil }
        return {
            DispatchQueue.main.async {
                endUIKitBackgroundTask(identifier)
            }
        }
    }

    @MainActor
    private static func endUIKitBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
    #endif
}
