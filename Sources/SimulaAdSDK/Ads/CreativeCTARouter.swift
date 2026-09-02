import Foundation
#if os(iOS)
import UIKit
#endif

final class BoundedCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?

    init(_ completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    func complete() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}

final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var completion: (@Sendable () -> Void)?

    init(count: Int, completion: @escaping @Sendable () -> Void) {
        self.remaining = max(1, count)
        self.completion = completion
    }

    func satisfy() {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        remaining -= 1
        guard remaining <= 0 else { lock.unlock(); return }
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}

final class WeakObjectReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object? = nil) {
        self.value = value
    }
}

private let directAppStoreSchemes: Set<String> = ["itms", "itms-apps", "itms-appss"]

enum ValidatedSKANIdentifier: Equatable {
    case campaign(Int)
    case source(Int)
}

enum SKANRejectionReason: String, Equatable {
    case missingNetwork = "missing_network"
    case invalidSourceAppID = "invalid_source_app_id"
    case invalidNonce = "invalid_nonce"
    case invalidTimestamp = "invalid_timestamp"
    case missingSignature = "missing_signature"
    case unsupportedVersion = "unsupported_version"
    case missingCampaignID = "missing_campaign_id"
    case invalidCampaignID = "invalid_campaign_id"
    case missingSourceID = "missing_source_id"
    case invalidSourceID = "invalid_source_id"
    case unsupportedOS = "unsupported_os"
    case invalidAdvertisedAppID = "invalid_advertised_app_id"
    case unsupportedViewVersion = "unsupported_view_version"
}

enum SKANIdentifierValidation: Equatable {
    case valid(ValidatedSKANIdentifier)
    case rejected(SKANRejectionReason)
}

enum SKANAttributionSurface: String {
    case storeProduct = "store_product"
    case interstitialViewThrough = "interstitial_view_through"
    case skOverlayImpression = "skoverlay_impression"
    case skOverlayFallback = "skoverlay_fallback"
}

func validateSKANIdentifier(
    version: String,
    campaignIdentifier: Int?,
    sourceIdentifier: Int?
) -> SKANIdentifierValidation {
    switch version {
    case "2.0", "2.1", "2.2", "3.0":
        guard let campaignIdentifier else { return .rejected(.missingCampaignID) }
        guard (1...100).contains(campaignIdentifier) else { return .rejected(.invalidCampaignID) }
        return .valid(.campaign(campaignIdentifier))
    case "4.0":
        guard let sourceIdentifier else { return .rejected(.missingSourceID) }
        guard (0...9_999).contains(sourceIdentifier) else { return .rejected(.invalidSourceID) }
        return .valid(.source(sourceIdentifier))
    default:
        return .rejected(.unsupportedVersion)
    }
}

func skanPayloadRejectionReason(_ skan: SKANParameters, signature: String) -> SKANRejectionReason? {
    guard !skan.adNetworkIdentifier.isEmpty else { return .missingNetwork }
    guard skan.sourceAppStoreIdentifier >= 0 else { return .invalidSourceAppID }
    guard UUID(uuidString: skan.nonce) != nil else { return .invalidNonce }
    guard skan.timestamp > 0 else { return .invalidTimestamp }
    guard !signature.isEmpty else { return .missingSignature }
    if case .rejected(let reason) = validateSKANIdentifier(
        version: skan.version,
        campaignIdentifier: skan.campaignIdentifier,
        sourceIdentifier: skan.sourceIdentifier
    ) {
        return reason
    }
    return nil
}

/// Selects the identifier covered by the server signature. The signature version, not the running
/// OS, determines which mutually exclusive field StoreKit must receive.
func validatedSKANIdentifier(
    version: String,
    campaignIdentifier: Int?,
    sourceIdentifier: Int?
) -> ValidatedSKANIdentifier? {
    guard case .valid(let identifier) = validateSKANIdentifier(
        version: version,
        campaignIdentifier: campaignIdentifier,
        sourceIdentifier: sourceIdentifier
    ) else { return nil }
    return identifier
}

func isDirectAppStoreScheme(_ scheme: String?) -> Bool {
    guard let scheme else { return false }
    return directAppStoreSchemes.contains(scheme.lowercased())
}

enum ClickSource: String, Codable, Sendable {
    case primaryCTA = "primary_cta"
    case storePrompt = "store_prompt"
    case installBanner = "install_banner"
    case fallbackCTA = "fallback_cta"
    case autoRedirect = "auto_redirect"
}

struct ClickInteraction: Equatable, Sendable {
    let id: String
    let source: ClickSource

    init(id: String = UUID().uuidString, source: ClickSource) {
        self.id = id
        self.source = source
    }
}

enum ClickHandoffPersistence {
    static let timeout: TimeInterval = 0.35

    static func wait(
        interaction: ClickInteraction,
        beaconImpressionId: String?,
        completion: @escaping @Sendable () -> Void
    ) {
        let bounded = BoundedCompletion(completion)
        let requiresBeacon = beaconImpressionId?.isEmpty == false
        let latch = CompletionLatch(count: requiresBeacon ? 2 : 1) { bounded.complete() }

        Telemetry.shared.afterPendingPersistence(timeout: timeout) { latch.satisfy() }
        if let beaconImpressionId, !beaconImpressionId.isEmpty {
            AdBeaconManager.shared.afterClickPersistence(
                impressionId: beaconImpressionId,
                interactionId: interaction.id,
                timeout: timeout
            ) { latch.satisfy() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            bounded.complete()
        }
    }
}

/// Pure one-gesture claim shared by both WebKit delegate paths. The coordinator is main-actor
/// isolated, so claiming the callback and destination route through this value is atomic.
struct CreativeClickClaim {
    private var lastClaimUptime: TimeInterval = -1

    mutating func claim(
        userActivated: Bool,
        source: ClickSource,
        now: TimeInterval,
        interactionId: String = UUID().uuidString
    ) -> ClickInteraction? {
        guard userActivated, now - lastClaimUptime >= 0.5 else { return nil }
        lastClaimUptime = now
        return ClickInteraction(id: interactionId, source: source)
    }
}

final class AttributionRouteLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    let automaticRoutes = AutomaticRouteCoordinator()
    let automaticRouteScope = AnyHashable(UUID())

    func activate() {
        lock.lock(); active = true; lock.unlock()
        automaticRoutes.activate(scope: automaticRouteScope)
    }

    func deactivate() {
        lock.lock(); active = false; lock.unlock()
        automaticRoutes.deactivate(scope: automaticRouteScope)
    }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

enum AttributionRoutePath: String, Equatable {
    case mmpRedirect = "mmp_redirect"
    case directStore = "direct_store"
    case rawStoreFallback = "raw_store_fallback"
    case web = "web"
    case customScheme = "custom_scheme"
    case automatic = "automatic"
}

struct AttributionRouteOutcome: Equatable {
    let path: AttributionRoutePath?
    let success: Bool
    let failureClass: String?
}

func preferredActiveScene<Scene: AnyObject>(
    originating: Scene?,
    scenes: [Scene],
    isActive: (Scene) -> Bool,
    hasKeyWindow: (Scene) -> Bool
) -> Scene? {
    if let originating, isActive(originating) { return originating }
    return scenes.first { isActive($0) && hasKeyWindow($0) }
        ?? scenes.first { isActive($0) }
}

func committedRouteTerminalAvailability(originatingScene: AnyObject?) -> () -> Bool {
    let scene = WeakObjectReference(originatingScene)
    return {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active,
              let windowScene = scene.value as? UIWindowScene else { return false }
        return windowScene.activationState == .foregroundActive
        #else
        return scene.value != nil
        #endif
    }
}

#if os(iOS)
@MainActor
func preferredForegroundActiveWindowScene(originating: UIWindowScene? = nil) -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return preferredActiveScene(
        originating: originating,
        scenes: scenes,
        isActive: { $0.activationState == .foregroundActive },
        hasKeyWindow: { $0.windows.contains(where: \.isKeyWindow) }
    )
}
#endif

