import XCTest
@testable import SimulaAdSDK

/// Tier-1 tests for `Ipv4Beacon` — URL contract (sid-first identity), per-identity dedup,
/// in-flight coalescing, failure retryability, and logout reset. Exercised with an injected fake
/// sender, device id, and clock — no network, no wall-clock timing.
final class Ipv4BeaconTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
        }
    }

    private func makeBeacon(
        urlString: String = "https://ip4.example/px",
        deviceId: String? = "device-123",
        recorder: SendRecorder
    ) -> Ipv4Beacon {
        Ipv4Beacon(
            urlString: urlString,
            send: { url, completion in recorder.record(url, completion: completion) },
            deviceId: { deviceId },
            now: { [date = referenceDate] in date }
        )
    }

    // MARK: - URL construction

    func testURLCarriesFullContract() {
        let url = Ipv4Beacon.buildURL(
            base: "https://ip4.example/px",
            apiKey: "key-1",
            sessionId: "sess-1",
            ppid: "user-1",
            deviceId: "dev-1",
            reason: Ipv4Beacon.reasonInit,
            timestamp: Date(timeIntervalSince1970: 42)
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://ip4.example/px?k=key-1&sid=sess-1&ppid=user-1&did=dev-1&p=ios&r=init&t=42000"
        )
    }

    func testURLOmitsAbsentSidPpidDid() {
        let url = Ipv4Beacon.buildURL(
            base: "https://ip4.example/px",
            apiKey: "key-1",
            sessionId: nil,
            ppid: "  ",
            deviceId: nil,
            reason: Ipv4Beacon.reasonPpidUpdate,
            timestamp: Date(timeIntervalSince1970: 42)
        )
        XCTAssertEqual(url?.absoluteString, "https://ip4.example/px?k=key-1&p=ios&r=ppid_update&t=42000")
    }

    func testURLPreservesAnExistingQuery() {
        let url = Ipv4Beacon.buildURL(
            base: "https://ip4.example/px?v=2",
            apiKey: "k",
            sessionId: nil,
            ppid: nil,
            deviceId: nil,
            reason: Ipv4Beacon.reasonInit,
            timestamp: referenceDate
        )
        XCTAssertTrue(url?.absoluteString.hasPrefix("https://ip4.example/px?v=2&k=k") == true)
    }

    // MARK: - firing + dedup

    func testFireSendsOneBeaconCarryingSidPpidDid() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "key-1", sessionId: "sess-1", ppid: "user-1", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 }

        let query = recorder.urls.first?.query ?? ""
        XCTAssertTrue(query.contains("k=key-1"))
        XCTAssertTrue(query.contains("sid=sess-1"))
        XCTAssertTrue(query.contains("ppid=user-1"))
        XCTAssertTrue(query.contains("did=device-123"))
        XCTAssertTrue(query.contains("r=init"))
    }

    func testSuccessfulCaptureIsDedupedForTheSameIdentity() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 && beacon.isIdleForTests }
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonPpidUpdate)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorder.count, 1)
    }

    func testANewSessionIdIsANewIdentityAndRefires() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess-1", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 && beacon.isIdleForTests }
        beacon.fire(apiKey: "k", sessionId: "sess-2", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 2 }
    }

    func testANewPpidIsANewIdentityAndRefires() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: nil, reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 && beacon.isIdleForTests }
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "user-1", reason: Ipv4Beacon.reasonPpidUpdate)
        await waitUntil(timeout: 2) { recorder.count == 2 }
    }

    func testOverlappingFiresForTheSameIdentityCoalesce() async {
        let recorder = SendRecorder()
        recorder.gate() // hold the first send in flight
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 } // first is in flight (gated)
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        recorder.open()
        await waitUntil(timeout: 2) { beacon.isIdleForTests }

        XCTAssertEqual(recorder.count, 1)
    }

    // MARK: - failure handling

    func testAFailedSendStaysRetryable() async {
        let recorder = SendRecorder()
        recorder.result = false
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 && beacon.isIdleForTests }

        recorder.result = true
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 2 && beacon.isIdleForTests }

        // Now captured — a third fire is deduped.
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.count, 2)
    }

    // MARK: - logout reset

    func testLogoutResetsDedupSoAReloginWithTheSamePpidRecaptures() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "user-1", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 && beacon.isIdleForTests }

        beacon.onLogout()
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "user-1", reason: Ipv4Beacon.reasonPpidUpdate)
        await waitUntil(timeout: 2) { recorder.count == 2 }
    }

    func testACompletionThatLandsAfterALogoutDoesNotResurrectStaleState() async {
        let recorder = SendRecorder()
        recorder.gate()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        await waitUntil(timeout: 2) { recorder.count == 1 } // in flight, gated

        beacon.onLogout() // clears bookkeeping while the fire is mid-flight
        recorder.open() // stale fire now completes successfully

        // The stale success must NOT mark the identity captured — post-logout it fires again.
        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonPpidUpdate)
        await waitUntil(timeout: 2) { recorder.count == 2 }
    }

    // MARK: - disabled / invalid input

    func testABlankURLDisablesTheBeacon() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(urlString: "   ", recorder: recorder)

        beacon.fire(apiKey: "k", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.count, 0)
    }

    func testAnEmptyApiKeyNeverFires() async {
        let recorder = SendRecorder()
        let beacon = makeBeacon(recorder: recorder)

        beacon.fire(apiKey: "", sessionId: "sess", ppid: "u", reason: Ipv4Beacon.reasonInit)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.count, 0)
    }
}

// MARK: - Test double

/// Records every sent URL, returns a programmable result, and can gate a send in flight so a
/// test can observe/act while the beacon is mid-request. Completion-based, mirroring the
/// production sender seam (the beacon's launch path uses no Swift Concurrency — see the
/// `send` property note in `Ipv4Beacon`).
private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var gated = false
    /// Deliveries parked while gated; `open()` fires them all.
    private var parked: [@Sendable () -> Void] = []

    var result = true

    var count: Int { lock.lock(); defer { lock.unlock() }; return recorded.count }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }

    /// Hold subsequent sends open until `open()` is called.
    func gate() { lock.lock(); gated = true; lock.unlock() }

    func open() {
        lock.lock()
        let deliveries = parked
        parked = []
        gated = false
        lock.unlock()
        for deliver in deliveries { deliver() }
    }

    func record(_ url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        recorded.append(url)
        let outcome = result
        // Park-or-deliver decided under one lock acquisition so a concurrent `open()` can
        // never slip between the check and the park.
        if gated {
            parked.append { completion(outcome) }
            lock.unlock()
            return
        }
        lock.unlock()
        completion(outcome)
    }
}
