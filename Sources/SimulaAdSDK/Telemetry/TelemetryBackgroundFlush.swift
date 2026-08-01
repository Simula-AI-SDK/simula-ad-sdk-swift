import Foundation

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

    /// Idempotent (first-wins, like the rest of the pipeline): a second install is a no-op.
    /// The observer token is retained for the process lifetime by design.
    func install(center: NotificationCenter = .default, name: Notification.Name, flush: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard observer == nil else { return }
        observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in flush() }
    }
}