@MainActor
final class AttributionRouteExecution {
    private enum State {
        case pending
        case running(AttributionRoutePath)
        case finished
    }

    private var state = State.pending
    private var uiHandoffReleased = false
    private var deterministicTrackerDelivered = false
    let id: UUID
    private let originatingSceneWasProvided: Bool
    private weak var originatingSceneObject: AnyObject?
#if os(iOS)
    var originatingScene: UIWindowScene? { originatingSceneObject as? UIWindowScene }
#endif
    private let isActive: () -> Bool
    private let allowsDetachedDeterministicAttribution: Bool
    private let survivesPresentationTeardownAfterBegin: Bool
    private let canCompleteAfterPresentationTeardown: () -> Bool
    private let onUIHandoffReleased: () -> Void
    private let onOutcome: (AttributionRouteOutcome) -> Void

    init(
        id: UUID = UUID(),
        originatingScene: AnyObject? = nil,
        isActive: @escaping () -> Bool,
        allowsDetachedDeterministicAttribution: Bool = false,
        survivesPresentationTeardownAfterBegin: Bool = false,
        canCompleteAfterPresentationTeardown: @escaping () -> Bool = { true },
        onUIHandoffReleased: @escaping () -> Void = {},
        onOutcome: @escaping (AttributionRouteOutcome) -> Void
    ) {
        self.id = id
        self.originatingSceneWasProvided = originatingScene != nil
        self.originatingSceneObject = originatingScene
        self.isActive = isActive
        self.allowsDetachedDeterministicAttribution = allowsDetachedDeterministicAttribution
        self.survivesPresentationTeardownAfterBegin = survivesPresentationTeardownAfterBegin
        self.canCompleteAfterPresentationTeardown = canCompleteAfterPresentationTeardown
        self.onUIHandoffReleased = onUIHandoffReleased
        self.onOutcome = onOutcome
    }

    /// Releases only the short-lived UI close gate. A committed user route remains running until a
    /// terminal outcome arrives even if its fullscreen presentation is subsequently torn down.
    func releaseUIHandoff() {
        guard !uiHandoffReleased else { return }
        uiHandoffReleased = true
        onUIHandoffReleased()
    }

    /// Delivers the click-classified tracker once for a deterministic tracker + store route. A
    /// committed user click may outlive its presentation; automatic routes remain presentation-bound.
    func deliverDeterministicTracker(_ tracker: URL, sender: (URL) -> Void) {
        switch state {
        case .pending, .running:
            break
        case .finished:
            return
        }
        guard !deterministicTrackerDelivered,
              allowsDetachedDeterministicAttribution || presentationIsActive() else { return }
        deterministicTrackerDelivered = true
        sender(tracker)
    }

    private func presentationIsActive() -> Bool {
        guard isActive() else { return false }
        #if os(iOS)
        if originatingSceneWasProvided {
            guard let originatingScene else { return false }
            return originatingScene.activationState == .foregroundActive
        }
        #else
        if originatingSceneWasProvided && originatingSceneObject == nil { return false }
        #endif
        return true
    }

    func begin(path: AttributionRoutePath) -> Bool {
        guard case .pending = state else { return false }
        guard presentationIsActive() else {
            state = .finished
            releaseUIHandoff()
            onOutcome(AttributionRouteOutcome(
                path: path,
                success: false,
                failureClass: "inactive_presentation"
            ))
            return false
        }
        state = .running(path)
        return true
    }

    func complete(_ route: () -> Bool) {
        guard case .running(let path) = state else { return }
        state = .finished
        releaseUIHandoff()
        let presentationActive = presentationIsActive()
        let canCompleteCommittedRoute = !presentationActive
            && survivesPresentationTeardownAfterBegin
            && canCompleteAfterPresentationTeardown()
        guard presentationActive || canCompleteCommittedRoute else {
            onOutcome(AttributionRouteOutcome(
                path: path,
                success: false,
                failureClass: "inactive_presentation"
            ))
            return
        }
        let success = route()
        onOutcome(AttributionRouteOutcome(
            path: path,
            success: success,
            failureClass: success ? nil : "route_unavailable"
        ))
    }

    func fail(_ failureClass: String) {
        guard case .running(let path) = state else { return }
        state = .finished
        releaseUIHandoff()
        onOutcome(AttributionRouteOutcome(path: path, success: false, failureClass: failureClass))
    }

    func cancel() {
        let path: AttributionRoutePath?
        switch state {
        case .pending: path = nil
        case .running(let runningPath): path = runningPath
        case .finished: return
        }
        state = .finished
        releaseUIHandoff()
        onOutcome(AttributionRouteOutcome(path: path, success: false, failureClass: "cancelled"))
    }
}

@MainActor
func startAsynchronousAttributionRoute(
    execution: AttributionRouteExecution,
    start: () -> Void
) {
    guard execution.begin(path: .mmpRedirect) else { return }
    start()
    execution.releaseUIHandoff()
}

func recordAttributionRoute(
    outcome: AttributionRouteOutcome,
    source: ClickSource,
) {
    var breadcrumb = "result=\(outcome.success ? "attempted" : "failed");source=\(source.rawValue)"
    if let path = outcome.path { breadcrumb += ";path=\(path.rawValue)" }
    Telemetry.shared.recordOperation(
        name: "attribution_route",
        durationMs: 0,
        success: outcome.success,
        failureClass: outcome.failureClass,
        breadcrumb: breadcrumb
    )
}

@MainActor
func makeCreativeAttributionRouteExecution(
    id: UUID,
    source: ClickSource,
    originatingScene: AnyObject? = nil,
    isActive: @escaping () -> Bool,
    canCompleteAfterPresentationTeardown: (() -> Bool)? = nil,
    onUIHandoffReleased: @escaping () -> Void,
    onTerminalOutcome: ((AttributionRouteOutcome) -> Void)?,
    onFinished: @escaping (UUID) -> Void
) -> AttributionRouteExecution {
    AttributionRouteExecution(
        id: id,
        originatingScene: originatingScene,
        isActive: isActive,
        allowsDetachedDeterministicAttribution: true,
        survivesPresentationTeardownAfterBegin: true,
        canCompleteAfterPresentationTeardown: canCompleteAfterPresentationTeardown
            ?? committedRouteTerminalAvailability(originatingScene: originatingScene),
        onUIHandoffReleased: onUIHandoffReleased,
        onOutcome: { outcome in
            recordAttributionRoute(outcome: outcome, source: source)
            onTerminalOutcome?(outcome)
            onFinished(id)
        }
    )
}

enum AutomaticRouteRequestResult: Equatable {
    case started
    case deferred
    case suppressed
    case stale
}

struct AutomaticRouteUserHandoff: Equatable {
    fileprivate let id: Int
}

/// Presentation-scoped arbitration between billable user routes and non-billable automatic routes.
/// Callers are main-thread confined; the value remains Foundation-only so its policy is pure-testable.
final class AutomaticRouteCoordinator {
    private struct DeferredRoute {
        let scope: AnyHashable
        let start: () -> Void
    }

