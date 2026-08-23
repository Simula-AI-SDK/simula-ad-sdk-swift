import XCTest
@testable import SimulaAdSDK
#if os(iOS)
import AppTrackingTransparency
#endif

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
    func testDefaultConfigurationReadsAttButNotIdfa() async {
        let reader = AdvertisingReaderRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )

        store.apply(SimulaPrivacyConfig())
        await store.waitForAdvertisingRefreshIdleForTests()

        XCTAssertEqual(reader.statusCount, 1)
        XCTAssertEqual(reader.idCount, 0)
        XCTAssertTrue(reader.allReadsOffMain)
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)
        XCTAssertNil(store.currentSnapshot.advertisingId)
    }

    @MainActor
    func testIdfaDisabledDefersAttReadUntilLaunchGate() async {
        let gate = ControllableLaunchSettledGate()
        let reader = AdvertisingReaderRecorder()
        reader.statusRaw = 2
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )

        store.apply(SimulaPrivacyConfig(enableAdvertisingId: false))
        await waitForGateWaiter(gate)
        XCTAssertEqual(reader.statusCount, 0)

        await gate.open()
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(reader.statusCount, 1)
        XCTAssertEqual(reader.idCount, 0)
        XCTAssertEqual(store.currentSnapshot.attStatus, 2)
        XCTAssertNil(store.currentSnapshot.advertisingId)
    }

    @MainActor
    func testDisablingIdfaWhileDeferredRefreshWaitsStillReadsOnlyAtt() async {
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
        store.update(enableAdvertisingId: false)

        await gate.open()
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(reader.statusCount, 1)
        XCTAssertEqual(reader.idCount, 0)
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)
        XCTAssertNil(store.currentSnapshot.advertisingId)
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
        await store.waitForAdvertisingRefreshIdleForTests()
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
        await store.waitForAdvertisingRefreshIdleForTests()
        clock.value += SimulaPrivacy.advertisingRefreshInterval - 1
        store.apply(config)
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(reader.statusCount, 1)
        XCTAssertEqual(reader.idCount, 1)

        clock.value += 1
        store.apply(config)
        await store.waitForAdvertisingRefreshIdleForTests()
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
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)
        store.update(enableAdvertisingId: false)
        XCTAssertNil(store.currentSnapshot.advertisingId)
        XCTAssertEqual(store.currentSnapshot.attStatus, 3, "disabling IDFA must retain ATT status")

        clock.value += 1
        store.update(enableAdvertisingId: true)
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")
    }

    @MainActor
    func testPromptStoresAttWithoutReadingIdfaWhenCollectionDisabled() async {
        let gate = ControllableLaunchSettledGate()
        let reader = AdvertisingReaderRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: false))
        await waitForGateWaiter(gate)

        await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3)
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)
        XCTAssertNil(store.currentSnapshot.advertisingId)
        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 0)

        await gate.open()
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(reader.statusCount, 0, "prompt result must supersede the deferred status read")
        XCTAssertEqual(reader.idCount, 0)
    }

    @MainActor
    func testCoppaSuppressesAutomaticAndPromptAdvertisingSignals() async {
        let reader = AdvertisingReaderRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )

        store.apply(SimulaPrivacyConfig(coppaApplies: true, enableAdvertisingId: true))
        await store.waitForAdvertisingRefreshIdleForTests()
        await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3)

        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 0)
        XCTAssertNil(store.currentSnapshot.attStatus)
        XCTAssertNil(store.currentSnapshot.advertisingId)
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

        await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3)
        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 1)
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")

        await gate.open()
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(reader.statusCount, 0)
        XCTAssertEqual(reader.idCount, 1)
    }

    @MainActor
    func testBlockedPromptPublishesAttImmediatelyAndCannotOverwriteNewerPromptStatus() async {
        let gate = ControllableLaunchSettledGate()
        let reader = BlockingAdvertisingReader()
        let telemetry = PrivacyReadTelemetryRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() },
            advertisingReadTelemetry: { operation, durationMs, success, _ in
                telemetry.record(operation: operation, snapshotDurationMs: durationMs, success: success)
            }
        )
        telemetry.attach(store)
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitForGateWaiter(gate)

        let stalePrompt = Task { await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3) }
        await waitUntil { reader.firstIdReadStarted }
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)

        await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 2)
        XCTAssertEqual(store.currentSnapshot.attStatus, 2)
        XCTAssertNil(store.currentSnapshot.advertisingId)

        reader.releaseFirstIdRead()
        await stalePrompt.value
        XCTAssertEqual(store.currentSnapshot.attStatus, 2)
        XCTAssertNil(store.currentSnapshot.advertisingId)
        let staleReadEvent = telemetry.events.last { $0.operation == "idfa_read" }
        XCTAssertEqual(staleReadEvent?.snapshot.attStatus, 2)
        XCTAssertNil(staleReadEvent?.snapshot.advertisingId)

        await gate.open()
        await store.waitForAdvertisingRefreshIdleForTests()
    }

    @MainActor
    func testForegroundRefreshSupersedesBlockedPromptIdfaRead() async {
        let gate = ControllableLaunchSettledGate()
        let reader = BlockingAdvertisingReader()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitForGateWaiter(gate)

        let stalePrompt = Task { await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3) }
        await waitUntil { reader.firstIdReadStarted }
        reader.statusRaw = 2
        store.refreshAdvertisingTrackingOnForeground()

        await gate.open()
        reader.releaseFirstIdRead()
        await stalePrompt.value
        await store.waitForAdvertisingRefreshIdleForTests()

        XCTAssertEqual(store.currentSnapshot.attStatus, 2)
        XCTAssertNil(store.currentSnapshot.advertisingId)
    }

    @MainActor
    func testDisableReenableSupersedesBlockedPromptAndKeepsFreshIdfa() async {
        let gate = ControllableLaunchSettledGate()
        let reader = BlockingAdvertisingReader()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitForGateWaiter(gate)

        let stalePrompt = Task { await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3) }
        await waitUntil { reader.firstIdReadStarted }
        store.update(enableAdvertisingId: false)
        store.update(enableAdvertisingId: true)

        await gate.open()
        reader.releaseFirstIdRead()
        await stalePrompt.value
        await store.waitForAdvertisingRefreshIdleForTests()

        XCTAssertEqual(reader.idCount, 2)
        XCTAssertEqual(store.currentSnapshot.attStatus, 3)
        XCTAssertEqual(store.currentSnapshot.advertisingId, "fresh-idfa")
    }

    @MainActor
    func testCoppaTransitionSupersedesBlockedPromptIdfaRead() async {
        let gate = ControllableLaunchSettledGate()
        let reader = BlockingAdvertisingReader()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: gate,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitForGateWaiter(gate)

        let stalePrompt = Task { await store.refreshAdvertisingTrackingAfterPrompt(statusRaw: 3) }
        await waitUntil { reader.firstIdReadStarted }
        store.update(coppaApplies: true)

        reader.releaseFirstIdRead()
        await stalePrompt.value
        XCTAssertNil(store.currentSnapshot.attStatus)
        XCTAssertNil(store.currentSnapshot.advertisingId)

        await gate.open()
        await store.waitForAdvertisingRefreshIdleForTests()
    }

    @MainActor
    func testGenerationChangeDuringIdReadDropsStaleValueAndRunsNewRefreshSerially() async {
        let reader = BlockingAdvertisingReader()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() }
        )
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await waitUntil { reader.firstIdReadStarted }
        store.update(enableAdvertisingId: false)
        store.update(enableAdvertisingId: true)
        reader.releaseFirstIdRead()
        await store.waitForAdvertisingRefreshIdleForTests()

        XCTAssertEqual(reader.idCount, 2)
        XCTAssertEqual(store.currentSnapshot.advertisingId, "fresh-idfa")
        XCTAssertEqual(reader.maxConcurrentReads, 1)
        XCTAssertTrue(reader.allReadsOffMain)
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
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")

        clock.value += 60
        reader.statusRaw = 2
        store.refreshAdvertisingTrackingOnForeground()
        await store.waitForAdvertisingRefreshIdleForTests()

        XCTAssertNil(store.currentSnapshot.advertisingId)
        XCTAssertEqual(reader.idCount, 1, "revocation must not touch the IDFA reader")
    }

    @MainActor
    func testReadTelemetryRunsAfterRevokedStateIsPublishedAndLockIsReleased() async {
        let reader = AdvertisingReaderRecorder()
        let telemetry = PrivacyReadTelemetryRecorder()
        let store = SimulaPrivacy(
            defaults: makeDefaults(),
            launchGate: ImmediateLaunchSettledGate.shared,
            now: { 0 },
            advertisingTrackingStatusReader: { reader.readStatus() },
            advertisingIdReader: { reader.readId() },
            advertisingReadTelemetry: { operation, durationMs, success, _ in
                telemetry.record(operation: operation, snapshotDurationMs: durationMs, success: success)
            }
        )
        telemetry.attach(store)
        store.apply(SimulaPrivacyConfig(enableAdvertisingId: true))
        await store.waitForAdvertisingRefreshIdleForTests()
        XCTAssertEqual(telemetry.events.last { $0.operation == "idfa_read" }?.snapshot.advertisingId, "test-idfa")

        telemetry.clear()
        reader.statusRaw = 2
        store.refreshAdvertisingTrackingOnForeground()
        await store.waitForAdvertisingRefreshIdleForTests()

        let statusEvent = telemetry.events.last { $0.operation == "att_status_read" }
        XCTAssertEqual(statusEvent?.snapshot.attStatus, 2)
        XCTAssertNil(statusEvent?.snapshot.advertisingId)
    }

    #if os(iOS)
    @MainActor
    func testPublicTrackingAuthorizationStatusReadsCurrentPlatformValueDirectly() {
        let store = SimulaPrivacy(defaults: makeDefaults())
        XCTAssertEqual(store.trackingAuthorizationStatus, ATTrackingManager.trackingAuthorizationStatus)
    }
    #endif

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
        await store.waitForAdvertisingRefreshIdleForTests()

        clock.value += 60
        store.refreshAdvertisingTrackingOnForeground()
        await store.waitForAdvertisingRefreshIdleForTests()

        XCTAssertEqual(reader.idCount, 1)
        XCTAssertEqual(store.currentSnapshot.advertisingId, "test-idfa")
    }

    // MARK: - Provider privacy-change classification

    func testAttTransitionMatrixOnlySuppressesInitialNilToNotDetermined() {
        let statuses: [Int?] = [nil, 0, 1, 2, 3]

        for previousStatus in statuses {
            for currentStatus in statuses {
                let expectedResync = previousStatus != currentStatus
                    && !(previousStatus == nil && currentStatus == 0)
                XCTAssertEqual(
                    classifyPrivacyChange(
                        from: ConsentSnapshot(attStatus: previousStatus),
                        to: ConsentSnapshot(attStatus: currentStatus)
                    ),
                    PrivacyChangeImpact(
                        requiresSessionResync: expectedResync,
                        requiresWebViewReset: false
                    ),
                    "unexpected impact for ATT \(String(describing: previousStatus)) -> \(String(describing: currentStatus))"
                )
            }
        }
    }

    func testNilToNotDeterminedWithAnotherPrivacyChangeStillResyncs() {
        let previous = ConsentSnapshot(tcString: "old", attStatus: nil)
        let current = ConsentSnapshot(tcString: "new", attStatus: 0)

        XCTAssertEqual(
            classifyPrivacyChange(from: previous, to: current),
            PrivacyChangeImpact(requiresSessionResync: true, requiresWebViewReset: false)
        )
    }

    func testNilToNotDeterminedWithStorageChangeResyncsAndResetsWebViews() {
        let previous = ConsentSnapshot(
            gdprApplies: true,
            tcfPurpose1Consent: true,
            attStatus: nil
        )
        let current = ConsentSnapshot(
            gdprApplies: true,
            tcfPurpose1Consent: false,
            attStatus: 0
        )

        XCTAssertEqual(
            classifyPrivacyChange(from: previous, to: current),
            PrivacyChangeImpact(requiresSessionResync: true, requiresWebViewReset: true)
        )
    }

    func testIdfaChangesResyncSessionWithoutResettingWebViews() {
        let snapshots = [
            ConsentSnapshot(attStatus: 3),
            ConsentSnapshot(advertisingId: "first-idfa", attStatus: 3),
            ConsentSnapshot(advertisingId: "second-idfa", attStatus: 3),
            ConsentSnapshot(attStatus: 3),
        ]

        for (previous, current) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertEqual(
                classifyPrivacyChange(from: previous, to: current),
                PrivacyChangeImpact(requiresSessionResync: true, requiresWebViewReset: false)
            )
        }
    }

    func testStoragePolicyChangeResyncsSessionAndResetsWebViews() {
        let persistent = ConsentSnapshot(gdprApplies: true, tcfPurpose1Consent: true)
        let ephemeral = ConsentSnapshot(gdprApplies: true, tcfPurpose1Consent: false)

        XCTAssertEqual(
            classifyPrivacyChange(from: persistent, to: ephemeral),
            PrivacyChangeImpact(requiresSessionResync: true, requiresWebViewReset: true)
        )
    }

    func testWirePrivacyChangeWithSameStoragePolicyOnlyResyncsSession() {
        let previous = ConsentSnapshot(tcString: "old", gdprApplies: true, tcfPurpose1Consent: true)
        let current = ConsentSnapshot(tcString: "new", gdprApplies: true, tcfPurpose1Consent: true)

        XCTAssertEqual(
            classifyPrivacyChange(from: previous, to: current),
            PrivacyChangeImpact(requiresSessionResync: true, requiresWebViewReset: false)
        )
        XCTAssertEqual(
            classifyPrivacyChange(from: current, to: current),
            PrivacyChangeImpact(requiresSessionResync: false, requiresWebViewReset: false)
        )
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

private final class AdvertisingReaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _statusRaw = 3
    private var _statusCount = 0
    private var _idCount = 0
    private var _allReadsOffMain = true

    var statusRaw: Int {
        get { lock.lock(); defer { lock.unlock() }; return _statusRaw }
        set { lock.lock(); _statusRaw = newValue; lock.unlock() }
    }
    var statusCount: Int { lock.lock(); defer { lock.unlock() }; return _statusCount }
    var idCount: Int { lock.lock(); defer { lock.unlock() }; return _idCount }
    var allReadsOffMain: Bool { lock.lock(); defer { lock.unlock() }; return _allReadsOffMain }

    func readStatus() -> Int? {
        lock.lock()
        _statusCount += 1
        _allReadsOffMain = _allReadsOffMain && !Thread.isMainThread
        let status = _statusRaw
        lock.unlock()
        return status
    }

    func readId() -> String? {
        lock.lock()
        _idCount += 1
        _allReadsOffMain = _allReadsOffMain && !Thread.isMainThread
        lock.unlock()
        return "test-idfa"
    }
}

