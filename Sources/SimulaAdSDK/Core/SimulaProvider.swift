import Foundation
import SwiftUI
import Combine
#if os(iOS)
import AppTrackingTransparency
#endif

// MARK: - SimulaProvider

/// The central state manager for the Simula Ad SDK.
/// Translates the React Context pattern from SimulaProvider.tsx.
///
/// Usage:
/// ```swift
/// SimulaProviderView(apiKey: "your-key") {
///     ContentView()
/// }
/// ```
///
/// Inside child views:
/// ```swift
/// @EnvironmentObject var simula: SimulaProvider
/// ```
public final class SimulaProvider: ObservableObject {
    // MARK: - Configuration (set once at init)

    /// The API key for authenticating with Simula services
    public let apiKey: String

    /// Whether the SDK is in development mode
    public let devMode: Bool

    /// Optional primary user identifier. Mutable mid-session via `updatePrimaryUserID(_:)`; stored in a
    /// thread-safe box so the telemetry flush (a background task) reads it without a data race.
    public var primaryUserID: String? { ppidStore.current }
    private let ppidStore: PPIDStore

    /// Legacy coarse consent flag. When false, suppresses collection of PII.
    /// Retained as a convenience alias for `privacyConfig.hasPrivacyConsent`.
    public let hasPrivacyConsent: Bool

    /// Resolved privacy / consent configuration. Pushed into the process-wide
    /// `SimulaPrivacy` store, which also auto-reads IAB-standard CMP keys.
    public let privacyConfig: SimulaPrivacyConfig

    /// Native-ad targeting context attached to every `POST /load/native` under this provider.
    /// Set at init and replaceable wholesale at runtime via `updateContext(_:)` (PRD). Read on the
    /// main thread by `NativeAdSlot` / the preload path.
    public private(set) var adContext: SimulaAdContext?

    // MARK: - Session State

    /// The server session ID, set after successful session creation
    @Published public private(set) var sessionId: String? {
        didSet { Telemetry.shared.setSessionId(sessionId) } // correlate telemetry to the session
    }

    /// The in-flight session-creation task, if any. Lets concurrent callers
    /// coalesce onto a single request instead of each firing their own.
    /// Touched only from `@MainActor` methods.
    private var sessionTask: Task<String?, Never>?

    // MARK: - Ad Caching Infrastructure (matching Flutter/React SDK)
    // Host-facing legacy cache API (getCachedAd/cacheAd/…). No internal callers, but a host using it
    // across many distinct slots would grow these without bound — so each is a size-capped store.

    /// Cache of fetched ads keyed by "slot:position"
    private var adCache = BoundedStore<AdData>(maxEntries: 64)

    /// Cache of measured heights keyed by "slot:position"
    private var heightCache = BoundedStore<CGFloat>(maxEntries: 64)

    /// "slot:position" keys that returned no-fill
    private var noFillCache = BoundedStore<Bool>(maxEntries: 64)

    // MARK: - Internal

    private let api: SimulaAPI