    private var activeScope: AnyHashable?
    private var pendingUserHandoff: AutomaticRouteUserHandoff?
    private var nextHandoffId = 0
    private var userRouteCommitted = false
    private var automaticRouteStarted = false
    private var deferredRoute: DeferredRoute?

    func activate(scope: AnyHashable) {
        guard activeScope != scope else { return }
        activeScope = scope
        pendingUserHandoff = nil
        deferredRoute = nil
    }

    func deactivate(scope: AnyHashable) {
        guard activeScope == scope else { return }
        activeScope = nil
        pendingUserHandoff = nil
        deferredRoute = nil
    }

    func reset(scope: AnyHashable) {
        activeScope = scope
        pendingUserHandoff = nil
        nextHandoffId = 0
        userRouteCommitted = false
        automaticRouteStarted = false
        deferredRoute = nil
    }

    func beginUserHandoff(scope: AnyHashable) -> AutomaticRouteUserHandoff? {
        guard activeScope == scope, pendingUserHandoff == nil else { return nil }
        nextHandoffId += 1
        let handoff = AutomaticRouteUserHandoff(id: nextHandoffId)
        pendingUserHandoff = handoff
        return handoff
    }

    @discardableResult
    func commitUserHandoff(_ handoff: AutomaticRouteUserHandoff, scope: AnyHashable) -> Bool {
        guard activeScope == scope, pendingUserHandoff == handoff else { return false }
        pendingUserHandoff = nil
        userRouteCommitted = true
        deferredRoute = nil
        return true
    }

    @discardableResult
    func cancelUserHandoff(_ handoff: AutomaticRouteUserHandoff, scope: AnyHashable) -> Bool {
        guard activeScope == scope, pendingUserHandoff == handoff else { return false }
        pendingUserHandoff = nil
        guard !userRouteCommitted, !automaticRouteStarted,
              let deferredRoute, deferredRoute.scope == scope else { return true }
        self.deferredRoute = nil
        automaticRouteStarted = true
        deferredRoute.start()
        return true
    }

    @discardableResult
    func requestAutomaticRoute(
        scope: AnyHashable,
        start: @escaping () -> Void
    ) -> AutomaticRouteRequestResult {
        guard activeScope == scope else { return .stale }
        guard !userRouteCommitted, !automaticRouteStarted else { return .suppressed }
        if pendingUserHandoff != nil {
            if deferredRoute == nil { deferredRoute = DeferredRoute(scope: scope, start: start) }
            return .deferred
        }
        automaticRouteStarted = true
        start()
        return .started
    }
}

@MainActor
@discardableResult
func routeCommittedUserHandoff(
    coordinator: AutomaticRouteCoordinator,
    handoff: AutomaticRouteUserHandoff,
    scope: AnyHashable,
    execution: AttributionRouteExecution,
    route: (AttributionRouteExecution) -> Void
) -> Bool {
    guard coordinator.commitUserHandoff(handoff, scope: scope) else {
        execution.cancel()
        return false
    }
    route(execution)
    return true
}

/// Exactly-once automatic-route admission for one ad surface. Automatic store redirects are not
/// clicks: they route once without publisher notification, click telemetry, or a click beacon.
final class AutomaticRouteGuard {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    func reset() {
        claimed = false
    }
}

enum CreativePopupRouteAdmission: Equatable {
    case billable
    case automatic
    case ignored
}

func creativeAutomaticRouteAdmission(
    isPopup: Bool,
    userActivated: Bool,
    sameOriginHTTP: Bool,
    isDirectStoreNavigation: Bool,
    automaticGuard: AutomaticRouteGuard
) -> CreativePopupRouteAdmission {
    if userActivated { return .billable }
    guard isPopup || isDirectStoreNavigation else { return .ignored }
    guard isDirectStoreNavigation || !sameOriginHTTP else { return .ignored }
    guard automaticGuard.claim() else { return .ignored }
    return .automatic
}

/// One-in-flight admission used by store-prompt badges while click persistence and routing run.
/// Once persisted, the interaction stays claimed for a bounded window even if routing fails so a
/// dead store button cannot mint a fresh billable click on every tap.
final class StorePromptGestureGuard {
    static let routedReleaseTimeout: TimeInterval = 2

    private enum State {
        case idle
        case pending
        case routed
    }

    private var state = State.idle
    private var generation = 0
    var isInFlight: Bool { state != .idle }

    func claim() -> Bool {
        guard state == .idle else { return false }
        generation += 1
        state = .pending
        return true
    }

    /// Returns the generation used for a bounded release if no external-return signal arrives.
    func complete() -> Int? {
        guard state == .pending else { return nil }
        state = .routed
        return generation
    }

    func releaseRoutedFallback(generation expectedGeneration: Int) {
        guard state == .routed, generation == expectedGeneration else { return }
        release()
    }

    func releaseAfterExternalReturn() {
        if state == .routed { release() }
    }

    func release() {
        generation += 1
        state = .idle
    }
}

func canDismissFullscreen(dismissUnlocked: Bool, clickHandoffPending: Bool) -> Bool {
    dismissUnlocked && !clickHandoffPending
}

enum FullscreenClickHandoffOwner: Hashable, Sendable {
    case creative
    case storePrompt
}

struct FullscreenClickHandoffState: Equatable, Sendable {
    private var owners: Set<FullscreenClickHandoffOwner> = []

    var isPending: Bool { !owners.isEmpty }

    func isPending(_ owner: FullscreenClickHandoffOwner) -> Bool {
        owners.contains(owner)
    }

    mutating func set(_ owner: FullscreenClickHandoffOwner, pending: Bool) {
        if pending { owners.insert(owner) } else { owners.remove(owner) }
    }

    mutating func reset() {
        owners.removeAll()
    }
}

enum CreativeCTAOpenAdmission: Equatable {
    case notMessage
    case rejected
    case accepted(URL)
}

enum CreativeCTAOpenAuthentication: Equatable {
    case notMessage
    case rejected
    case accepted(URL)
}

enum CreativeCTAOpenMessage {
    static let type = "SIMULA_CTA_OPEN"
    private static let blockedSchemes: Set<String> = ["about", "blob", "data", "file", "javascript"]

    /// Parses only the SDK's structured popup envelope, then applies the current serve's routing
    /// policy. HTTP(S) and App Store schemes work on every surface. Other absolute custom schemes
    /// are admitted only where the existing native router opens them directly (native external or
    /// `.web` destinations); internal/executable schemes always fail closed. URL fragments are never
    /// rewritten, so attribution URLs reach the router byte-for-byte as received from JavaScript.
    static func admission(
        for body: String,
        expectedNonce: String,
        destination: AdDestination,
        externalClickOnly: Bool
    ) -> CreativeCTAOpenAdmission {
        switch authenticate(body, expectedNonce: expectedNonce) {
        case .accepted(let url):
            return isAllowed(url, destination: destination, externalClickOnly: externalClickOnly)
                ? .accepted(url)
                : .rejected
        case .rejected:
            return .rejected
        case .notMessage:
            return .notMessage
        }
    }

    static func authenticate(
        _ body: String,
        expectedNonce: String
    ) -> CreativeCTAOpenAuthentication {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = object["type"] as? String else {
            return .notMessage
        }
        guard messageType == type else { return .notMessage }
        guard !expectedNonce.isEmpty,
              object["activation_nonce"] as? String == expectedNonce,
              let value = object["url"] as? String,
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme?.isEmpty == false else {
            return .rejected
        }
        return .accepted(url)
    }

