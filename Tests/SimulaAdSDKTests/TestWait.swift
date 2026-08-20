import XCTest

/// Shared async poll for tests that wait on unstructured `Task` drains.
///
/// iOS Simulator CI can leave those tasks unscheduled for many seconds while
/// WebKit's GPU process launches (we've seen 8–11s). The happy path still
/// returns on the first check — this timeout is only a stall budget, not a
/// sleep.
enum TestWait {
    static let timeout: TimeInterval = 20
}

func waitUntil(
    timeout: TimeInterval = TestWait.timeout,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) async {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
        if condition() { return }
        if ProcessInfo.processInfo.systemUptime > deadline {
            await Task.yield()
            if condition() { return }
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
    }
}

func waitUntil(
    timeout: TimeInterval = TestWait.timeout,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async -> Bool
) async {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
        if await condition() { return }
        if ProcessInfo.processInfo.systemUptime > deadline {
            await Task.yield()
            if await condition() { return }
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
    }
}
