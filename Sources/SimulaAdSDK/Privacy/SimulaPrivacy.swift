import Foundation
import Combine
#if os(iOS)
import AppTrackingTransparency
import AdSupport
#endif

// MARK: - SimulaPrivacy

/// Process-wide consent store and source of truth for the SDK's privacy signals.
///
/// Responsibilities:
/// - **Auto-reads** the IAB-standard keys a CMP writes to `UserDefaults`
///   (`IABTCF_TCString`, `IABTCF_gdprApplies`, `IABTCF_PurposeConsents`,
///   `IABUSPrivacy_String`, `IABGPP_HDR_GppString`, `IABGPP_GppSID`).
/// - **Auto-refreshes** when the CMP updates those keys (observes
///   `UserDefaults.didChangeNotification`).
/// - Merges **explicit overrides** from `SimulaPrivacyConfig` / `update(...)` on
///   top of the IAB-read values.
/// - Owns ATT + IDFA collection, gated by `enableAdvertisingId` and `coppaApplies`.
/// - Publishes `snapshot` for SwiftUI; exposes `currentSnapshot` for thread-safe
///   reads from the API client.
///
/// Most apps use the shared instance, `SimulaPrivacy.shared`. A custom
/// `UserDefaults` can be injected (used by tests).
public final class SimulaPrivacy: ObservableObject {
    /// The shared, process-wide store. `SimulaProvider` feeds it and observes it.
    public static let shared = SimulaPrivacy()

    /// Main-thread mirror of the current snapshot, for SwiftUI observation.
    @Published public private(set) var snapshot = ConsentSnapshot()

    // MARK: - State

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var explicitConfig = SimulaPrivacyConfig()
    private var collectedAdvertisingId: String?
    private var attStatusRaw: Int?
    private var lockedSnapshot = ConsentSnapshot()
    private var observer: NSObjectProtocol?

    /// IAB-standard `UserDefaults` keys, written by an in-app CMP.
    private enum IABKey {
        static let tcString = "IABTCF_TCString"
        static let gdprApplies = "IABTCF_gdprApplies"
        static let purposeConsents = "IABTCF_PurposeConsents"
        static let uspString = "IABUSPrivacy_String"
        static let gppString = "IABGPP_HDR_GppString"
        static let gppSid = "IABGPP_GppSID"
    }

    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recompute()
        // CMPs write the IAB keys asynchronously and may refresh them later; pick
        // changes up automatically. `object: nil` because the notification is not
        // reliably posted with the defaults instance as its object.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recompute()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Public API

    /// The current resolved snapshot. Thread-safe; use this from non-UI code
    /// (e.g. the API client) instead of the `@Published` `snapshot`.
    public var currentSnapshot: ConsentSnapshot {
        lock.lock(); defer { lock.unlock() }
        return lockedSnapshot
    }

    /// Replace the explicit configuration wholesale (provider init / CMP handoff).
    public func apply(_ config: SimulaPrivacyConfig) {
        lock.lock()
        explicitConfig = config
        if !config.enableAdvertisingId || config.coppaApplies { collectedAdvertisingId = nil }
        lock.unlock()
        refreshAdvertisingIdIfNeeded()
        recompute()
    }

    /// Merge a partial runtime update (e.g. a CMP refresh). Only the supplied
    /// fields change; `nil` arguments leave the current value untouched.
    public func update(
        hasPrivacyConsent: Bool? = nil,
        tcString: String? = nil,
        uspString: String? = nil,
        gppString: String? = nil,
        gppSid: String? = nil,
        gdprApplies: Bool? = nil,
        coppaApplies: Bool? = nil,
        enableAdvertisingId: Bool? = nil
    ) {
        lock.lock()
        var c = explicitConfig
        if let hasPrivacyConsent { c.hasPrivacyConsent = hasPrivacyConsent }
        if let tcString { c.tcString = tcString }
        if let uspString { c.uspString = uspString }
        if let gppString { c.gppString = gppString }
        if let gppSid { c.gppSid = gppSid }
        if let gdprApplies { c.gdprApplies = gdprApplies }
        if let coppaApplies { c.coppaApplies = coppaApplies }
        if let enableAdvertisingId { c.enableAdvertisingId = enableAdvertisingId }
        explicitConfig = c
        if !c.enableAdvertisingId || c.coppaApplies { collectedAdvertisingId = nil }
        lock.unlock()
        refreshAdvertisingIdIfNeeded()
        recompute()
    }

    // MARK: - ATT / IDFA (iOS)

    #if os(iOS)
    /// Current ATT authorization status without prompting.
    public var trackingAuthorizationStatus: ATTrackingManager.AuthorizationStatus {
        ATTrackingManager.trackingAuthorizationStatus
    }