    static func isAllowed(_ url: URL, destination: AdDestination, externalClickOnly: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty,
              !blockedSchemes.contains(scheme) else { return false }
        if scheme == "http" || scheme == "https" {
            return url.host?.isEmpty == false
        }
        if isDirectAppStoreScheme(scheme) {
            return directAppStoreID(from: url) != nil
        }
        return externalClickOnly || destination == .web
    }
}

func validatedMMPTrackingURL(_ trackingUrl: String?) -> URL? {
    guard let value = trackingUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty else {
        return nil
    }
    return url
}

private let directAppStorePathIDRegex = try? NSRegularExpression(pattern: #"/id(\d+)(?:/|$)"#)

private func isAppleAppStoreHost(_ host: String) -> Bool {
    let host = host.lowercased()
    return host == "apps.apple.com"
        || host.hasSuffix(".apps.apple.com")
        || host == "itunes.apple.com"
        || host.hasSuffix(".itunes.apple.com")
}

func shouldStopRedirectResolution(at url: URL) -> Bool {
    isAppleAppStoreHost(url.host ?? "") || isDirectAppStoreScheme(url.scheme)
}

private func capturedDirectStoreID(_ regex: NSRegularExpression?, in string: String) -> String? {
    guard let regex else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    guard let match = regex.firstMatch(in: string, range: range),
          match.numberOfRanges >= 2,
          let idRange = Range(match.range(at: 1), in: string) else { return nil }
    return String(string[idRange])
}

func directAppStoreID(from url: URL) -> String? {
    let scheme = url.scheme?.lowercased() ?? ""
    if isDirectAppStoreScheme(scheme) {
        let host = url.host?.lowercased() ?? ""
        guard isAppleAppStoreHost(host) else { return nil }
        return capturedDirectStoreID(directAppStorePathIDRegex, in: url.path)
    }
    guard scheme == "http" || scheme == "https" else { return nil }
    let host = url.host?.lowercased() ?? ""
    guard isAppleAppStoreHost(host) else { return nil }
    return capturedDirectStoreID(directAppStorePathIDRegex, in: url.path)
}

func validatedDirectAppStoreURL(_ value: String?) -> URL? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          let url = URL(string: value),
          directAppStoreID(from: url) != nil else { return nil }
    return url
}

func validatedTopLevelAttributionURL(_ value: String?) -> URL? {
    validatedMMPTrackingURL(value) ?? validatedDirectAppStoreURL(value)
}

enum CreativeRoutePlan: Equatable {
    case directStore(url: URL, appID: String, storeOpen: StoreOpen)
    case trackerWithStore(
        tracker: URL,
        storeURL: URL,
        appID: String,
        storeOpen: StoreOpen
    )
    case resolveTracker(url: URL, storeOpen: StoreOpen)
    case web(url: URL, storeOpen: StoreOpen)
    case customScheme(url: URL)
    case invalid
}

func creativeRoutePlan(
    selectedURL: URL,
    destination: AdDestination,
    storeOpen: StoreOpen,
    campaignStoreURL: String?,
    fallbackStoreURL: URL?,
    externalClickOnly: Bool
) -> CreativeRoutePlan {
    guard CreativeCTAOpenMessage.isAllowed(
        selectedURL,
        destination: destination,
        externalClickOnly: externalClickOnly
    ) else { return .invalid }

    if let appID = directAppStoreID(from: selectedURL) {
        return .directStore(url: selectedURL, appID: appID, storeOpen: storeOpen)
    }
    if destination == .appstore,
       let storeURL = validatedDirectAppStoreURL(campaignStoreURL),
       let appID = directAppStoreID(from: storeURL) {
        return .trackerWithStore(
            tracker: selectedURL,
            storeURL: storeURL,
            appID: appID,
            storeOpen: storeOpen
        )
    }
    if let fallbackStoreURL,
       let validatedFallback = validatedDirectAppStoreURL(fallbackStoreURL.absoluteString),
       let appID = directAppStoreID(from: validatedFallback) {
        return .trackerWithStore(
            tracker: selectedURL,
            storeURL: validatedFallback,
            appID: appID,
            storeOpen: storeOpen
        )
    }

    let scheme = selectedURL.scheme?.lowercased() ?? ""
    if scheme != "http" && scheme != "https" {
        return .customScheme(url: selectedURL)
    }
    if destination == .web {
        return .web(url: selectedURL, storeOpen: storeOpen)
    }
    return .resolveTracker(url: selectedURL, storeOpen: storeOpen)
}

func validatedResolverRedirectURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return validatedMMPTrackingURL(url.absoluteString)
        ?? validatedDirectAppStoreURL(url.absoluteString)
}

@MainActor
func terminalResolverRedirectURL(
    _ url: URL?,
    execution: AttributionRouteExecution
) -> URL? {
    guard let url else {
        execution.fail("resolve_failed")
        return nil
    }
    guard let validURL = validatedResolverRedirectURL(url) else {
        execution.fail("invalid_redirect_url")
        return nil
    }
    return validURL
}

/// Prefer a validated top-level tracker, then apply the same destination policy to the creative's
/// tapped fallback URL before admitting a click or external open.
func preferredCreativeClickURL(
    trackingUrl: String?,
    fallback: URL,
    destination: AdDestination = .appstore,
    externalClickOnly: Bool = false
) -> URL? {
    if let tracker = validatedTopLevelAttributionURL(trackingUrl) { return tracker }
    guard CreativeCTAOpenMessage.isAllowed(
        fallback,
        destination: destination,
        externalClickOnly: externalClickOnly
    ) else { return nil }
    return fallback
}

#if os(iOS)
import StoreKit
import SafariServices
import ObjectiveC.runtime

// MARK: - External-sheet lifecycle notifications

extension Notification.Name {
    /// Posted when an in-app store (`SKStoreProductViewController`) or `SFSafariViewController` sheet
    /// is presented over an ad. The app stays foreground-active behind it, so the ad's countdown
    /// timers pause on this and resume on `simulaAdExternalSheetDidDismiss`.
    static let simulaAdExternalSheetWillPresent = Notification.Name("SimulaAdExternalSheetWillPresent")
    /// Posted when that in-app sheet is dismissed and the ad is interactive again.
    static let simulaAdExternalSheetDidDismiss = Notification.Name("SimulaAdExternalSheetDidDismiss")
}

// MARK: - CreativeCTARouter

