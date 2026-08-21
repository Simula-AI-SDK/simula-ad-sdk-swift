#if os(iOS)
import XCTest
@testable import SimulaAdSDK

/// Unit tests for the WebView ↔ SDK bridge (PRD §3): envelope parsing, event/command/query
/// routing, and the `window.postMessage` reply shape for `GET_*` queries. The UIKit-backed
/// readers (haptics / orientation / device context) run on the simulator; we assert the
/// envelope/reply contract rather than the hardware effect.
final class CreativeBridgeTests: XCTestCase {

    private final class FakeAudioObservation: CreativeAudioVolumeObservation {
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    private final class FakeAudioVolumeSource: CreativeAudioVolumeSource {
        var outputVolume: Float
        private(set) var callbacks: [(Float) -> Void] = []
        private(set) var observations: [FakeAudioObservation] = []

        init(_ outputVolume: Float) {
            self.outputVolume = outputVolume
        }

        func observe(_ onChange: @escaping (Float) -> Void) -> CreativeAudioVolumeObservation? {
            let observation = FakeAudioObservation()
            observations.append(observation)
            callbacks.append(onChange)
            return observation
        }

        func emit(_ outputVolume: Float, observation index: Int? = nil) {
            self.outputVolume = outputVolume
            if let index {
                callbacks[index](outputVolume)
            } else {
                callbacks.last?(outputVolume)
            }
        }
    }

    private final class FakeAudioVolumePoller: CreativeAudioVolumePolling {
        private(set) var callbacks: [() -> Void] = []
        private(set) var starts = 0
        private(set) var stops = 0
        private var active = false

        func start(_ onPoll: @escaping () -> Void) {
            starts += 1
            active = true
            callbacks.append(onPoll)
        }

        func stop() {
            if active { stops += 1 }
            active = false
        }

        func fire(_ index: Int? = nil) {
            if let index {
                callbacks[index]()
            } else {
                callbacks.last?()
            }
        }
    }