    /// Presents the ATT prompt (if still undetermined) and — when advertising-id
    /// collection is enabled and COPPA does not apply — reads the IDFA into the
    /// snapshot on authorization. Returns the resulting status.
    ///
    /// The host app must declare `NSUserTrackingUsageDescription` in its Info.plist.
    @MainActor
    @discardableResult
    public func requestTrackingAuthorization() async -> ATTrackingManager.AuthorizationStatus {
        let status = await ATTrackingManager.requestTrackingAuthorization()
        applyTrackingStatus(status)
        return status
    }

    private func applyTrackingStatus(_ status: ATTrackingManager.AuthorizationStatus) {
        lock.lock()
        attStatusRaw = Int(status.rawValue)
        let enabled = explicitConfig.enableAdvertisingId && !explicitConfig.coppaApplies
        collectedAdvertisingId = (status == .authorized && enabled) ? SimulaPrivacy.readIDFA() : nil
        lock.unlock()
        recompute()
    }
    #endif

    /// Reads the IDFA when collection is enabled, COPPA does not apply, and ATT is
    /// authorized — used when the host enables collection *after* authorization.
    private func refreshAdvertisingIdIfNeeded() {
        #if os(iOS)
        lock.lock()
        let enabled = explicitConfig.enableAdvertisingId && !explicitConfig.coppaApplies
        lock.unlock()
        guard enabled else { return }
        let status = ATTrackingManager.trackingAuthorizationStatus
        lock.lock()
        attStatusRaw = Int(status.rawValue)
        collectedAdvertisingId = (status == .authorized) ? SimulaPrivacy.readIDFA() : nil
        lock.unlock()
        #endif
    }

    #if os(iOS)
    /// Reads the IDFA, mapping the all-zero "unavailable" id to `nil`.
    private static func readIDFA() -> String? {
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        if id == zeroUUID {
            #if targetEnvironment(simulator)
            // Simulators have no real IDFA; surface a stable dummy so the
            // end-to-end gating/wire path is observable without a device.
            return "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
            #else
            return nil
            #endif
        }
        return id
    }
    #endif

    // MARK: - Snapshot building

    private func recompute() {
        let new = buildSnapshot()
        lock.lock()
        let changed = lockedSnapshot != new
        if changed { lockedSnapshot = new }
        lock.unlock()
        guard changed else { return }
        if Thread.isMainThread {
            snapshot = new
        } else {
            DispatchQueue.main.async { [weak self] in self?.snapshot = new }
        }
    }

    private func buildSnapshot() -> ConsentSnapshot {
        lock.lock()
        let cfg = explicitConfig
        let adId = collectedAdvertisingId
        let att = attStatusRaw
        lock.unlock()

        // Explicit (provider/CMP) values win; otherwise fall back to IAB-read keys.
        return ConsentSnapshot(
            hasPrivacyConsent: cfg.hasPrivacyConsent,
            tcString: cfg.tcString ?? nonEmpty(defaults.string(forKey: IABKey.tcString)),
            uspString: cfg.uspString ?? nonEmpty(defaults.string(forKey: IABKey.uspString)),
            gppString: cfg.gppString ?? nonEmpty(defaults.string(forKey: IABKey.gppString)),
            gppSid: cfg.gppSid ?? readGppSid(),
            gdprApplies: cfg.gdprApplies ?? readGdprApplies(),
            coppaApplies: cfg.coppaApplies,
            tcfPurpose1Consent: readPurpose1Consent(),
            advertisingId: cfg.coppaApplies ? nil : adId,
            attStatus: att
        )
    }

    // MARK: - IAB key readers

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// `IABTCF_gdprApplies` is stored as a Number (0/1). `nil` when unset.
    private func readGdprApplies() -> Bool? {
        guard defaults.object(forKey: IABKey.gdprApplies) != nil else { return nil }
        return defaults.integer(forKey: IABKey.gdprApplies) == 1
    }

    /// `IABGPP_GppSID` is stored as an underscore-separated string of section IDs
    /// (e.g. `"2_6"`). Normalize to comma-separated to match the wire contract.
    private func readGppSid() -> String? {
        guard let s = nonEmpty(defaults.string(forKey: IABKey.gppSid)) else { return nil }
        return s.replacingOccurrences(of: "_", with: ",")
    }

    /// TCF Purpose 1 consent = first character of `IABTCF_PurposeConsents` (a
    /// binary string indexed from Purpose 1); `'1'` means consented.
    private func readPurpose1Consent() -> Bool? {
        guard let s = nonEmpty(defaults.string(forKey: IABKey.purposeConsents)) else { return nil }
        return s.first == "1"
    }
}