/// Routes a creative's CTA tap to its advertiser destination.
///
/// This is the single, shared implementation of the store/Safari/redirect-resolve
/// logic that used to live privately inside `WebViewRepresentable.Coordinator`.
/// Both the imperative native creative interstitial (`CreativeInterstitialView`)
/// and the declarative game-iframe CTA (`WebViewRepresentable.Coordinator`) route
/// through here so their open behavior is byte-for-byte identical.
///
/// Routing by `destination`:
/// - `.appstore` → if the `trackingUrl` already encodes an App Store id, show the
///   in-app `SKStoreProductViewController` directly; otherwise follow the
///   click-attribution redirect chain and route the resolved URL to the store
///   sheet (App Store) or Safari (everything else).
/// - `.web` → `SFSafariViewController` for http(s); fall back to
///   `UIApplication.shared.open` for non-http(s) schemes.
///
/// A `nil`/empty `trackingUrl` is a no-op (the caller still fires `CLICKED`).
@MainActor
enum CreativeCTARouter {
    /// Opens the advertiser destination for a creative CTA. Best-effort: a bad id
    /// or unopenable URL silently no-ops (the CLICKED event has already fired).
    ///
    /// `storeOpen` selects the presentation surface (server-driven A/B config):
    /// - `.skstoreproduct` (default; also the iOS mapping of the Android-only
    ///   `.inlineInstall`) → in-app `SKStoreProductViewController` / `SFSafariViewController`.
    /// - `.external` → leave the app: the App Store app for store links, the default
    ///   browser otherwise (resolving the attribution redirect first for store CTAs).
    ///
    /// `storeUrl` is the campaign's raw App Store link (`ios_store_url`). When it carries an app id
    /// and the destination is `.appstore`, the route is **deterministic**: the store surface opens
    /// from that id and the MMP tracker (`trackingUrl`) is fired in the background — no dependency
    /// on the tracker's redirect chain (the same pattern `resolveAppStoreID` uses for SKOverlay).
    /// `nil`/id-less falls back to redirect-chain resolution.
    static func open(
        trackingUrl: String?,
        destination: AdDestination,
        storeOpen: StoreOpen = .skstoreproduct,
        storeUrl: String? = nil,
        attribution: AdAttribution? = nil,
        execution: AttributionRouteExecution,
        trackerSender: @escaping (URL) -> Void = { fireClickTracker($0) }
    ) {
        if let directStoreURL = validatedDirectAppStoreURL(trackingUrl),
           let appID = appStoreID(from: directStoreURL) {
            guard execution.begin(path: .directStore) else { return }
            execution.complete {
                if storeOpen == .external {
                    UIApplication.shared.open(directStoreURL)
                    return true
                }
                return presentStoreProduct(
                    appID: appID,
                    attribution: attribution,
                    originatingScene: execution.originatingScene
                )
            }
            return
        }

        guard let url = validatedMMPTrackingURL(trackingUrl) else {
            // No tracker on the serve — a raw store link still gives the CTA somewhere to go
            // (previously a silent no-op). No tracker means no background click to fire.
            if destination == .appstore, let appID = appStoreID(fromString: storeUrl) {
                guard execution.begin(path: .rawStoreFallback) else { return }
                execution.complete {
                    if storeOpen == .external, let storeURL = validatedDirectAppStoreURL(storeUrl) {
                        UIApplication.shared.open(storeURL)
                        return true
                    }
                    return presentStoreProduct(
                        appID: appID,
                        attribution: attribution,
                        originatingScene: execution.originatingScene
                    )
                }
                return
            }
            guard execution.begin(path: .mmpRedirect) else { return }
            execution.fail("invalid_url")
            return
        }

        if storeOpen == .external {
            // `.external` leaves the app to the App Store / browser, which StoreKit attribution tokens
            // can't ride on — they apply only to the in-app store sheet below.
            openExternally(
                initialURL: url,
                destination: destination,
                storeUrl: storeUrl,
                execution: execution,
                trackerSender: trackerSender
            )
            return
        }

        switch destination {
        case .appstore:
            // If the tracking URL is already an App Store URL, present the sheet directly.
            // Otherwise prefer the deterministic route (store id from the raw `ios_store_url`,
            // tracker fired in the background); only without one resolve the redirect chain.
            if let appID = appStoreID(from: url) {
                guard execution.begin(path: .directStore) else { return }
                execution.complete {
                    presentStoreProduct(
                        appID: appID,
                        attribution: attribution,
                        originatingScene: execution.originatingScene
                    )
                }
            } else if let appID = appStoreID(fromString: storeUrl) {
                execution.deliverDeterministicTracker(url, sender: trackerSender)
                guard execution.begin(path: .rawStoreFallback) else { return }
                execution.complete {
                    return presentStoreProduct(
                        appID: appID,
                        attribution: attribution,
                        originatingScene: execution.originatingScene
                    )
                }
            } else {
                resolveAndRoute(url: url, attribution: attribution, execution: execution)
            }
        case .web:
            guard execution.begin(path: .web) else { return }
            execution.complete {
                presentSafari(url: url, originatingScene: execution.originatingScene)
            }
        }
    }

    /// Routes a user-activated click-through from inside a creative WebView (the game iframe's
    /// `window.open(TRACKING_URL)` / cross-domain CTA), given the serve's routing context.
    ///
    /// `url` is the selected tracker or creative destination. A validated fallback store URL retains
    /// the original scheme/host/path so `.external` can open it verbatim instead of losing everything
    /// except its app id.
    static func routeCreativeTap(
        url: URL,
        destination: AdDestination,
        storeOpen: StoreOpen,
        storeUrl: String?,
        fallbackStoreURL: URL? = nil,
        externalClickOnly: Bool = false,
        attribution: AdAttribution? = nil,
        execution: AttributionRouteExecution,
        trackerSender: @escaping (URL) -> Void = { fireClickTracker($0) }
    ) {
        let plan = creativeRoutePlan(
            selectedURL: url,
            destination: destination,
            storeOpen: storeOpen,
            campaignStoreURL: storeUrl,
            fallbackStoreURL: fallbackStoreURL,
            externalClickOnly: externalClickOnly
        )

        switch plan {
        case .invalid:
            guard execution.begin(path: .mmpRedirect) else { return }
            execution.fail("invalid_url")
        case .directStore(let storeURL, let appID, let mode):
            guard execution.begin(path: .directStore) else { return }
            execution.complete {
                openStoreDestination(
                    storeURL: storeURL,
                    appID: appID,
                    storeOpen: mode,
                    attribution: attribution,
                    originatingScene: execution.originatingScene
                )
            }
        case .trackerWithStore(let tracker, let storeURL, let appID, let mode):
            execution.deliverDeterministicTracker(tracker, sender: trackerSender)
            guard execution.begin(path: .rawStoreFallback) else { return }
            execution.complete {
                return openStoreDestination(
                    storeURL: storeURL,
                    appID: appID,
                    storeOpen: mode,
                    attribution: attribution,
                    originatingScene: execution.originatingScene
                )
            }
        case .resolveTracker(let tracker, let mode):
            if mode == .external {
                openExternally(
                    initialURL: tracker,
                    destination: .appstore,
                    execution: execution,
                    trackerSender: trackerSender
                )
            } else {
                resolveAndRoute(url: tracker, attribution: attribution, execution: execution)
            }
        case .web(let webURL, let mode):
            if mode == .external {
                openExternally(
                    initialURL: webURL,
                    destination: .web,
                    execution: execution
                )
            } else {
                guard execution.begin(path: .web) else { return }
                execution.complete {
                    presentSafari(url: webURL, originatingScene: execution.originatingScene)
                }
            }
        case .customScheme(let customURL):
            guard execution.begin(path: .customScheme) else { return }
            execution.complete {
                UIApplication.shared.open(customURL)
                return true
            }
        }
    }

    private static func openStoreDestination(
        storeURL: URL,
        appID: String,
        storeOpen: StoreOpen,
        attribution: AdAttribution?,
        originatingScene: UIWindowScene?
    ) -> Bool {
        if storeOpen == .external {
            UIApplication.shared.open(storeURL)
            return true
        }
        return presentStoreProduct(
            appID: appID,
            attribution: attribution,
            originatingScene: originatingScene
        )
    }

