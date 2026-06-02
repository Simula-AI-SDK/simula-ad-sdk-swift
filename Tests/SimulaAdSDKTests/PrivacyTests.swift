import XCTest
@testable import SimulaAdSDK

/// Unit tests for the privacy/consent layer: snapshot wire formats, derived
/// gating, and the `SimulaPrivacy` store's IAB auto-read + explicit overrides.
final class PrivacyTests: XCTestCase {

    /// A fresh, isolated `UserDefaults` suite seeded with the given keys.
    private func makeDefaults(_ pairs: [String: Any] = [:]) -> UserDefaults {
        let name = "SimulaPrivacyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        for (key, value) in pairs { defaults.set(value, forKey: key) }
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - ConsentSnapshot wire formats

    func testConsentHeaders() {
        let snap = ConsentSnapshot(
            hasPrivacyConsent: true,
            tcString: "CPtc", uspString: "1YNN",
            gppString: "DBABgpp", gppSid: "2,6",
            gdprApplies: true, coppaApplies: false,
            advertisingId: "AAAA"
        )
        let h = snap.consentHeaders()
        XCTAssertEqual(h["X-Simula-GDPR-Applies"], "1")
        XCTAssertEqual(h["X-Simula-Consent-TCString"], "CPtc")
        XCTAssertEqual(h["X-Simula-Consent-USP"], "1YNN")
        XCTAssertEqual(h["X-Simula-Consent-GPP"], "DBABgpp")
        XCTAssertEqual(h["X-Simula-Consent-GPP-SID"], "2,6")
        XCTAssertEqual(h["X-Simula-COPPA"], "0")
        XCTAssertEqual(h["X-Simula-IDFA"], "AAAA")
    }

    func testConsentHeadersOmitsEmptyButKeepsCoppa() {
        let h = ConsentSnapshot().consentHeaders()
        XCTAssertNil(h["X-Simula-Consent-TCString"])
        XCTAssertNil(h["X-Simula-GDPR-Applies"])
        XCTAssertNil(h["X-Simula-IDFA"])
        XCTAssertEqual(h["X-Simula-COPPA"], "0") // always present
    }

    func testPrivacyBodyIsSerializable() throws {
        let snap = ConsentSnapshot(
            hasPrivacyConsent: true, tcString: "CPtc",
            gdprApplies: true, coppaApplies: true,
            advertisingId: "IDFA1", attStatus: 3
        )
        let b = snap.privacyBody()
        XCTAssertEqual(b["hasPrivacyConsent"] as? Bool, true)
        XCTAssertEqual(b["coppaApplies"] as? Bool, true)
        XCTAssertEqual(b["gdprApplies"] as? Int, 1)
        XCTAssertEqual(b["tcString"] as? String, "CPtc")
        XCTAssertEqual(b["attStatus"] as? Int, 3)
        XCTAssertEqual(b["idfa"] as? String, "IDFA1")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))
    }

    // MARK: - Derived gating

    func testCoppaAndConsentGatePrimaryUserID() {
        XCTAssertTrue(ConsentSnapshot(hasPrivacyConsent: true, coppaApplies: false).allowsPrimaryUserID)
        XCTAssertFalse(ConsentSnapshot(hasPrivacyConsent: true, coppaApplies: true).allowsPrimaryUserID)
        XCTAssertFalse(ConsentSnapshot(hasPrivacyConsent: false, coppaApplies: false).allowsPrimaryUserID)
    }

    func testPurpose1GatesLocalStorage() {
        XCTAssertTrue(ConsentSnapshot(tcfPurpose1Consent: nil).allowsLocalStorage)  // unknown → permit
        XCTAssertTrue(ConsentSnapshot(tcfPurpose1Consent: true).allowsLocalStorage)
        XCTAssertFalse(ConsentSnapshot(tcfPurpose1Consent: false).allowsLocalStorage)
    }

    // MARK: - Store: IAB auto-read

    func testStoreReadsIABKeys() {
        let store = SimulaPrivacy(defaults: makeDefaults([
            "IABTCF_TCString": "CPtcstring",
            "IABTCF_gdprApplies": 1,
            "IABTCF_PurposeConsents": "10000",
            "IABUSPrivacy_String": "1YNN",
            "IABGPP_HDR_GppString": "DBABgpp",
            "IABGPP_GppSID": "2_6",
        ]))
        let s = store.currentSnapshot
        XCTAssertEqual(s.tcString, "CPtcstring")
        XCTAssertEqual(s.gdprApplies, true)
        XCTAssertEqual(s.tcfPurpose1Consent, true)
        XCTAssertEqual(s.uspString, "1YNN")
        XCTAssertEqual(s.gppString, "DBABgpp")
        XCTAssertEqual(s.gppSid, "2,6") // underscore normalized to comma
    }

    func testStoreUnsetGdprAppliesIsNil() {
        let store = SimulaPrivacy(defaults: makeDefaults())
        XCTAssertNil(store.currentSnapshot.gdprApplies)
    }

    func testStorePurpose1Denied() {
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_PurposeConsents": "0111"]))
        XCTAssertEqual(store.currentSnapshot.tcfPurpose1Consent, false)
        XCTAssertFalse(store.currentSnapshot.allowsLocalStorage)
    }

    // MARK: - Store: explicit overrides

    func testExplicitConfigOverridesIAB() {
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_TCString": "IAB_VALUE"]))
        store.apply(SimulaPrivacyConfig(tcString: "EXPLICIT"))
        XCTAssertEqual(store.currentSnapshot.tcString, "EXPLICIT")
    }

    func testExplicitNilFallsBackToIAB() {
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_TCString": "IAB_VALUE"]))
        store.apply(SimulaPrivacyConfig(tcString: nil))
        XCTAssertEqual(store.currentSnapshot.tcString, "IAB_VALUE")
    }

    func testUpdatePartialMergeKeepsOtherFields() {
        let store = SimulaPrivacy(defaults: makeDefaults())
        store.apply(SimulaPrivacyConfig(tcString: "TC1", uspString: "1YNN"))
        store.update(tcString: "TC2")
        XCTAssertEqual(store.currentSnapshot.tcString, "TC2")
        XCTAssertEqual(store.currentSnapshot.uspString, "1YNN")
    }

    func testCoppaSuppressesAdvertisingIdInStore() {
        let store = SimulaPrivacy(defaults: makeDefaults())
        store.apply(SimulaPrivacyConfig(coppaApplies: true, enableAdvertisingId: true))
        XCTAssertNil(store.currentSnapshot.advertisingId)
    }
}
