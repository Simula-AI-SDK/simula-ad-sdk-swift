import XCTest
@testable import SimulaAdSDK

// Package.swift shares artifact conditions with this target. The stable lane
// verifies the no-op implementation through its artifact scan.
#if SIMULA_DEV_ARTIFACT
final class ArtifactOptionSelectionTests: XCTestCase {
    func testDefaultsOffAndFreezes() {
        let selection = ArtifactOptionSelection()
        XCTAssertEqual(selection.headers(), [:])
        XCTAssertFalse(selection.configure(hidden: true))
        XCTAssertTrue(selection.configure(hidden: false))
    }

    func testExplicitSettingIsIdempotentAndCannotChange() {
        let selection = ArtifactOptionSelection()
        XCTAssertTrue(selection.configure(hidden: true))
        XCTAssertTrue(selection.configure(hidden: true))
        XCTAssertEqual(selection.headers(), ["X-Simula-Dev-Hide-Companion": "true"])
        XCTAssertFalse(selection.configure(hidden: false))
        XCTAssertTrue(selection.freeze())
    }
}
#endif