    /// Fires the MMP click tracker in the background (fire-and-forget GET), used when the store
    /// surface is opened deterministically instead of by navigating the tracker's redirect chain.
    /// Uses the same Safari-style-UA session configuration as `RedirectResolver`, so the click
    /// fingerprints for probabilistic attribution exactly like a resolved click. Redirects are
    /// followed by default; App Store scheme hops are recognized by `RedirectResolver`.
    nonisolated static func fireClickTracker(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return }
        let session = URLSession(configuration: SimulaUserAgent.sessionConfiguration())
        let task = session.dataTask(with: URLRequest(url: url)) { _, _, _ in
            session.finishTasksAndInvalidate()
        }
        task.resume()
    }

    // MARK: - App Store id extraction

    /// Extracts App Store ID from URLs like:
    /// - https://apps.apple.com/app/id123456789
    /// - https://itunes.apple.com/app/id123456789
    /// - itms-apps://apps.apple.com/app/id123456789
    /// - itms-apps://itunes.apple.com/app/id123456789
    // Precompiled once — `range(of:options:.regularExpression)` would compile
    // the pattern on every navigation. Group 1 captures the numeric ID.
    // `try?` (not `try!`) so a malformed pattern could never trap — the patterns are constant string
    // literals so this is always non-nil in practice, but it removes the only trap-on-error construct.
    /// String-flavored variant of `appStoreID(from:)` for optional raw links (e.g. the serve's
    /// `ios_store_url`). `nil`/empty/unparseable → nil.
    nonisolated static func appStoreID(fromString urlString: String?) -> String? {
        guard let url = validatedDirectAppStoreURL(urlString) else { return nil }
        return appStoreID(from: url)
    }

    /// Pure regex extraction — `nonisolated` so the WKWebView navigation-policy
    /// decision (and any non-main context) can call it directly without a
    /// `MainActor.assumeIsolated` trap.
    nonisolated static func appStoreID(from url: URL) -> String? {
        directAppStoreID(from: url)
    }

    // MARK: - App Store id resolution (for SKOverlay)

    /// Resolves the advertised app's numeric App Store id (adamId) for `SKOverlay.AppConfiguration`.
    /// Resolution order mirrors the CTA paths (`open` / `routeCreativeTap`) exactly, so every store
    /// surface of one serve always lands on the SAME app id: (1) a tracking URL that is itself an
    /// App Store link wins; (2) the serve's raw store link (`storeUrl`) supplies it directly.
    /// A tracker redirect is intentionally not followed here because that request is click-classified;
    /// when it is the only source, resolution returns nil and the overlay safely no-ops. The
    /// completion is always delivered on the calling main thread.
    static func resolveAppStoreID(
        trackingUrl: String?,
        destination: AdDestination,
        storeUrl: String? = nil,
        completion: @escaping (String?) -> Void
    ) {
        // (1) The tracker is already a store URL — its id wins (no network, no click to fire),
        // matching `open`'s precedence so the SKOverlay never advertises a different app than the
        // CTA / store-prompt taps.
        if let url = validatedDirectAppStoreURL(trackingUrl),
           let appID = appStoreID(from: url) {
            completion(appID)
            return
        }
        // (2) Deterministic path: the raw store link carries the id — no redirect resolution
        // needed. Resolution is deliberately side-effect free: merely displaying an overlay is
        // not a click. Gated on an `.appstore`
        // destination — a web campaign that happens to carry an ios_store_url must not surface
        // SKOverlay (the resolver fallback below returns nil for `.web`, and this branch must agree).
        if destination == .appstore, let appID = appStoreID(fromString: storeUrl) {
            completion(appID)
            return
        }
        // A tracker redirect can only be resolved by issuing its click-classified request. Skip the
        // overlay instead of manufacturing engagement before the user taps it.
        completion(nil)
    }

    /// Starts a side-effect-free StoreKit product load for a displayed fullscreen serve. Resolution is
    /// intentionally limited to URLs that already contain an App Store id; an MMP tracker is never
    /// requested until a committed user click.
    static func prewarmStoreProduct(
        trackingUrl: String?,
        destination: AdDestination,
        storeOpen: StoreOpen,
        storeUrl: String?,
        attribution: AdAttribution?
    ) {
        guard storeOpen != .external else { return }
        resolveAppStoreID(
            trackingUrl: trackingUrl,
            destination: destination,
            storeUrl: storeUrl
        ) { appID in
            guard let appID else { return }
            StoreProductPrewarmer.shared.prewarm(appID: appID, attribution: attribution)
        }
    }

    // MARK: - Presentation

    /// Associated-object keys under which a presented store / Safari sheet retains
    /// its own delegate, so each in-flight sheet owns its delegate (no single global
    /// slot that a second present would clobber).
    private static var storeDelegateAssocKey: UInt8 = 0
    private static var safariDelegateAssocKey: UInt8 = 0

    /// Guards against stacking a second in-app sheet (store OR Safari) on top of one
    /// already showing — only one external surface should be up at a time. Set `true`
    /// only after a confirmed present (and never set on a failed present), so a
    /// no-window early-return can't wedge all future CTAs shut. Each sheet's delegate
    /// resets it on dismiss.
    private static var isPresentingExternal = false
    private static var presentationRootOverrideForTesting: (() -> UIViewController?)?

    /// Test cleanup for SDK-owned presentation state. Tests dismiss the presented controller first;
    /// this only prevents a failed test from contaminating later route assertions.
    static func resetExternalPresentationStateForTesting() {
        isPresentingExternal = false
        presentationRootOverrideForTesting = nil
    }

    static func setPresentationRootForTesting(_ provider: @escaping () -> UIViewController?) {
        presentationRootOverrideForTesting = provider
    }

    /// Presents `SKStoreProductViewController` in-app for the given App Store ID, carrying any
    /// campaign/provider/SKAN [attribution] tokens so the install it drives is credited to the campaign.
    @discardableResult
    static func presentStoreProduct(
        appID: String,
        attribution: AdAttribution? = nil,
        originatingScene: UIWindowScene? = nil
    ) -> Bool {
        guard !isPresentingExternal else { return false }
        let prepared = StoreProductPrewarmer.shared.take(appID: appID, attribution: attribution)
        let storeVC = prepared ?? SKStoreProductViewController()
        let delegate = StoreProductDelegate {
            isPresentingExternal = false
            NotificationCenter.default.post(name: .simulaAdExternalSheetDidDismiss, object: nil)
        }
        storeVC.delegate = delegate
        // Also observe the sheet's interactive swipe-down, which does not reliably fire
        // `productViewControllerDidFinish` (long-standing iOS bug) — without this the pause
        // flag and `isPresentingExternal` would stick forever after a swiped-away sheet.
        storeVC.presentationController?.delegate = delegate
        // Retain the delegate on the presented VC itself (per-sheet), not a single
        // global slot — multiple sheets can be presented/dismissed independently.
        // NOTE for host/dependency auditors: this is a scoped associated object on an SDK-owned VC —
        // NOT method swizzling and NOT host global-state mutation; its lifetime ends with the sheet.
        objc_setAssociatedObject(
            storeVC, &storeDelegateAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        if prepared == nil {
            let start = DispatchTime.now().uptimeNanoseconds
            storeVC.loadProduct(
                withParameters: storeProductParameters(appID: appID, attribution: attribution)
            ) { loaded, _ in
                let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                Telemetry.shared.recordOperation(
                    name: "store_product_load",
                    durationMs: Int(elapsed / 1_000_000),
                    success: loaded,
                    failureClass: loaded ? nil : "load_failed"
                )
            }
        }
        // Only mark "showing" once the present actually succeeds; otherwise the
        // guard would stick true forever on a no-window early-return.
        if presentViewController(storeVC, originatingScene: originatingScene) {
            isPresentingExternal = true
            NotificationCenter.default.post(name: .simulaAdExternalSheetWillPresent, object: nil)
            return true
        }
        return false
    }

    // MARK: - Attribution token mapping

    /// The full `loadProduct` parameter set: the App Store item id plus any campaign/provider/SKAN
    /// attribution tokens the backend supplied. Used by `presentStoreProduct`; the SKAN subset is
    /// shared with `SKOverlayPresenter` (same `SKStoreProductParameterAdNetwork*` keys).
    static func storeProductParameters(appID: String, attribution: AdAttribution?) -> [String: Any] {
        var params: [String: Any] = [
            SKStoreProductParameterITunesItemIdentifier: NSNumber(value: Int(appID) ?? 0)
        ]
        if let campaign = attribution?.campaignToken, !campaign.isEmpty {
            params[SKStoreProductParameterCampaignToken] = campaign
        }
        if let provider = attribution?.providerToken, !provider.isEmpty {
            params[SKStoreProductParameterProviderToken] = provider
        }
        params.merge(skanAdditionalValues(attribution)) { _, new in new }
        return params
    }

    /// Maps a signed `SKANParameters` payload to StoreKit's `SKStoreProductParameterAdNetwork*` keys —
    /// the same keys `SKStoreProductViewController.loadProduct` and `SKOverlay.AppConfiguration`'s
    /// `setAdditionalValue(_:forKey:)` both consume. StoreKit uses them to generate the SKAdNetwork
    /// install postback that credits the campaign without IDFA. Returns `[:]` when there's no SKAN
    /// payload or the nonce isn't a valid UUID (StoreKit would reject a malformed set anyway).
    static func skanAdditionalValues(
        _ attribution: AdAttribution?,
        surface: SKANAttributionSurface = .storeProduct,
        recordRejection: Bool = true
    ) -> [String: Any] {
        guard let skan = attribution?.skan else { return [:] }
        if let reason = skanPayloadRejectionReason(skan, signature: skan.attributionSignature) {
            if recordRejection { recordDroppedSKAN(reason, surface: surface) }
            return [:]
        }
        guard let nonce = UUID(uuidString: skan.nonce) else {
            recordDroppedSKAN(.invalidNonce, surface: surface)
            return [:]
        }
        guard let identifier = validatedSKANIdentifier(
            version: skan.version,
            campaignIdentifier: skan.campaignIdentifier,
            sourceIdentifier: skan.sourceIdentifier
        ) else {
            if recordRejection { recordDroppedSKAN(.unsupportedVersion, surface: surface) }
            return [:]
        }
        var values: [String: Any] = [
            SKStoreProductParameterAdNetworkIdentifier: skan.adNetworkIdentifier,
            SKStoreProductParameterAdNetworkVersion: skan.version,
            SKStoreProductParameterAdNetworkNonce: nonce,
            SKStoreProductParameterAdNetworkTimestamp: NSNumber(value: skan.timestamp),
            SKStoreProductParameterAdNetworkSourceAppStoreIdentifier: NSNumber(value: skan.sourceAppStoreIdentifier),
            SKStoreProductParameterAdNetworkAttributionSignature: skan.attributionSignature,
        ]
        switch identifier {
        case .campaign(let campaignID):
            values[SKStoreProductParameterAdNetworkCampaignIdentifier] = NSNumber(value: campaignID)
        case .source(let sourceID):
            guard #available(iOS 16.1, *) else {
                if recordRejection { recordDroppedSKAN(.unsupportedOS, surface: surface) }
                return [:]
            }
            values[SKStoreProductParameterAdNetworkSourceIdentifier] = NSNumber(value: sourceID)
        }
        return values
    }

    static func recordDroppedSKAN(
        _ reason: SKANRejectionReason,
        surface: SKANAttributionSurface
    ) {
        Telemetry.shared.recordOperation(
            name: "skan_payload_dropped",
            durationMs: 0,
            success: false,
            failureClass: reason.rawValue,
            breadcrumb: "surface=\(surface.rawValue)"
        )
    }

    /// Presents `SFSafariViewController` for external links.
    @discardableResult
    static func presentSafari(url: URL, originatingScene: UIWindowScene? = nil) -> Bool {
        guard !isPresentingExternal else { return false }
        let safariVC = SFSafariViewController(url: url)
        let delegate = SafariDelegate {
            isPresentingExternal = false
            NotificationCenter.default.post(name: .simulaAdExternalSheetDidDismiss, object: nil)
        }
        safariVC.delegate = delegate
        // Catch the interactive swipe-down too — see the note in `presentStoreProduct`.
        safariVC.presentationController?.delegate = delegate
        // Retain the delegate on the presented VC itself (per-sheet).
        objc_setAssociatedObject(
            safariVC, &safariDelegateAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        // Only mark "presenting" once the present actually succeeds.
        if presentViewController(safariVC, originatingScene: originatingScene) {
            isPresentingExternal = true
            NotificationCenter.default.post(name: .simulaAdExternalSheetWillPresent, object: nil)
            return true
        }
        return false
    }

    /// Presents `vc` on top of the active window. Returns `true` if a host
    /// view-controller was found and `present` was invoked, `false` otherwise.
    @discardableResult
    static func presentViewController(
        _ vc: UIViewController,
        originatingScene: UIWindowScene? = nil
    ) -> Bool {
        let rootVC: UIViewController?
        if let override = presentationRootOverrideForTesting {
            rootVC = override()
        } else if let originatingScene {
            guard originatingScene.activationState == .foregroundActive else { return false }
            rootVC = (originatingScene.windows.first(where: \.isKeyWindow)
                      ?? originatingScene.windows.first)?.rootViewController
        } else if let scene = preferredForegroundActiveWindowScene() {
            rootVC = (scene.windows.first(where: \.isKeyWindow)
                      ?? scene.windows.first)?.rootViewController
        } else {
            rootVC = nil
        }
        guard let rootVC else { return false }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(vc, animated: true)
        return true
    }

    /// In-flight redirect resolvers. A Set (rather than a single static slot) lets
    /// multiple CTAs resolve concurrently without dropping/leaking each other; each
    /// removes itself on completion.
    private static var activeResolvers: Set<RedirectResolver> = []

    /// Opens the destination externally (leaving the app) for `store_open == .external`.
    /// Direct App Store / non-http links and web destinations open immediately; an
    /// http(s) attribution tracker for a store CTA is opened deterministically when the serve
    /// carries a raw store link (`storeUrl` — tracker fired in the background, store opened
    /// directly), else resolved through its redirect chain so we land on the real App Store
    /// page rather than bouncing through the tracker.
    static func openExternally(
        initialURL: URL,
        destination: AdDestination,
        storeUrl: String? = nil,
        execution: AttributionRouteExecution,
        trackerSender: @escaping (URL) -> Void = { fireClickTracker($0) }
    ) {
        guard CreativeCTAOpenMessage.isAllowed(
            initialURL,
            destination: destination,
            externalClickOnly: true
        ) else {
            guard execution.begin(path: .mmpRedirect) else { return }
            execution.fail("invalid_url")
            return
        }
        let scheme = initialURL.scheme?.lowercased() ?? ""
        let isHTTP = scheme == "http" || scheme == "https"

        // Already a store / custom-scheme link, or a plain web destination — open as-is.
        if appStoreID(from: initialURL) != nil || !isHTTP || destination == .web {
            let path: AttributionRoutePath = appStoreID(from: initialURL) != nil
                ? .directStore
                : (destination == .web ? .web : .customScheme)
            guard execution.begin(path: path) else { return }
            execution.complete {
                UIApplication.shared.open(initialURL)
                return true
            }
            return
        }

        // Deterministic external store open: fire the tracker in the background and jump straight
        // to the App Store from the raw store link — no redirect-chain dependency.
        if let storeURL = validatedDirectAppStoreURL(storeUrl) {
            execution.deliverDeterministicTracker(initialURL, sender: trackerSender)
            guard execution.begin(path: .rawStoreFallback) else { return }
            execution.complete {
                UIApplication.shared.open(storeURL)
                return true
            }
            return
        }

        // appstore destination behind an http(s) tracker: resolve, then open the final URL.
        startAsynchronousAttributionRoute(execution: execution) {
            weak var resolverRef: RedirectResolver?
            let resolver = RedirectResolver { finalURL in
                DispatchQueue.main.async {
                    defer {
                        if let r = resolverRef { activeResolvers.remove(r) }
                    }
                    guard let finalURL = terminalResolverRedirectURL(
                        finalURL,
                        execution: execution
                    ) else { return }
                    execution.complete {
                        UIApplication.shared.open(finalURL)
                        return true
                    }
                }
            }
            resolverRef = resolver
            activeResolvers.insert(resolver)
            let session = URLSession(configuration: SimulaUserAgent.sessionConfiguration(), delegate: resolver, delegateQueue: nil)
            resolver.session = session
            session.dataTask(with: URLRequest(url: initialURL)).resume()
        }
    }

    /// Follows the HTTP redirect chain to determine the final destination.
    /// If it resolves to an App Store URL → `SKStoreProductViewController`.
    /// Otherwise → `SFSafariViewController` with the final URL.
    static func resolveAndRoute(
        url: URL,
        attribution: AdAttribution? = nil,
        execution: AttributionRouteExecution
    ) {
        // Quick check — already an App Store URL?
        if let appID = appStoreID(from: url) {
            guard execution.begin(path: .directStore) else { return }
            execution.complete {
                presentStoreProduct(
                    appID: appID,
                    attribution: attribution,
                    originatingScene: execution.originatingScene
                )
            }
            return
        }

        startAsynchronousAttributionRoute(execution: execution) {
            // `weak` so the completion closure (stored on `resolver.completion`) doesn't
            // strongly capture the resolver — that would be a retain cycle
            // (resolver → completion → resolver) that outlives removal from
            // `activeResolvers` and leaks one resolver per resolve. The Set + the
            // delegate-retaining URLSession keep it alive through the request, so the
            // weak ref is still valid when the completion fires.
            weak var resolverRef: RedirectResolver?
            let resolver = RedirectResolver { finalURL in
                DispatchQueue.main.async {
                    defer {
                        if let r = resolverRef { activeResolvers.remove(r) }
                    }
                    guard let finalURL = terminalResolverRedirectURL(
                        finalURL,
                        execution: execution
                    ) else { return }
                    execution.complete {
                        if let appID = appStoreID(from: finalURL) {
                            return presentStoreProduct(
                                appID: appID,
                                attribution: attribution,
                                originatingScene: execution.originatingScene
                            )
                        } else {
                            return presentSafari(
                                url: finalURL,
                                originatingScene: execution.originatingScene
                            )
                        }
                    }
                }
            }
            resolverRef = resolver
            // Keep a strong reference so it isn't deallocated during the request.
            activeResolvers.insert(resolver)
            let session = URLSession(configuration: SimulaUserAgent.sessionConfiguration(), delegate: resolver, delegateQueue: nil)
            resolver.session = session
            session.dataTask(with: URLRequest(url: url)).resume()
        }
    }
}

