import Foundation

// MARK: - SimulaPrivacyConfig

/// Public privacy / consent configuration supplied to `SimulaProvider`.
///
/// Every field defaults to a contextual, no-tracking posture, so existing
/// integrations behave byte-for-byte as before until a host opts in. Explicit
/// non-`nil` values here take precedence over anything the SDK auto-reads from
/// the IAB-standard `UserDefaults` keys a CMP writes (see `SimulaPrivacy`).
public struct SimulaPrivacyConfig: Sendable, Equatable {
    /// Legacy coarse consent flag. When `false`, suppresses PII (the `ppid`).
    /// Retained for backward compatibility; folded into the consent snapshot.
    public var hasPrivacyConsent: Bool

    /// IAB TCF v2.2 consent string (mirror of `IABTCF_TCString`).
    public var tcString: String?

    /// IAB US Privacy (CCPA) string, e.g. `"1YNN"` (mirror of `IABUSPrivacy_String`).
    public var uspString: String?

    /// IAB Global Privacy Platform string (mirror of `IABGPP_HDR_GppString`).
    public var gppString: String?

    /// Applicable GPP section IDs, comma-separated e.g. `"2,6"` (mirror of `IABGPP_GppSID`).
    public var gppSid: String?

    /// Whether GDPR applies. `nil` = unknown/unset (mirror of `IABTCF_gdprApplies`).
    public var gdprApplies: Bool?

    /// Whether COPPA (child-directed) treatment applies. When `true`, PII and the
    /// advertising identifier are suppressed regardless of ATT / consent.
    public var coppaApplies: Bool

    /// Opt-in switch for advertising-identifier (IDFA) collection. Default `false`
    /// keeps the SDK contextual-only. Even when `true`, the IDFA is read only when
    /// ATT is authorized, COPPA does not apply, and consent permits.
    public var enableAdvertisingId: Bool

    public init(
        hasPrivacyConsent: Bool = true,
        tcString: String? = nil,
        uspString: String? = nil,
        gppString: String? = nil,
        gppSid: String? = nil,
        gdprApplies: Bool? = nil,
        coppaApplies: Bool = false,
        enableAdvertisingId: Bool = false
    ) {
        self.hasPrivacyConsent = hasPrivacyConsent
        self.tcString = tcString
        self.uspString = uspString
        self.gppString = gppString
        self.gppSid = gppSid
        self.gdprApplies = gdprApplies
        self.coppaApplies = coppaApplies
        self.enableAdvertisingId = enableAdvertisingId
    }
}

// MARK: - ConsentSnapshot

/// An immutable, value-typed snapshot of the resolved privacy state at a point
/// in time. Produced by `SimulaPrivacy` (merging explicit config over IAB-read
/// values); consumed by the API client to build request headers and the
/// `/session/create` body.
public struct ConsentSnapshot: Sendable, Equatable {
    public let hasPrivacyConsent: Bool
    public let tcString: String?
    public let uspString: String?
    public let gppString: String?
    public let gppSid: String?
    public let gdprApplies: Bool?
    public let coppaApplies: Bool
    /// TCF Purpose 1 ("store and/or access information on a device") consent,
    /// parsed from the first character of `IABTCF_PurposeConsents`. `nil` = unknown.
    public let tcfPurpose1Consent: Bool?
    /// The collected advertising identifier (IDFA), or `nil` when not collected /
    /// not allowed. Never the all-zero "unavailable" UUID.
    public let advertisingId: String?
    /// Raw ATT authorization status (`ATTrackingManager.AuthorizationStatus.rawValue`),
    /// or `nil` on platforms without ATT / before it is resolved.
    public let attStatus: Int?

    public init(
        hasPrivacyConsent: Bool = true,
        tcString: String? = nil,
        uspString: String? = nil,
        gppString: String? = nil,
        gppSid: String? = nil,
        gdprApplies: Bool? = nil,
        coppaApplies: Bool = false,
        tcfPurpose1Consent: Bool? = nil,
        advertisingId: String? = nil,
        attStatus: Int? = nil
    ) {
        self.hasPrivacyConsent = hasPrivacyConsent
        self.tcString = tcString
        self.uspString = uspString
        self.gppString = gppString
        self.gppSid = gppSid
        self.gdprApplies = gdprApplies
        self.coppaApplies = coppaApplies
        self.tcfPurpose1Consent = tcfPurpose1Consent
        self.advertisingId = advertisingId
        self.attStatus = attStatus
    }

    // MARK: Derived gating

    /// Whether the host's `primaryUserID` (`ppid`) may be forwarded.
    public var allowsPrimaryUserID: Bool { hasPrivacyConsent && !coppaApplies }

    /// Whether non-essential local storage / caching is permitted. Under TCF a
    /// denied Purpose 1 means the SDK must avoid non-essential on-device storage.
    /// When GDPR applies, an *unknown* Purpose 1 is treated as denied (consent
    /// must be explicit); outside GDPR we permit by default (contextual).
    public var allowsLocalStorage: Bool {
        if gdprApplies == true { return tcfPurpose1Consent == true }
        return tcfPurpose1Consent ?? true
    }

    // MARK: Wire formats

    /// Consent *metadata* as request headers — used when the backend wants consent
    /// on ad-serving / tracking calls in addition to the session body. The raw
    /// advertising identifier is intentionally **not** included here (it travels
    /// only in the session body) to minimize PII exposure on per-request calls.
    public func consentHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let gdprApplies { h["X-Simula-GDPR-Applies"] = gdprApplies ? "1" : "0" }
        if let tcString, !tcString.isEmpty { h["X-Simula-Consent-TCString"] = tcString }
        if let uspString, !uspString.isEmpty { h["X-Simula-Consent-USP"] = uspString }
        if let gppString, !gppString.isEmpty { h["X-Simula-Consent-GPP"] = gppString }
        if let gppSid, !gppSid.isEmpty { h["X-Simula-Consent-GPP-SID"] = gppSid }
        h["X-Simula-COPPA"] = coppaApplies ? "1" : "0"
        return h
    }

    /// Consent signals as the `privacy` JSON block embedded in `/session/create`.
    public func privacyBody() -> [String: Any] {
        var b: [String: Any] = [
            "hasPrivacyConsent": hasPrivacyConsent,
            "coppaApplies": coppaApplies,
        ]
        if let gdprApplies { b["gdprApplies"] = gdprApplies ? 1 : 0 }
        if let tcString, !tcString.isEmpty { b["tcString"] = tcString }
        if let uspString, !uspString.isEmpty { b["uspString"] = uspString }
        if let gppString, !gppString.isEmpty { b["gppString"] = gppString }
        if let gppSid, !gppSid.isEmpty { b["gppSid"] = gppSid }
        if let attStatus { b["attStatus"] = attStatus }
        if let advertisingId, !advertisingId.isEmpty { b["idfa"] = advertisingId }
        return b
    }
}
