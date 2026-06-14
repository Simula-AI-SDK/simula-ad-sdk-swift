import XCTest
@testable import SimulaAdSDK

/// Covers the `/character-selector` request body and the tolerant character parsing
/// the Character Selector relies on. Pure — no network.
final class CharacterSelectorTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Request body

    func testRequestBodyEncodesSessionIdAndFill() throws {
        let body = try JSONEncoder().encode(CharacterSelectorRequest(sessionId: "sess_9", fill: 4))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["session_id"] as? String, "sess_9")
        XCTAssertEqual(obj["fill"] as? Int, 4)
    }

    // MARK: - parseCharacters

    func testParsesCharacterSelectorBareArrayWithImageUrl() {
        // Exactly what POST /character-selector returns: a bare array of
        // {id, name, imageUrl, description}.
        let json = """
        [
          {"id":"superman","name":"Superman","imageUrl":"https://x/c1.png","description":"hero"},
          {"id":"maya","name":"Maya","imageUrl":"https://x/c3.png","description":"mage"}
        ]
        """
        let chars = parseCharacters(data(json))
        XCTAssertEqual(chars.count, 2)
        XCTAssertEqual(chars[0].id, "superman")
        XCTAssertEqual(chars[0].name, "Superman")
        XCTAssertEqual(chars[0].imageUrl,"https://x/c1.png") // imageUrl
        XCTAssertEqual(chars[0].description, "hero")
        XCTAssertEqual(chars[1].imageUrl,"https://x/c3.png")
    }

    func testDropsItemsMissingNameDescriptionOrImageButToleratesBlankId() {
        let json = """
        [
          {"id":"ok","name":"OK","imageUrl":"u","description":"d"},
          {"name":"no id","imageUrl":"u","description":"d"},
          {"id":"x","imageUrl":"u","description":"d"},
          {"id":"y","name":"Y","description":"d"},
          {"id":"z","name":"Z","imageUrl":"u"}
        ]
        """
        let chars = parseCharacters(data(json))
        // Kept: the fully-populated entry and the one missing only an id.
        XCTAssertEqual(chars.map { $0.id }, ["ok", ""])
        XCTAssertEqual(chars.map { $0.name }, ["OK", "no id"])
    }

    func testStillToleratesLegacyFieldNamesAndWrappers() {
        let legacy = """
        {"characters":[
          {"character_id":"a","character_name":"A","images_1_1":["u1"],"description":"da"},
          {"character_id":"b","character_name":"B","avatar_url":"u2","description":"db"}
        ]}
        """
        let chars = parseCharacters(data(legacy))
        XCTAssertEqual(chars.count, 2)
        XCTAssertEqual(chars[0].imageUrl,"u1") // images_1_1[0]
        XCTAssertEqual(chars[1].imageUrl,"u2") // avatar_url fallback

        let wrapped = parseCharacters(data(#"{"data":[{"id":"c","name":"C","image":"u3","description":"dc"}]}"#))
        XCTAssertEqual(wrapped.count, 1)
        XCTAssertEqual(wrapped[0].imageUrl,"u3")
    }

    func testReturnsEmptyForUnexpectedShapesInsteadOfThrowing() {
        XCTAssertTrue(parseCharacters(data(#"{"unexpected":true}"#)).isEmpty)
        XCTAssertTrue(parseCharacters(data("not json")).isEmpty)
    }

    // MARK: - mergeRoster

    private func entry(_ id: String) -> CharacterSelectorEntry {
        CharacterSelectorEntry(data: CharacterData(id: id, name: id, imageUrl: "", description: ""))
    }
    private var fallback: [CharacterSelectorEntry] {
        [entry("f1"), entry("f2"), entry("f3"), entry("f4")]
    }

    func testHostOfFourLeavesNoRoomForBackend() {
        let merged = mergeRoster(
            host: [entry("h1"), entry("h2"), entry("h3"), entry("h4")],
            fetched: [entry("b1")],
            fallback: fallback
        )
        XCTAssertEqual(merged.map { $0.data.id }, ["h1", "h2", "h3", "h4"])
    }

    func testHostOfOnePlusThreeBackendFillsGrid() {
        let merged = mergeRoster(
            host: [entry("h1")],
            fetched: [entry("b1"), entry("b2"), entry("b3")],
            fallback: fallback
        )
        XCTAssertEqual(merged.map { $0.data.id }, ["h1", "b1", "b2", "b3"])
    }

    func testPartialBackendResponsePadsWithPlaceholders() {
        let merged = mergeRoster(host: [], fetched: [entry("b1"), entry("b2")], fallback: fallback)
        XCTAssertEqual(merged.map { $0.data.id }, ["b1", "b2", "f3", "f4"])
    }

    func testEmptyBackendKeepsFullPlaceholderSeed() {
        let merged = mergeRoster(host: [], fetched: [], fallback: fallback)
        XCTAssertEqual(merged.map { $0.data.id }, ["f1", "f2", "f3", "f4"])
    }

    func testHostOverFourIsCapped() {
        let host = (1...5).map { entry("h\($0)") }
        let merged = mergeRoster(host: host, fetched: [entry("b1")], fallback: fallback)
        XCTAssertEqual(merged.map { $0.data.id }, ["h1", "h2", "h3", "h4"])
    }

    func testBackendDuplicateOfHostIsDroppedAndToppedUpByPlaceholder() {
        let merged = mergeRoster(
            host: [entry("h1")],
            fetched: [entry("h1"), entry("b2"), entry("b3")],
            fallback: fallback
        )
        XCTAssertEqual(merged.map { $0.data.id }, ["h1", "b2", "b3", "f3"])
    }

    func testDuplicateBackendIdsAreCollapsed() {
        let merged = mergeRoster(host: [], fetched: [entry("b1"), entry("b1"), entry("b2")], fallback: fallback)
        XCTAssertEqual(merged.map { $0.data.id }, ["b1", "b2", "f3", "f4"])
    }

    func testLoadingEntriesProducesDistinctLoadingSlots() {
        let loading = CharacterSelector.loadingEntries(3)
        XCTAssertEqual(loading.count, 3)
        XCTAssertTrue(loading.allSatisfy { $0.loading })
        XCTAssertEqual(Set(loading.map { $0.id }).count, 3) // distinct ids
        XCTAssertTrue(CharacterSelector.loadingEntries(0).isEmpty)
    }
}
