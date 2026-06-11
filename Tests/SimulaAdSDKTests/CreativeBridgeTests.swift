#if os(iOS)
import XCTest
@testable import SimulaAdSDK

/// Unit tests for the WebView ↔ SDK bridge (PRD §3): envelope parsing, event/command/query
/// routing, and the `window.postMessage` reply shape for `GET_*` queries. The UIKit-backed
/// readers (haptics / orientation / device context) run on the simulator; we assert the
/// envelope/reply contract rather than the hardware effect.
final class CreativeBridgeTests: XCTestCase {

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
        assertQueryReply(type: "GET_AUDIO_STATE", requestId: "42") { payload, rid in
            XCTAssertEqual(rid as? String, "42")
            XCTAssertNotNil(payload["muted"] as? Bool)
        }
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
        type: String,
        requestId: Any,
        _ body: ([String: Any], Any?) -> Void
    ) {
        let bridge = CreativeBridge()
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
}
#endif