    /// Subscriptions to the consent store (re-sync session on CMP refresh).
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    public init(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        privacy: SimulaPrivacyConfig? = nil,
        telemetryEnabled: Bool = true,
        adContext: SimulaAdContext? = nil
    ) {
        // Validate at init (matches React's validateSimulaProviderProps call)
        do {
            try validateSimulaProviderProps(apiKey: apiKey)
        } catch {
            // In React, this throws and prevents render. In Swift, we assert in debug.
            assertionFailure("[SimulaSDK] \(error.localizedDescription)")
        }

        self.apiKey = apiKey
        self.devMode = devMode
        self.ppidStore = PPIDStore(primaryUserID)
        self.hasPrivacyConsent = hasPrivacyConsent
        self.adContext = adContext

        // When an explicit `privacy` config is given it wins; otherwise the legacy
        // `hasPrivacyConsent` flag seeds the config so existing call sites behave
        // exactly as before.
        var resolved = privacy ?? SimulaPrivacyConfig()
        if privacy == nil { resolved.hasPrivacyConsent = hasPrivacyConsent }
        self.privacyConfig = resolved
        self.api = SimulaAPI()

        // Install telemetry before the first request so the /session/create call (and every
        // subsequent SDK request) is captured. First call wins, so a re-created provider
        // doesn't churn it; the facade re-gates PII on the live consent snapshot.
        Telemetry.shared.initialize(
            apiKey: apiKey,
            devMode: devMode,
            enabled: telemetryEnabled,
            // Read the PPID live so a mid-session updatePrimaryUserID is honored; the box is Sendable.
            primaryUserIDProvider: { [ppidStore = self.ppidStore] in ppidStore.current }
        )

        // Feed the process-wide store, then re-sync the session whenever consent
        // changes (host CMP refresh or ATT result) so the backend sees current signals.
        SimulaPrivacy.shared.apply(resolved)
        SimulaPrivacy.shared.$snapshot
            .dropFirst()
            .removeDuplicates()
            // CMPs write the IAB keys in a burst; coalesce so a settled consent
            // state triggers exactly one /session/create instead of a race.
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    #if os(iOS)
                    // The storage policy may have flipped (TCF Purpose 1 / GDPR);
                    // drop prewarmed web views so the next game/ad is built with a
                    // data store matching the new consent. (`acquire` also guards
                    // this lazily; this just frees stale views proactively.)
                    WebViewPool.shared.clear()
                    #endif
                    await self?.resyncSession()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Session Management

    /// Creates a session with the server. Called automatically by `SimulaProviderView`.
    /// Translates the `useEffect(() => { ensureSession() }, [...])` from SimulaProvider.tsx.
    @MainActor
    public func createSession() async {
        _ = await ensureSession()
    }

    /// Returns a valid session id, creating one on demand if needed.
    ///
    /// - Returns the existing id immediately if a session already exists.
    /// - Coalesces concurrent callers onto a single in-flight request, so a
    ///   fast game tap during launch awaits the same session creation instead
    ///   of racing it (previously this surfaced as "Session invalid").
    /// - Retries on the next call after a failed attempt (the failed task is
    ///   cleared), so a transient network error at launch no longer disables
    ///   minigames for the whole app session.
    @MainActor
    @discardableResult
    public func ensureSession() async -> String? {
        if let sessionId, !sessionId.isEmpty { return sessionId }
        if let sessionTask { return await sessionTask.value }

        let snapshot = SimulaPrivacy.shared.currentSnapshot
        let task = Task<String?, Never> { [api, apiKey, devMode, ppidStore] in
            // Emit session_created/session_failed once per creation attempt (callers coalesce onto
            // this single task). Best-effort telemetry; never affects session creation.
            let startNanos = DispatchTime.now().uptimeNanoseconds
            func durationMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000) }
            do {
                let id = try await api.createSession(
                    apiKey: apiKey,
                    devMode: devMode,
                    primaryUserID: ppidStore.current,
                    privacy: snapshot
                )
                let resolved = (id?.isEmpty == false) ? id : nil
                if resolved != nil {
                    Telemetry.shared.recordOperation(name: "session_created", durationMs: durationMs(), success: true)
                } else {
                    Telemetry.shared.recordOperation(name: "session_failed", durationMs: durationMs(), success: false, failureClass: "no_session")
                }
                return resolved
            } catch {
                Telemetry.shared.recordOperation(name: "session_failed", durationMs: durationMs(), success: false, failureClass: "no_session")
                return nil
            }
        }
        sessionTask = task