private final class PrivacyReadTelemetryRecorder: @unchecked Sendable {
    struct Event {
        let operation: String
        let snapshot: ConsentSnapshot
    }

    private let lock = NSLock()
    private weak var store: SimulaPrivacy?
    private var recorded: [Event] = []

    func attach(_ store: SimulaPrivacy) { lock.lock(); self.store = store; lock.unlock() }

    func record(operation: String, snapshotDurationMs _: Int, success _: Bool) {
        lock.lock(); let store = self.store; lock.unlock()
        guard let snapshot = store?.currentSnapshot else { return }
        lock.lock(); recorded.append(Event(operation: operation, snapshot: snapshot)); lock.unlock()
    }

    var events: [Event] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded.removeAll(); lock.unlock() }
}

private final class BlockingAdvertisingReader: @unchecked Sendable {
    private let lock = NSLock()
    private let firstIdGate = DispatchSemaphore(value: 0)
    private var _statusRaw = 3
    private var _statusCount = 0
    private var _idCount = 0
    private var activeReads = 0
    private var _maxConcurrentReads = 0
    private var _firstIdReadStarted = false
    private var _allReadsOffMain = true

    var statusRaw: Int {
        get { lock.lock(); defer { lock.unlock() }; return _statusRaw }
        set { lock.lock(); _statusRaw = newValue; lock.unlock() }
    }
    var statusCount: Int { lock.lock(); defer { lock.unlock() }; return _statusCount }
    var idCount: Int { lock.lock(); defer { lock.unlock() }; return _idCount }
    var firstIdReadStarted: Bool { lock.lock(); defer { lock.unlock() }; return _firstIdReadStarted }
    var maxConcurrentReads: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrentReads }
    var allReadsOffMain: Bool { lock.lock(); defer { lock.unlock() }; return _allReadsOffMain }

    func readStatus() -> Int? {
        beginRead()
        lock.lock()
        _statusCount += 1
        let status = _statusRaw
        lock.unlock()
        endRead()
        return status
    }

    func readId() -> String? {
        beginRead()
        lock.lock()
        _idCount += 1
        let count = _idCount
        if count == 1 { _firstIdReadStarted = true }
        lock.unlock()
        if count == 1 { firstIdGate.wait() }
        endRead()
        return count == 1 ? "stale-idfa" : "fresh-idfa"
    }

    func releaseFirstIdRead() { firstIdGate.signal() }

    private func beginRead() {
        lock.lock()
        activeReads += 1
        _maxConcurrentReads = max(_maxConcurrentReads, activeReads)
        _allReadsOffMain = _allReadsOffMain && !Thread.isMainThread
        lock.unlock()
    }

    private func endRead() {
        lock.lock(); activeReads -= 1; lock.unlock()
    }
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
    await waitUntil { await gate.waitCount > 0 }
}