    /// `AD_EARLY_COMPLETE` is a no-reply event that flips `earlyComplete` (the presenting view
    /// reveals the close button on it).
    @MainActor
    func testEarlyCompleteFlipsFlag() {
        let bridge = CreativeBridge()
        XCTAssertFalse(bridge.earlyComplete)
        var replied = false
        bridge.handle(#"{"type":"AD_EARLY_COMPLETE"}"#) { _ in replied = true }
        XCTAssertTrue(bridge.earlyComplete)
        XCTAssertFalse(replied, "events must not reply")
    }

    /// Commands act but never reply; an unknown payload style is ignored, not crashed.
    @MainActor
    func testCommandsDoNotReply() {
        let bridge = CreativeBridge()
        var replied = false
        bridge.handle(#"{"type":"TRIGGER_HAPTIC","payload":{"style":"success"}}"#) { _ in replied = true }
        bridge.handle(#"{"type":"TRIGGER_HAPTIC","payload":{"style":"bogus"}}"#) { _ in replied = true }
        bridge.handle(#"{"type":"SET_ORIENTATION","payload":{"orientation":"landscape"}}"#) { _ in replied = true }
        XCTAssertFalse(replied, "commands must not reply")
    }

    /// Malformed input and unknown types are silently ignored (no reply, no crash).
    @MainActor
    func testMalformedAndUnknownIgnored() {
        let bridge = CreativeBridge()
        var replied = false
        bridge.handle("not json") { _ in replied = true }
        bridge.handle(#"{"noType":true}"#) { _ in replied = true }
        bridge.handle(#"{"type":"NOPE","requestId":"1"}"#) { _ in replied = true }
        XCTAssertFalse(replied)
    }

    @MainActor
    func testGetAudioStateReplyShape() {
        let bridge = CreativeBridge(audioVolumeSource: FakeAudioVolumeSource(0.42))
        assertQueryReply(bridge: bridge, type: "GET_AUDIO_STATE", requestId: "42") { payload, rid in
            XCTAssertEqual(rid as? String, "42")
            XCTAssertEqual(payload["muted"] as? Bool, false)
            XCTAssertEqual(payload["volume"] as? Int, 42)
        }
    }

    func testAudioStateNormalization() {
        XCTAssertEqual(CreativeAudioState(outputVolume: 0).volume, 0)
        XCTAssertTrue(CreativeAudioState(outputVolume: 0).muted)
        XCTAssertTrue(CreativeAudioState(outputVolume: 0.004).muted)
        XCTAssertFalse(CreativeAudioState(outputVolume: 0.005).muted)
        XCTAssertEqual(CreativeAudioState(outputVolume: 0.5).volume, 50)
        XCTAssertFalse(CreativeAudioState(outputVolume: 0.5).muted)
        XCTAssertEqual(CreativeAudioState(outputVolume: 2).volume, 100)
        XCTAssertEqual(CreativeAudioState(outputVolume: -.infinity).volume, 0)
        XCTAssertTrue(CreativeAudioState(outputVolume: .nan).muted)
    }

    @MainActor
    func testAudioStateEventsStartAfterLoadAndDeduplicate() {
        let source = FakeAudioVolumeSource(0.42)
        let poller = FakeAudioVolumePoller()
        let bridge = CreativeBridge(audioVolumeSource: source, audioVolumePoller: poller)
        var events: [[String: Any]] = []

        source.emit(0.5)
        XCTAssertTrue(events.isEmpty)

        bridge.pageDidFinishLoading { [weak self] js in
            if let event = self?.decodeMessage(js) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "AUDIO_STATE_CHANGED")
        XCTAssertNil(events[0]["requestId"])
        XCTAssertEqual(events[0]["__simulaSdkResponse"] as? Bool, true)
        let initial = events[0]["payload"] as? [String: Any]
        XCTAssertEqual(initial?["volume"] as? Int, 50)
        XCTAssertEqual(initial?["muted"] as? Bool, false)

        source.emit(0.504)
        XCTAssertEqual(events.count, 1, "same normalized payload must be deduplicated")
        source.emit(0)
        XCTAssertEqual(events.count, 2)
        let changed = events[1]["payload"] as? [String: Any]
        XCTAssertEqual(changed?["volume"] as? Int, 0)
        XCTAssertEqual(changed?["muted"] as? Bool, true)
    }

    @MainActor
    func testPollingCatchesChangesWithoutKVOAndDeduplicates() {
        let source = FakeAudioVolumeSource(0.5)
        let poller = FakeAudioVolumePoller()
        let bridge = CreativeBridge(audioVolumeSource: source, audioVolumePoller: poller)
        var events: [[String: Any]] = []

        bridge.pageDidFinishLoading { [weak self] js in
            if let event = self?.decodeMessage(js) { events.append(event) }
        }
        XCTAssertEqual(poller.starts, 1)
        XCTAssertEqual(events.count, 1)

        source.outputVolume = 0.2
        poller.fire()
        XCTAssertEqual(events.count, 2)
        let changed = events[1]["payload"] as? [String: Any]
        XCTAssertEqual(changed?["volume"] as? Int, 20)

        poller.fire()
        source.emit(0.2)
        XCTAssertEqual(events.count, 2, "polling and KVO share one payload dedupe baseline")
    }

    @MainActor
    func testAudioObservationStopsAcrossReloadAndTeardown() {
        let source = FakeAudioVolumeSource(0.5)
        let poller = FakeAudioVolumePoller()
        let bridge = CreativeBridge(audioVolumeSource: source, audioVolumePoller: poller)
        var eventCount = 0

        bridge.pageDidFinishLoading { _ in eventCount += 1 }
        XCTAssertEqual(eventCount, 1)
        bridge.pageDidCommit()
        XCTAssertTrue(source.observations[0].invalidated)
        XCTAssertEqual(poller.stops, 1)
        source.emit(0, observation: 0)
        source.outputVolume = 0
        poller.fire(0)
        XCTAssertEqual(eventCount, 1, "queued callbacks from the old page must be ignored")

        bridge.pageDidFinishLoading { _ in eventCount += 1 }
        XCTAssertEqual(poller.starts, 2)
        XCTAssertEqual(eventCount, 2, "each loaded document receives an initial state")
        bridge.stop()
        XCTAssertTrue(source.observations[1].invalidated)
        XCTAssertEqual(poller.stops, 2)
        source.emit(1, observation: 1)
        source.outputVolume = 1
        poller.fire(1)
        XCTAssertEqual(eventCount, 2)
    }

    func testNavigationIdentityRequiresTwoNonNilMatchingObjects() {
        final class NavigationToken {}
        let first = NavigationToken()
        let second = NavigationToken()
        let missing: NavigationToken? = nil

        XCTAssertTrue(identicalNonNilObjects(first, first))
        XCTAssertFalse(identicalNonNilObjects(first, second))
        XCTAssertFalse(identicalNonNilObjects(first, missing))
        XCTAssertFalse(identicalNonNilObjects(missing, missing))
    }

    func testBridgeStopsBeforeWebViewRecycling() {
        var events: [String] = []

        stopBeforeRecycling(
            stop: { events.append("stop") },
            recycle: { events.append("recycle") }
        )

        XCTAssertEqual(events, ["stop", "recycle"])
    }

    /// A numeric requestId is echoed back with its JSON type preserved.
    @MainActor
    func testGetOrientationReplyShape() {
        assertQueryReply(type: "GET_ORIENTATION", requestId: 7) { payload, rid in
            XCTAssertEqual(rid as? Int, 7)
            let orientation = payload["orientation"] as? String
            XCTAssertTrue(orientation == "portrait" || orientation == "landscape")
        }
    }

    @MainActor
    func testGetDeviceContextReplyShape() {
        assertQueryReply(type: "GET_DEVICE_CONTEXT", requestId: "ctx") { payload, _ in
            XCTAssertNotNil(payload["darkMode"] as? Bool)
            XCTAssertNotNil(payload["locale"] as? String)
            XCTAssertNotNil(payload["osVersion"] as? String)
        }
    }

    // MARK: - Helpers

    /// Drives a `GET_*` query and decodes the `window.postMessage(<json>, '*');` reply, asserting
    /// the shared envelope (matching `type`, the echo-guard marker) before delegating to `body`.
    @MainActor
    private func assertQueryReply(
        bridge: CreativeBridge = CreativeBridge(),
        type: String,
        requestId: Any,
        _ body: ([String: Any], Any?) -> Void
    ) {
        let ridJSON = requestId is String ? "\"\(requestId)\"" : "\(requestId)"
        var captured: String?
        bridge.handle("{\"type\":\"\(type)\",\"requestId\":\(ridJSON)}") { js in captured = js }

        guard let js = captured else { return XCTFail("\(type) did not reply") }
        let json = stripPostMessageWrapper(js)
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("\(type) reply was not valid JSON: \(js)")
        }
        XCTAssertEqual(dict["type"] as? String, type)
        XCTAssertEqual(dict["__simulaSdkResponse"] as? Bool, true)
        guard let payload = dict["payload"] as? [String: Any] else {
            return XCTFail("\(type) reply missing payload")
        }
        body(payload, dict["requestId"])
    }

    /// `window.postMessage(<json>, '*');` → `<json>`.
    private func stripPostMessageWrapper(_ js: String) -> String {
        var s = js
        let prefix = "window.postMessage("
        let suffix = ", '*');"
        if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }

    private func decodeMessage(_ js: String) -> [String: Any]? {
        let json = stripPostMessageWrapper(js)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
#endif