        let id = await task.value
        // Clear the task so a failed attempt can be retried on the next call.
        sessionTask = nil
        if let id, !id.isEmpty {
            sessionId = id
        }
        return sessionId
    }

    /// Invalidates the current session and recreates it so the backend sees the
    /// latest consent signals. Triggered when the consent store changes.
    @MainActor
    private func resyncSession() async {
        sessionId = nil
        sessionTask = nil
        await ensureSession()
    }

    // MARK: - Consent Updates

    /// Replace the privacy configuration at runtime (e.g. after the host CMP
    /// gathers or refreshes consent). Forwarded to the process-wide store; the
    /// session re-syncs automatically.
    public func updateConsent(_ config: SimulaPrivacyConfig) {
        SimulaPrivacy.shared.apply(config)
    }

    // MARK: - Native Ad Context

    /// Replace the native-ad targeting context at runtime (e.g. when the feed category changes).
    /// A full replacement, not a merge (PRD); all subsequent `POST /load/native` calls use the new
    /// value. Ads already preloaded under the old context are unaffected.
    public func updateContext(_ context: SimulaAdContext?) {
        adContext = context
    }

    // MARK: - Primary User ID (PPID)

    /// Update the primary user id (PPID) mid-session — after a login, a logout, or a first login that
    /// happened only after the session was created. Mirrors `updateContext`. A nil/empty id clears the
    /// PPID (logout).
    ///
    /// Effects: (1) the value the next `session/create` carries is updated; (2) telemetry reports the
    /// new value; (3) when a session already exists, the live session is PATCHed server-side. Clearing
    /// (nil) updates local + telemetry state only — the backend's `PATCH …/ppid/{ppid}` path can't
    /// express an empty id. The network call is best-effort.
    @MainActor
    public func updatePrimaryUserID(_ id: String?) {
        let normalized = (id?.isEmpty == false) ? id : nil
        ppidStore.set(normalized)
        // With no session yet, the pending/next createSession carries the new value, so no PATCH is
        // needed. PATCH a live session to push the new value server-side.
        guard let normalized, let sid = sessionId, !sid.isEmpty else { return }
        Task { [api, apiKey] in
            await api.updatePpid(apiKey: apiKey, sessionId: sid, ppid: normalized)
        }
    }

    /// Merge a partial consent update at runtime. Only the supplied fields change.
    public func updateConsent(
        hasPrivacyConsent: Bool? = nil,
        tcString: String? = nil,
        uspString: String? = nil,
        gppString: String? = nil,
        gppSid: String? = nil,
        gdprApplies: Bool? = nil,
        tcfPurpose1Consent: Bool? = nil,
        coppaApplies: Bool? = nil,
        enableAdvertisingId: Bool? = nil
    ) {
        SimulaPrivacy.shared.update(
            hasPrivacyConsent: hasPrivacyConsent,
            tcString: tcString,
            uspString: uspString,
            gppString: gppString,
            gppSid: gppSid,
            gdprApplies: gdprApplies,
            tcfPurpose1Consent: tcfPurpose1Consent,
            coppaApplies: coppaApplies,
            enableAdvertisingId: enableAdvertisingId
        )
    }

    /// Clears the named explicit consent overrides (the store then falls back to any
    /// auto-read IAB value). Use to *remove* a signal you previously set — `update`
    /// can only change or leave fields, not clear them.
    public func clearConsent(
        tcString: Bool = false,
        uspString: Bool = false,
        gppString: Bool = false,
        gppSid: Bool = false,
        gdprApplies: Bool = false,
        tcfPurpose1Consent: Bool = false
    ) {
        SimulaPrivacy.shared.clearConsent(
            tcString: tcString,
            uspString: uspString,
            gppString: gppString,
            gppSid: gppSid,
            gdprApplies: gdprApplies,
            tcfPurpose1Consent: tcfPurpose1Consent
        )
    }

    #if os(iOS)
    /// Presents the App Tracking Transparency prompt and, when advertising-id
    /// collection is enabled (and COPPA does not apply), begins forwarding the
    /// IDFA on authorization. Call from the host's launch flow or a post-CMP
    /// callback. Requires `NSUserTrackingUsageDescription` in the app's Info.plist.
    @MainActor
    @discardableResult
    public func requestTrackingAuthorization() async -> ATTrackingManager.AuthorizationStatus {
        await SimulaPrivacy.shared.requestTrackingAuthorization()
    }
    #endif

    // MARK: - Cache Key Helper

    /// Creates a cache key from slot and position (translates `getCacheKey` from SimulaProvider.tsx)
    private func cacheKey(slot: String, position: Int) -> String {
        "\(slot):\(position)"
    }

    // MARK: - Ad Cache Methods

    /// Get cached ad for a slot/position (translates `getCachedAd`)
    public func getCachedAd(slot: String, position: Int) -> AdData? {
        adCache[cacheKey(slot: slot, position: position)]
    }

    /// Cache an ad for a slot/position (translates `cacheAd`)
    public func cacheAd(slot: String, position: Int, ad: AdData) {
        adCache[cacheKey(slot: slot, position: position)] = ad
    }

    /// Get cached height for a slot/position (translates `getCachedHeight`)
    public func getCachedHeight(slot: String, position: Int) -> CGFloat? {
        heightCache[cacheKey(slot: slot, position: position)]
    }

    /// Cache height for a slot/position (translates `cacheHeight`)
    public func cacheHeight(slot: String, position: Int, height: CGFloat) {
        heightCache[cacheKey(slot: slot, position: position)] = height
    }

    /// Check if a slot/position has no fill (translates `hasNoFill`)
    public func hasNoFill(slot: String, position: Int) -> Bool {
        noFillCache.contains(cacheKey(slot: slot, position: position))
    }

    /// Mark a slot/position as having no fill (translates `markNoFill`)
    public func markNoFill(slot: String, position: Int) {
        noFillCache[cacheKey(slot: slot, position: position)] = true
    }
}

// MARK: - Non-observing provider environment key

/// Carries the `SimulaProvider` down the view tree WITHOUT subscribing readers to its
/// `objectWillChange`. `NativeAdSlot` reads this (via `@Environment(\.simulaProvider)`) instead of
/// `@EnvironmentObject`, so a `@Published` change on the provider — e.g. `sessionId` after session
/// create/refresh — doesn't invalidate and re-render every ad slot in a feed at once. Injected by
/// `SimulaProviderView` alongside the existing `.environmentObject(provider)` (which the menu
/// components still use).
private struct SimulaProviderKey: EnvironmentKey {
    static let defaultValue: SimulaProvider? = nil
}