// MARK: - StoreProductDelegate

/// Minimal `SKStoreProductViewControllerDelegate` that dismisses the store sheet
/// and clears the "showing" guard when the user finishes. `nonisolated` so it can
/// satisfy the (nonisolated) delegate requirement; StoreKit always calls this on
/// the main thread, so the hop in the body is effectively a no-op.
/// Also the sheet's `UIAdaptivePresentationControllerDelegate`: an interactive swipe-down
/// does not reliably fire `productViewControllerDidFinish`, and on some iOS versions both
/// callbacks fire for a single dismissal — so both funnel into `finishOnce()`, which runs
/// the cleanup exactly once per presentation.
private final class StoreProductDelegate: NSObject, SKStoreProductViewControllerDelegate,
                                          UIAdaptivePresentationControllerDelegate {
    private let onFinish: @MainActor () -> Void
    /// Main-thread only (both StoreKit and UIKit deliver these callbacks there).
    private var finished = false

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true)
        finishOnce()
    }

    /// The user swiped the sheet down (interactive dismissal).
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishOnce()
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        let onFinish = self.onFinish
        Task { @MainActor in onFinish() }
    }
}

// MARK: - SafariDelegate

/// Clears the "presenting" guard when the user dismisses the Safari sheet. Retained
/// per-sheet via an associated object (like `StoreProductDelegate`). `SFSafariViewController`
/// dismisses itself, so this only resets the guard. Delivered on the main thread.
/// Also the sheet's `UIAdaptivePresentationControllerDelegate` so an interactive swipe-down
/// (which can skip `safariViewControllerDidFinish`) still resets the guard; both callbacks
/// funnel into `finishOnce()` so a double-fire cleans up exactly once.
private final class SafariDelegate: NSObject, SFSafariViewControllerDelegate,
                                    UIAdaptivePresentationControllerDelegate {
    private let onFinish: @MainActor () -> Void
    /// Main-thread only (both SafariServices and UIKit deliver these callbacks there).
    private var finished = false

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        finishOnce()
    }

    /// The user swiped the sheet down (interactive dismissal).
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishOnce()
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        let onFinish = self.onFinish
        Task { @MainActor in onFinish() }
    }
}

