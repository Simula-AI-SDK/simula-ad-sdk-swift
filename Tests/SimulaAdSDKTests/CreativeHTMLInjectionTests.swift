import XCTest
@testable import SimulaAdSDK

final class CreativeHTMLInjectionTests: XCTestCase {
    func testSlotSourceUsesDocumentStartScriptWithoutRewritingHTML() {
        let html = "<!doctype html><html><head><script>userCTA()</script></head></html>"

        let source = creativeSlotSourceScriptSource(.primaryCTA)

        XCTAssertEqual(source, "window.__simulaNativeSlotSource='primary_cta';")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"), "creative markup remains byte-for-byte owned by the server")
    }

    func testSlotSourceFallsBackToCanonicalValue() {
        XCTAssertEqual(
            creativeSlotSourceScriptSource(.primaryUnknown),
            "window.__simulaNativeSlotSource='primary_unknown';"
        )
    }

    func testRendererRecoveryScriptIsIdempotent() {
        XCTAssertEqual(
            creativeSlotSourceScriptSource(.fallbackCTA),
            creativeSlotSourceScriptSource(.fallbackCTA)
        )
    }
}
