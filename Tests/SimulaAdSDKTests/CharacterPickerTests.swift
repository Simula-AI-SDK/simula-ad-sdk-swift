import XCTest
@testable import SimulaAdSDK

/// Covers the companions request URL and the tolerant character parsing the
/// Character Picker relies on. Pure — no network.
final class CharacterPickerTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - companionsURL

    func testCompanionsURLAppendsSessionId() throws {
        let url = try XCTUnwrap(SimulaAPI.companionsURL(sessionId: "sess_9"))
        XCTAssertTrue(url.absoluteString.hasSuffix("/minigames/companions?session_id=sess_9"))
    }

    func testCompanionsURLOmitsSessionWhenNilOrEmpty() throws {
        XCTAssertNil(try XCTUnwrap(SimulaAPI.companionsURL(sessionId: nil)).query)
        XCTAssertNil(try XCTUnwrap(SimulaAPI.companionsURL(sessionId: "")).query)
    }

    // MARK: - parseCharacters

    func testParsesCharactersWithBackendFieldNames() {
        let json = """
        {"characters":[
          {"character_id":"superman","character_name":"Superman","images_1_1":["https://x/c1.png"],"description":"hero"},
          {"character_id":"maya","character_name":"Maya","avatar_url":"https://x/c3.png"}
        ]}
        """
        let chars = parseCharacters(data(json))
        XCTAssertEqual(chars.count, 2)
        XCTAssertEqual(chars[0].id, "superman")
        XCTAssertEqual(chars[0].name, "Superman")
        XCTAssertEqual(chars[0].image, "https://x/c1.png") // images_1_1[0]
        XCTAssertEqual(chars[0].description, "hero")
        XCTAssertEqual(chars[1].image, "https://x/c3.png") // avatar_url fallback
    }

    func testParsesBareArrayAndDataWrapperDroppingInvalid() {
        let bare = parseCharacters(data(#"[{"id":"a","name":"A","image":"u"},{"name":"no id"}]"#))
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].id, "a")
        XCTAssertEqual(bare[0].image, "u")

        let wrapped = parseCharacters(data(#"{"data":[{"id":"b","name":"B"}]}"#))
        XCTAssertEqual(wrapped.count, 1)
        XCTAssertEqual(wrapped[0].image, "") // no image field → empty
    }

    func testReturnsEmptyForUnexpectedShapesInsteadOfThrowing() {
        XCTAssertTrue(parseCharacters(data(#"{"unexpected":true}"#)).isEmpty)
        XCTAssertTrue(parseCharacters(data("not json")).isEmpty)
    }
}
