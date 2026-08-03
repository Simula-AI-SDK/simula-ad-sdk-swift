import XCTest
@testable import SimulaAdSDK

final class ExtraParametersTests: XCTestCase {
    func testValidParametersAreCopiedAndSortedDeterministically() throws {
        var input = ["surface": "chat", "page_name": "Search"]
        let normalized = try XCTUnwrap(normalizeExtraParameters(input, warn: {}))
        input["surface"] = "changed"

        XCTAssertEqual(normalized, ["page_name": "Search", "surface": "chat"])
    }

    func testInvalidEntriesAreDroppedWithOneWarning() throws {
        var warnings = 0
        let normalized = try XCTUnwrap(normalizeExtraParameters([
            "$set": "x",
            "page.name": "x",
            String(repeating: "k", count: 65): "x",
            "long": String(repeating: "v", count: 257),
            "valid": "検索",
        ], warn: { warnings += 1 }))

        XCTAssertEqual(normalized, ["valid": "検索"])
        XCTAssertEqual(warnings, 1)
    }

    func testEmptyKeyIsRejected() {
        var warnings = 0

        XCTAssertNil(normalizeExtraParameters(["": "value"], warn: { warnings += 1 }))
        XCTAssertEqual(warnings, 1)
    }

    func testLimitsAreInclusiveAndExcessKeysAreDeterministic() throws {
        var parameters = Dictionary(uniqueKeysWithValues: (0..<11).map { ("k\($0)", "v") })
        parameters[String(repeating: "z", count: 64)] = String(repeating: "v", count: 256)
        var warnings = 0

        let normalized = try XCTUnwrap(normalizeExtraParameters(parameters, warn: { warnings += 1 }))

        XCTAssertEqual(normalized.count, 10)
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(Set(normalized.keys), Set(parameters.keys.sorted().prefix(10)))
    }

    func testLengthsUseBackendCompatibleUnicodeScalarCounts() {
        let allowed = String(repeating: "🚀", count: 64)
        let rejected = String(repeating: "🚀", count: 65)
        var warnings = 0

        XCTAssertEqual(normalizeExtraParameters([allowed: allowed], warn: { warnings += 1 })?[allowed], allowed)
        XCTAssertNil(normalizeExtraParameters([rejected: "value"], warn: { warnings += 1 }))
        XCTAssertEqual(warnings, 1)
    }

    func testStoreUpsertsReplacesAndClears() {
        let store = ExtraParametersStore(warn: {})
        store.set(key: "page_name", value: "Search")
        store.set(key: "page_name", value: "Chat")
        XCTAssertEqual(store.snapshot(), ["page_name": "Chat"])

        store.replace(with: ["surface": "feed"])
        XCTAssertEqual(store.snapshot(), ["surface": "feed"])

        store.replace(with: [:])
        XCTAssertNil(store.snapshot())
    }

    func testDuplicateMergeKeepsNewestKeysWhenCombinedSetExceedsCap() throws {
        let existing = Dictionary(uniqueKeysWithValues: (0..<10).map { ("old\($0)", "old") })
        let newest = Dictionary(uniqueKeysWithValues: (0..<6).map { ("new\($0)", "new") })
        var warnings = 0

        let merged = try XCTUnwrap(mergeExtraParameters(
            existing: existing,
            newest: newest,
            warn: { warnings += 1 }
        ))

        XCTAssertEqual(merged.count, maxExtraParameterEntries)
        XCTAssertTrue(newest.keys.allSatisfy { merged[$0] == "new" })
        XCTAssertEqual(merged.values.filter { $0 == "old" }.count, 4)
        XCTAssertEqual(warnings, 1)
    }

    func testDuplicateMergeUsesNewestValueForCollidingKey() {
        let merged = mergeExtraParameters(
            existing: ["placement": "old", "surface": "feed"],
            newest: ["placement": "new"],
            warn: {}
        )

        XCTAssertEqual(merged, ["placement": "new", "surface": "feed"])
    }
}
