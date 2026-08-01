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
            tcfPurpose1Consent: false,
            advertisingId: "AAAA"
        )
        let h = snap.consentHeaders()
        XCTAssertEqual(h["X-Simula-GDPR-Applies"], "1")
        XCTAssertEqual(h["X-Simula-Consent-TCString"], "CPtc")
        XCTAssertEqual(h["X-Simula-Consent-USP"], "1YNN")
        XCTAssertEqual(h["X-Simula-Consent-GPP"], "DBABgpp")
        XCTAssertEqual(h["X-Simula-Consent-GPP-SID"], "2,6")
        XCTAssertEqual(h["X-Simula-Consent-Purpose1"], "0")
        XCTAssertEqual(h["X-Simula-COPPA"], "0")
        // The raw advertising id is intentionally NOT in headers (session body only).
        XCTAssertNil(h["X-Simula-IDFA"])
        XCTAssertEqual(snap.privacyBody()["idfa"] as? String, "AAAA")
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
            tcfPurpose1Consent: true,
            advertisingId: "IDFA1", attStatus: 3
        )
        let b = snap.privacyBody()
        XCTAssertEqual(b["hasPrivacyConsent"] as? Bool, true)
        XCTAssertEqual(b["coppaApplies"] as? Bool, true)
        XCTAssertEqual(b["gdprApplies"] as? Int, 1)
        XCTAssertEqual(b["tcString"] as? String, "CPtc")
        XCTAssertEqual(b["tcfPurpose1Consent"] as? Bool, true)
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

    func testPurpose1GatesLocalStorageOutsideGdpr() {
        XCTAssertTrue(ConsentSnapshot(tcfPurpose1Consent: nil).allowsLocalStorage)  // unknown → permit
        XCTAssertTrue(ConsentSnapshot(tcfPurpose1Consent: true).allowsLocalStorage)
        XCTAssertFalse(ConsentSnapshot(tcfPurpose1Consent: false).allowsLocalStorage)
    }

    func testUnknownPurpose1DeniedUnderGdpr() {
        // Under GDPR an unknown Purpose 1 must be treated as denied.
        XCTAssertFalse(ConsentSnapshot(gdprApplies: true, tcfPurpose1Consent: nil).allowsLocalStorage)
        XCTAssertFalse(ConsentSnapshot(gdprApplies: true, tcfPurpose1Consent: false).allowsLocalStorage)
        XCTAssertTrue(ConsentSnapshot(gdprApplies: true, tcfPurpose1Consent: true).allowsLocalStorage)
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

    func testStoreCoercesNumericIABValues() {
        // Some CMPs store a single-section GppSID (and gdprApplies) as Numbers.
        let store = SimulaPrivacy(defaults: makeDefaults([
            "IABGPP_GppSID": 2,
            "IABTCF_gdprApplies": 1,
        ]))
        XCTAssertEqual(store.currentSnapshot.gppSid, "2")
        XCTAssertEqual(store.currentSnapshot.gdprApplies, true)
    }

    func testGppSidParsesArrayStringAndNumber() {
        // CMPs write IABGPP_GppSID inconsistently: array, underscore string, or number.
        XCTAssertEqual(SimulaPrivacy(defaults: makeDefaults(["IABGPP_GppSID": [2, 6]])).currentSnapshot.gppSid, "2,6")
        XCTAssertEqual(SimulaPrivacy(defaults: makeDefaults(["IABGPP_GppSID": "2_6"])).currentSnapshot.gppSid, "2,6")
        XCTAssertEqual(SimulaPrivacy(defaults: makeDefaults(["IABGPP_GppSID": "2,6"])).currentSnapshot.gppSid, "2,6")
        XCTAssertEqual(SimulaPrivacy(defaults: makeDefaults(["IABGPP_GppSID": 2])).currentSnapshot.gppSid, "2")
    }

    func testStorePurpose1Denied() {
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_PurposeConsents": "0111"]))
        XCTAssertEqual(store.currentSnapshot.tcfPurpose1Consent, false)
        XCTAssertFalse(store.currentSnapshot.allowsLocalStorage)
    }

    func testStoreRefreshesWhenIabValuesChangeAfterInit() async {
        let defaults = makeDefaults()
        let store = SimulaPrivacy(defaults: defaults)
        XCTAssertNil(store.currentSnapshot.tcString)

        defaults.set("LATE_TC", forKey: "IABTCF_TCString")
        // UserDefaults' notification carries no changed key; the store compares its
        // six-value IAB fingerprint and recomputes only when that fingerprint changed.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        let deadline = Date().addingTimeInterval(1)
        while store.currentSnapshot.tcString != "LATE_TC", Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(store.currentSnapshot.tcString, "LATE_TC")
    }

    // MARK: - Store: explicit overrides

    func testExplicitConfigOverridesIAB() {
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_TCString": "IAB_VALUE"]))
        store.apply(SimulaPrivacyConfig(tcString: "EXPLICIT"))
        XCTAssertEqual(store.currentSnapshot.tcString, "EXPLICIT")
    }

    func testExplicitPurpose1OverrideWinsOverIAB() {
        // IAB says Purpose 1 granted ("1..."), explicit override denies it.
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_PurposeConsents": "10000"]))
        store.apply(SimulaPrivacyConfig(gdprApplies: true, tcfPurpose1Consent: false))
        XCTAssertEqual(store.currentSnapshot.tcfPurpose1Consent, false)
        XCTAssertFalse(store.currentSnapshot.allowsLocalStorage)
    }

    func testExplicitNilFallsBackToIAB() {
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_TCString": "IAB_VALUE"]))
        store.apply(SimulaPrivacyConfig(tcString: nil))
        XCTAssertEqual(store.currentSnapshot.tcString, "IAB_VALUE")
    }

    func testClearConsentFallsBackToIAB() {
        // Clearing an explicit override falls back to the auto-read IAB value.
        let store = SimulaPrivacy(defaults: makeDefaults(["IABTCF_TCString": "IAB_TC"]))
        store.apply(SimulaPrivacyConfig(tcString: "EXPLICIT", uspString: "1YNN"))
        store.clearConsent(tcString: true)
        XCTAssertEqual(store.currentSnapshot.tcString, "IAB_TC")  // fell back to IAB
        XCTAssertEqual(store.currentSnapshot.uspString, "1YNN")   // untouched
    }

    func testClearConsentToNilWhenNoIAB() {
        let store = SimulaPrivacy(defaults: makeDefaults())
        store.apply(SimulaPrivacyConfig(gppString: "GPP"))
        store.clearConsent(gppString: true)
        XCTAssertNil(store.currentSnapshot.gppString)
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

    // MARK: - Privacy resolution (shared by SimulaAds.initialize via SimulaProvider)

    @MainActor
    func testProviderExplicitPrivacyConfigWins() {
        // An explicit `privacy` config is stored verbatim (the imperative
        // `SimulaAds.initialize(privacy:)` forwards straight into this init).
        let cfg = SimulaPrivacyConfig(hasPrivacyConsent: true, gdprApplies: true, coppaApplies: true)
        let provider = SimulaProvider(apiKey: "test-key", privacy: cfg)
        XCTAssertEqual(provider.privacyConfig, cfg)
    }

    @MainActor
    func testProviderSeedsConfigFromLegacyFlagWhenNoPrivacy() {
        // No `privacy` given → the legacy `hasPrivacyConsent` flag seeds the config.
        let provider = SimulaProvider(apiKey: "test-key", hasPrivacyConsent: false)
        XCTAssertFalse(provider.privacyConfig.hasPrivacyConsent)
    }

    @MainActor
    func testProviderExplicitPrivacyOverridesLegacyFlag() {
        // Explicit `privacy` (consent granted) wins even when the legacy flag says false.
        let cfg = SimulaPrivacyConfig(hasPrivacyConsent: true)
        let provider = SimulaProvider(apiKey: "test-key", hasPrivacyConsent: false, privacy: cfg)
        XCTAssertTrue(provider.privacyConfig.hasPrivacyConsent)
    }
}
