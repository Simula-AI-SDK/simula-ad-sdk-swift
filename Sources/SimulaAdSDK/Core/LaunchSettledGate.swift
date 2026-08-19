import Foundation

/// One process-wide quiet window for non-essential launch work. Waiting suspends only the
/// calling task; late callers return immediately and the main thread is never blocked.
let simulaLaunchSettledQuietWindow: TimeInterval = 5

protocol LaunchSettling: Sendable {
    func waitUntilSettled() async
}

final class LaunchSettledGate: LaunchSettling, @unchecked Sendable {
    static let shared = LaunchSettledGate(quietWindow: simulaLaunchSettledQuietWindow)

    private let deadlineUptime: TimeInterval

    init(
        quietWindow: TimeInterval,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        deadlineUptime = uptime() + max(0, quietWindow)
        self.uptime = uptime
    }

    private let uptime: @Sendable () -> TimeInterval

    func waitUntilSettled() async {
        let remaining = deadlineUptime - uptime()
        guard remaining > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        } catch {
            return
        }
    }
}

struct ImmediateLaunchSettledGate: LaunchSettling {
    static let shared = ImmediateLaunchSettledGate()
    func waitUntilSettled() async {}
}
