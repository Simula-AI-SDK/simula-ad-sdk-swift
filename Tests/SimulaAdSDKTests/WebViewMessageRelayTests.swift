#if os(iOS)
import XCTest
@testable import SimulaAdSDK

final class WebViewMessageRelayTests: XCTestCase {
    func testGenericBridgeMessagesRequireCurrentCapability() {
        let authenticated = #"{"type":"AD_EARLY_COMPLETE","__simulaSdkCapability":"current"}"#

        XCTAssertEqual(
            authenticatedCreativeBridgeMessage(authenticated, expectedCapability: "current"),
            authenticated
        )
        XCTAssertNil(authenticatedCreativeBridgeMessage(#"{"type":"AD_EARLY_COMPLETE"}"#, expectedCapability: "current"))
        XCTAssertNil(authenticatedCreativeBridgeMessage(authenticated, expectedCapability: "stale"))
        XCTAssertNil(authenticatedCreativeBridgeMessage("malformed", expectedCapability: "current"))
        XCTAssertNil(authenticatedCreativeBridgeMessage(
            authenticated + String(repeating: " ", count: creativeBridgeMaxMessageUTF16Characters),
            expectedCapability: "current"
        ))
    }

    func testRelayAcceptsOnlyTopOrDirectSrcdocCreativeRoot() {
        let source = creativeBridgeRelayScriptSource(capability: "bridge-capability")

        XCTAssertTrue(source.contains("window.parent === window.top"))
        XCTAssertTrue(source.contains("window.frameElement.hasAttribute('srcdoc')"))
        XCTAssertTrue(source.contains("window.frameElement === window.top.document.querySelector('iframe[srcdoc]')"))
        XCTAssertTrue(source.contains("if (!isTop && !isDirectSrcdoc) { return; }"))
        XCTAssertTrue(source.contains("function isCreativeRootSource(source)"))
        XCTAssertTrue(source.contains("document.querySelector('iframe[srcdoc]')"))
        XCTAssertTrue(source.contains("frame.contentWindow !== source"))
        XCTAssertTrue(source.contains("String(source.location.href) === 'about:srcdoc'"))
        XCTAssertTrue(source.contains("!isCreativeRootSource(event.source)"))
        XCTAssertTrue(source.contains("envelope.__simulaSdkResponse"))
        XCTAssertTrue(source.contains("envelope.type === 'SIMULA_JS_ERROR'"))
        XCTAssertTrue(source.contains("envelope.type === 'SIMULA_AD_HEIGHT'"))
        XCTAssertTrue(source.contains("event.stopImmediatePropagation()"))
        let responseGuard = source.range(of: "if (envelope.__simulaSdkResponse) { return; }")
        let internalGuard = source.range(of: "if (envelope.type === 'SIMULA_JS_ERROR'")
        let serialization = source.range(of: "var serialized = nativeStringify(envelope)")
        XCTAssertNotNil(responseGuard)
        XCTAssertNotNil(internalGuard)
        XCTAssertNotNil(serialization)
        if let responseGuard, let internalGuard, let serialization {
            XCTAssertLessThan(responseGuard.lowerBound, internalGuard.lowerBound)
            XCTAssertLessThan(internalGuard.lowerBound, serialization.lowerBound)
        }
        XCTAssertFalse(source.contains("window.frames"))
        XCTAssertFalse(source.contains("contentWindow.frames"))
    }

    func testErrorCaptureRunsOnlyInCreativeRoots() {
        let rootGuard = creativeRootGuardScriptSource()
        let source = creativeErrorCaptureScriptSource()

        XCTAssertTrue(source.contains(rootGuard))
        XCTAssertTrue(source.contains("if (!isTop && !isDirectSrcdoc) { return; }"))
        XCTAssertTrue(source.contains("window.addEventListener('error'"))
        guard let guardRange = source.range(of: rootGuard),
              let listenerRange = source.range(of: "window.addEventListener('error'") else {
            return XCTFail("error capture must install after the creative-root guard")
        }
        XCTAssertLessThan(guardRange.lowerBound, listenerRange.lowerBound)
    }

    func testForwarderRotatesBridgeAndActivationCapabilitiesTogether() {
        let forwarder = WebViewMessageForwarder()
        let oldBridge = forwarder.bridgeCapability
        let oldActivation = forwarder.userActivationNonce

        forwarder.rotatePresentationCapabilities()

        XCTAssertNotEqual(forwarder.bridgeCapability, oldBridge)
        XCTAssertNotEqual(forwarder.userActivationNonce, oldActivation)
    }

    @MainActor
    func testRepliesTargetOnlyTopAndDirectSrcdocCreativeRoots() {
        let bridge = CreativeBridge()
        var script: String?

        bridge.handle(#"{"type":"GET_AUDIO_STATE"}"#) { script = $0 }

        guard let script else { return XCTFail("GET_AUDIO_STATE did not reply") }
        XCTAssertTrue(script.contains("if (window !== window.top) { return; }"))
        XCTAssertTrue(script.contains("deliver(window)"))
        XCTAssertTrue(script.contains("document.querySelector('iframe[srcdoc]')"))
        XCTAssertTrue(script.contains("target = frame && frame.contentWindow"))
        XCTAssertTrue(script.contains("String(target.location.href) !== 'about:srcdoc'"))
        XCTAssertFalse(script.contains("window.frames"))
        XCTAssertFalse(script.contains("contentWindow.frames"))
    }

}
#endif
