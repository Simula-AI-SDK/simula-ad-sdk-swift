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

    // MARK: - Deferred ATT / IDFA scheduling

    @MainActor
    func testAdvertisingReadsStayDisabledByDefault() async {
        let reader = AdvertisingReaderRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )

        store.apply(SimulaPrivacyConfig())
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 0)
        XCTAssertNil(store.currentSnapshot.attStatus)
    }

    @MainActor
    func testOptInReadsOnceOnlyAfterLaunchGateOpens() async {
        let gate = ControllableLaunchSettledGate()
        let reader = AdvertisingReaderRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        let config = SimulaPrivacyConfig(enableAdvertisingId: true)

        store.apply(config)
        store.apply(config)
        store.update(enableAdvertisingId: true)
        await waitForGateWaiter(gate)
        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 0)

        await gate.open()
        await waitUntil { reader.statusCount == 1 && reader.idCount == 1 }
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)
    }

    @MainActor
    func testUnchangedRefreshesAreThrottledForFourHours() async {
        let reader = AdvertisingReaderRecorder()
        let clock = PrivacyClock(100)
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { clock.value },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        let config = SimulaPrivacyConfig(enableAdvertisingId: true)

        store.apply(config)
        await waitUntil { reader.statusCount == 1 && reader.idCount == 1 }
        clock.value += SimulaPrivacy.advertisingRefreshInterval - 1
        store.apply(config)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(reader.statusCount, 1)
        XCTAssertEqual(reader.idCount, 1)

        clock.value += 1
        store.apply(config)
        await waitUntil { reader.statusCount == 2 && reader.idCount == 2 }
    }

    @MainActor
    func testReenablingAdvertisingIdRefreshesWithoutWaitingFourHours() async {
        let reader = AdvertisingReaderRecorder()
        let clock = PrivacyClock(100)
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { clock.value },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )

        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitUntil { reader.statusCount == 1 && reader.idCount == 1 }
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: false))
        XCTAssertNil(store.currentSnapshot.advertisingId)

        clock.value += 1
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitUntil { reader.statusCount == 2 && reader.idCount == 2 }
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")
    }

    @MainActor
    func testPromptCompletionRefreshesImmediatelyAndCancelsDeferredRead() async {
        let gate = ControllableLaunchSettledGate()
        let reader = AdvertisingReaderRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitForGateWaiter(gate)

        store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3)
        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 1)
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")

        await gate.open()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 1)
    }

    @MainActor
    func testForegroundRevocationClearsIdfaInsideFourHours() async {
        let reader = AdvertisingReaderRecorder()
        let clock = PrivacyClock(100)
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { clock.value },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitUntil { reader.idCount == 1 }
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")

        clock.value += 60
        reader.statusRaw = 2
        store.refreshAdvertisingTrackingOnForeground()
        await waitUntil { reader.statusCount == 2 && store.currentSnapshot.attStatus == 2 }

        XCTAssertNil(store.currentSnapshot.advertisingId)
        XCTAssertEqual(reader.idCount, 1, "revocation must not touch the IDFA reader")
    }

    @MainActor
    func testAuthorizedForegroundRefreshChecksStatusButThrottlesIdfa() async {
        let reader = AdvertisingReaderRecorder()
        let clock = PrivacyClock(100)
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { clock.value },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitUntil { reader.idCount == 1 }

        clock.value += 60
        store.refreshAdvertisingTrackingOnForeground()
        await waitUntil { reader.statusCount == 2 }

        XCTAssertEqual(reader.idCount, 1)
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")
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

@MainActor
private final class AdvertisingReaderRecorder {
    var statusRaw = 3
    private(set) var statusCount = 0
    private(set) var idCount = 0
    func readStatus() -> Int? { statusCount += 1; return statusRaw }
    func readId() -> String? { idCount += 1; return "test-idfa" }
}

private final class PrivacyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ value: TimeInterval) { time = value }
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return time }
        set { lock.lock(); time = newValue; lock.unlock() }
    }
}

private func waitForGateWaiter(_ gate: ControllableLaunchSettledGate) async {
    let deadline = Date().addingTimeInterval(TestWait.timeout)
    while await gate.waitCount == 0, Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