// MARK: - RedirectResolver

/// URLSession delegate that follows HTTP redirect chains and stops when it
/// encounters an App Store URL or non-HTTP scheme. Used to pre-resolve
/// AppsFlyer/onelink redirects before deciding whether to show
/// `SKStoreProductViewController` or `SFSafariViewController`.
final class RedirectResolver: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    // Identity-based `Hashable`/`Equatable` (inherited from `NSObject`) so instances
    // can live in the router's `Set<RedirectResolver>` of in-flight resolvers.
    let completion: (URL?) -> Void
    /// The session driving this resolution. Held so it can be invalidated on
    /// completion: a delegate-based URLSession otherwise retains its delegate
    /// (and an operation-queue thread) indefinitely until `invalidate` is called.
    var session: URLSession?
    private var completed = false

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url else {
            // request.url is nil here; never force-unwrap it.
            finish(with: task.currentRequest?.url)
            completionHandler(nil)
            return
        }

        // Stop at App Store hosts or canonical direct App Store schemes.
        if shouldStopRedirectResolution(at: redirectURL) {
            finish(with: redirectURL)
            completionHandler(nil)
            return
        }

        // Continue following redirect chain
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Terminal callback on every path (success or error). Always finish so
        // the session is invalidated even when there's no final URL to route to.
        finish(with: task.currentRequest?.url)
    }

    /// Terminates the resolution. Always invalidates the session — so its
    /// delegate (self) and backing thread are released on every path — and
    /// routes to `url` only when one is available.
    private func finish(with url: URL?) {
        guard !completed else { return }
        completed = true
        session?.finishTasksAndInvalidate()
        completion(url)
    }
}

#endif
