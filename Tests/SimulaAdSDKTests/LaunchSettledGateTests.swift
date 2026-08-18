import XCTest
@testable import SimulaAdSDK

final class LaunchSettledGateTests: XCTestCase {
    func testQuietWindowIsFiveSeconds() {
        XCTAssertEqual(simulaLaunchSettledQuietWindow, 5)
    }

    func testLateWaitReturnsImmediately() async {
        let clock = GateClock(100)
        let gate = LaunchSettledGate(quietWindow: 5, uptime: { clock.value })
        clock.value = 106

        let started = ProcessInfo.processInfo.systemUptime
        await gate.waitUntilSettled()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1)
    }
}

private final class GateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ value: TimeInterval) { time = value }
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return time }
        set { lock.lock(); time = newValue; lock.unlock() }
    }
}