extension EnvironmentValues {
    var simulaProvider: SimulaProvider? {
        get { self[SimulaProviderKey.self] }
        set { self[SimulaProviderKey.self] = newValue }
    }
}

// MARK: - PPIDStore

/// Thread-safe holder for the mutable PPID. `Sendable` so the telemetry flush closure and the
/// session-create task read the live value off the main thread without a data race.
final class PPIDStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String?) { value = initial }
    var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: String?) { lock.lock(); value = newValue; lock.unlock() }
}

// MARK: - BoundedStore

/// A tiny insertion-ordered, size-capped key→value store backing the legacy host-facing ad caches.
/// Evicts the oldest entry once past `maxEntries`. Not internally synchronized — used exactly where
/// the raw dictionaries were (the public cache methods), so it inherits their single-threaded contract.
private struct BoundedStore<Value> {
    private let maxEntries: Int
    private var storage: [String: Value] = [:]
    private var order: [String] = []

    init(maxEntries: Int) { self.maxEntries = maxEntries }

    subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                if storage.removeValue(forKey: key) != nil, let i = order.firstIndex(of: key) {
                    order.remove(at: i)
                }
                return
            }
            if storage[key] == nil { order.append(key) }
            storage[key] = newValue
            while storage.count > maxEntries, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
    }

    func contains(_ key: String) -> Bool { storage[key] != nil }
}

// MARK: - SimulaProviderView

/// A SwiftUI wrapper view that provides `SimulaProvider` to its children via EnvironmentObject.
/// This is the direct equivalent of `<SimulaProvider apiKey="...">` in React.
///
/// Usage:
/// ```swift
/// SimulaProviderView(apiKey: "your-api-key", devMode: true) {
///     MyAppContent()
/// }
/// ```
public struct SimulaProviderView<Content: View>: View {
    @StateObject private var provider: SimulaProvider
    private let content: () -> Content
    /// The resolved config, kept so prop changes can be pushed to the store —
    /// `@StateObject` is initialized only once and ignores later init args.
    private let resolvedConfig: SimulaPrivacyConfig
    /// Native-ad targeting context, kept so prop changes can be pushed to the (possibly reused)
    /// provider — like `resolvedConfig`, the `@StateObject` ignores later init args.
    private let adContext: SimulaAdContext?

    public init(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        privacy: SimulaPrivacyConfig? = nil,
        telemetryEnabled: Bool = true,
        adContext: SimulaAdContext? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.adContext = adContext
        // Resolve the privacy config: an explicit `privacy` wins; otherwise the
        // legacy `hasPrivacyConsent` flag seeds it. Kept so prop changes can be
        // pushed into the store via `.task(id: resolvedConfig)` below.
        var resolved = privacy ?? SimulaPrivacyConfig()
        if privacy == nil { resolved.hasPrivacyConsent = hasPrivacyConsent }
        self.resolvedConfig = resolved

        // Reuse the process-wide provider when its core config matches, to avoid
        // recreating the session/store. A divergent privacy config on the shared
        // instance is reconciled by `updateConsent(resolvedConfig)` in the
        // `.task(id:)` below, so reuse stays safe.
        let provider: SimulaProvider
        if let shared = SimulaAds.shared,
           shared.apiKey == apiKey,
           shared.devMode == devMode,
           shared.primaryUserID == primaryUserID,
           shared.hasPrivacyConsent == hasPrivacyConsent {
            provider = shared
        } else {
            provider = SimulaProvider(
                apiKey: apiKey,
                devMode: devMode,
                primaryUserID: primaryUserID,
                hasPrivacyConsent: hasPrivacyConsent,
                privacy: privacy,
                telemetryEnabled: telemetryEnabled,
                adContext: adContext
            )
        }
        self._provider = StateObject(wrappedValue: provider)
        self.content = content
    }

    public var body: some View {
        content()
            .environmentObject(provider)
            // Also expose it non-observingly so NativeAdSlot can read it without re-rendering on
            // every @Published change (see EnvironmentValues.simulaProvider).
            .environment(\.simulaProvider, provider)
            .task {
                await provider.createSession()
            }
            // Push privacy-prop changes into the store. SwiftUI does not re-init
            // the @StateObject when the `privacy`/`hasPrivacyConsent` props change,
            // so without this a host updating them at render time would be ignored.
            .task(id: resolvedConfig) {
                provider.updateConsent(resolvedConfig)
            }
            // Push native-ad context prop changes onto the (possibly reused) provider. Only when a
            // value is supplied, so a host setting context imperatively via SimulaAds.updateContext
            // isn't clobbered by a nil prop.
            .task(id: adContext) {
                if let adContext { provider.updateContext(adContext) }
            }
    }
}
