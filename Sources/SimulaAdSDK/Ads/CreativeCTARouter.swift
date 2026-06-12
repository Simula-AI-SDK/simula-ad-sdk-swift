#if os(iOS)
import UIKit
import StoreKit
import SafariServices
import ObjectiveC.runtime

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
    static func open(
        trackingUrl: String?,
        destination: AdDestination,
        storeOpen: StoreOpen = .skstoreproduct,
        attribution: AdAttribution? = nil
    ) {
        guard let trackingUrl, !trackingUrl.isEmpty, let url = URL(string: trackingUrl) else {
            return
        }

        if storeOpen == .external {
            // `.external` leaves the app to the App Store / browser, which StoreKit attribution tokens
            // can't ride on — they apply only to the in-app store sheet below.
            openExternally(initialURL: url, destination: destination)
            return
        }

        switch destination {
        case .appstore:
            // If the tracking URL is already an App Store URL, present the sheet
            // directly; otherwise resolve the attribution redirect chain first.
            if let appID = appStoreID(from: url) {
                presentStoreProduct(appID: appID, attribution: attribution)
            } else {
                resolveAndRoute(url: url, attribution: attribution)
            }
        case .web:
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                presentSafari(url: url)
            } else {
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - App Store id extraction

    /// Extracts App Store ID from URLs like:
    /// - https://apps.apple.com/app/id123456789
    /// - https://itunes.apple.com/app/id123456789
    /// - itms-apps://apps.apple.com/app/id123456789
    /// - itms-apps://itunes.apple.com/app/id123456789
    // Precompiled once — `range(of:options:.regularExpression)` would compile
    // the pattern on every navigation. Group 1 captures the numeric ID.
    nonisolated private static let appStoreIDRegex = try! NSRegularExpression(pattern: #"id(\d+)"#)
    nonisolated private static let appStorePathIDRegex = try! NSRegularExpression(pattern: #"/id(\d+)"#)

    nonisolated private static func capturedID(_ regex: NSRegularExpression, in string: String) -> String? {
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              match.numberOfRanges >= 2,
              let idRange = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return String(string[idRange])
    }

    /// Pure regex extraction — `nonisolated` so the WKWebView navigation-policy
    /// decision (and any non-main context) can call it directly without a
    /// `MainActor.assumeIsolated` trap.
    nonisolated static func appStoreID(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""

        // For itms-apps:// and itms:// schemes, search the path for /id\d+
        // regardless of host (these are always App Store URLs)
        if scheme == "itms-apps" || scheme == "itms" {
            return capturedID(appStoreIDRegex, in: url.absoluteString)
        }

        // For http/https, require known App Store hosts
        guard host.contains("apps.apple.com") || host.contains("itunes.apple.com") else {
            return nil
        }
        return capturedID(appStorePathIDRegex, in: url.path)
    }

    // MARK: - App Store id resolution (for SKOverlay)

    /// Resolves the advertised app's numeric App Store id (adamId) for `SKOverlay.AppConfiguration`.
    /// Tries the tracking URL directly; if it's an http(s) attribution tracker for a store CTA,
    /// follows the redirect chain (the same `RedirectResolver` the CTA uses) to the final App Store
    /// URL. Calls back with `nil` when none can be resolved (the overlay then safely no-ops).
    /// The completion is always delivered on the main thread.
    static func resolveAppStoreID(
        trackingUrl: String?,
        destination: AdDestination,
        completion: @escaping (String?) -> Void
    ) {
        guard let trackingUrl, !trackingUrl.isEmpty, let url = URL(string: trackingUrl) else {
            completion(nil)
            return
        }
        // Already a store URL — no network needed.
        if let appID = appStoreID(from: url) {
            completion(appID)
            return
        }
        // Only http(s) trackers for an appstore destination are worth resolving.
        let scheme = url.scheme?.lowercased() ?? ""
        guard destination == .appstore, scheme == "http" || scheme == "https" else {
            completion(nil)
            return
        }

        weak var resolverRef: RedirectResolver?
        let resolver = RedirectResolver { finalURL in
            DispatchQueue.main.async {
                completion(appStoreID(from: finalURL))
                if let r = resolverRef { activeResolvers.remove(r) }
            }
        }
        resolverRef = resolver
        activeResolvers.insert(resolver)
        let session = URLSession(configuration: SimulaUserAgent.sessionConfiguration(), delegate: resolver, delegateQueue: nil)
        resolver.session = session
        // This GET both resolves the advertised app id AND is the MMP click for the SKOverlay
        // engagement — `is_skoverlay=true` tells AppsFlyer/Adjust it's an SKOverlay view/click (so it's
        // matched to the StoreKit/SKAN install). Folding it into this one request avoids firing the
        // tracker twice (and double-counting the click). `resolveAppStoreID` is only ever called for
        // the SKOverlay flow, so flagging every request here is correct.
        let clickURL = appendingQueryItem(url, name: "is_skoverlay", value: "true")
        session.dataTask(with: URLRequest(url: clickURL)).resume()
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

    /// Presents `SKStoreProductViewController` in-app for the given App Store ID, carrying any
    /// campaign/provider/SKAN [attribution] tokens so the install it drives is credited to the campaign.
    static func presentStoreProduct(appID: String, attribution: AdAttribution? = nil) {
        guard !isPresentingExternal else { return }
        let storeVC = SKStoreProductViewController()
        let delegate = StoreProductDelegate {
            isPresentingExternal = false
        }
        storeVC.delegate = delegate
        // Retain the delegate on the presented VC itself (per-sheet), not a single
        // global slot — multiple sheets can be presented/dismissed independently.
        objc_setAssociatedObject(
            storeVC, &storeDelegateAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        storeVC.loadProduct(withParameters: storeProductParameters(appID: appID, attribution: attribution))
        // Only mark "showing" once the present actually succeeds; otherwise the
        // guard would stick true forever on a no-window early-return.
        if presentViewController(storeVC) {
            isPresentingExternal = true
        }
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
    static func skanAdditionalValues(_ attribution: AdAttribution?) -> [String: Any] {
        guard let skan = attribution?.skan, let nonce = UUID(uuidString: skan.nonce) else { return [:] }
        var values: [String: Any] = [
            SKStoreProductParameterAdNetworkIdentifier: skan.adNetworkIdentifier,
            SKStoreProductParameterAdNetworkVersion: skan.version,
            SKStoreProductParameterAdNetworkNonce: nonce,
            SKStoreProductParameterAdNetworkTimestamp: NSNumber(value: skan.timestamp),
            SKStoreProductParameterAdNetworkSourceAppStoreIdentifier: NSNumber(value: skan.sourceAppStoreIdentifier),
            SKStoreProductParameterAdNetworkAttributionSignature: skan.attributionSignature,
        ]
        // SKAN 4 keys the install by a numeric source identifier (iOS 16.1+); earlier versions use the
        // campaign identifier. Supply whichever the backend signed for this `version`.
        if #available(iOS 16.1, *), let sourceID = skan.sourceIdentifier {
            values[SKStoreProductParameterAdNetworkSourceIdentifier] = NSNumber(value: sourceID)
        } else if let campaignID = skan.campaignIdentifier {
            values[SKStoreProductParameterAdNetworkCampaignIdentifier] = NSNumber(value: campaignID)
        }
        return values
    }

    /// Appends a query item to `url` (no-op if the name is already present), used to fold
    /// `is_skoverlay=true` into the SKOverlay click without disturbing the rest of the tracker URL.
    nonisolated static func appendingQueryItem(_ url: URL, name: String, value: String) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        guard !items.contains(where: { $0.name == name }) else { return url }
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? url
    }

    /// Presents `SFSafariViewController` for external links.
    static func presentSafari(url: URL) {
        guard !isPresentingExternal else { return }
        let safariVC = SFSafariViewController(url: url)
        let delegate = SafariDelegate {
            isPresentingExternal = false
        }
        safariVC.delegate = delegate
        // Retain the delegate on the presented VC itself (per-sheet).
        objc_setAssociatedObject(
            safariVC, &safariDelegateAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        // Only mark "presenting" once the present actually succeeds.
        if presentViewController(safariVC) {
            isPresentingExternal = true
        }
    }

    /// Presents `vc` on top of the active window. Returns `true` if a host
    /// view-controller was found and `present` was invoked, `false` otherwise.
    @discardableResult
    static func presentViewController(_ vc: UIViewController) -> Bool {
        guard let scene = activeWindowScene(),
              let rootVC = (scene.windows.first(where: \.isKeyWindow)
                            ?? scene.windows.first)?.rootViewController else { return false }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(vc, animated: true)
        return true
    }

    /// Picks a window scene the same way `InterstitialPresenter` does — preferring a
    /// foreground-active scene — so both present on the same surface (matters on
    /// multi-window iPad).
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// In-flight redirect resolvers. A Set (rather than a single static slot) lets
    /// multiple CTAs resolve concurrently without dropping/leaking each other; each
    /// removes itself on completion.
    private static var activeResolvers: Set<RedirectResolver> = []

    /// Opens the destination externally (leaving the app) for `store_open == .external`.
    /// Direct App Store / non-http links and web destinations open immediately; an
    /// http(s) attribution tracker for a store CTA is resolved through its redirect chain
    /// first so we land on the real App Store page rather than bouncing through the tracker.
    static func openExternally(initialURL: URL, destination: AdDestination) {
        let scheme = initialURL.scheme?.lowercased() ?? ""
        let isHTTP = scheme == "http" || scheme == "https"

        // Already a store / custom-scheme link, or a plain web destination — open as-is.
        if appStoreID(from: initialURL) != nil || !isHTTP || destination == .web {
            UIApplication.shared.open(initialURL)
            return
        }

        // appstore destination behind an http(s) tracker: resolve, then open the final URL.
        weak var resolverRef: RedirectResolver?
        let resolver = RedirectResolver { finalURL in
            DispatchQueue.main.async {
                UIApplication.shared.open(finalURL)
                if let r = resolverRef { activeResolvers.remove(r) }
            }
        }
        resolverRef = resolver
        activeResolvers.insert(resolver)
        let session = URLSession(configuration: SimulaUserAgent.sessionConfiguration(), delegate: resolver, delegateQueue: nil)
        resolver.session = session
        session.dataTask(with: URLRequest(url: initialURL)).resume()
    }

    /// Follows the HTTP redirect chain to determine the final destination.
    /// If it resolves to an App Store URL → `SKStoreProductViewController`.
    /// Otherwise → `SFSafariViewController` with the final URL.
    static func resolveAndRoute(url: URL, attribution: AdAttribution? = nil) {
        // Quick check — already an App Store URL?
        if let appID = appStoreID(from: url) {
            presentStoreProduct(appID: appID, attribution: attribution)
            return
        }

        // `weak` so the completion closure (stored on `resolver.completion`) doesn't
        // strongly capture the resolver — that would be a retain cycle
        // (resolver → completion → resolver) that outlives removal from
        // `activeResolvers` and leaks one resolver per resolve. The Set + the
        // delegate-retaining URLSession keep it alive through the request, so the
        // weak ref is still valid when the completion fires.
        weak var resolverRef: RedirectResolver?
        let resolver = RedirectResolver { finalURL in
            DispatchQueue.main.async {
                if let appID = appStoreID(from: finalURL) {
                    presentStoreProduct(appID: appID, attribution: attribution)
                } else {
                    presentSafari(url: finalURL)
                }
                // Release this resolver (and its now-invalidated session).
                if let r = resolverRef { activeResolvers.remove(r) }
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

// MARK: - StoreProductDelegate

/// Minimal `SKStoreProductViewControllerDelegate` that dismisses the store sheet
/// and clears the "showing" guard when the user finishes. `nonisolated` so it can
/// satisfy the (nonisolated) delegate requirement; StoreKit always calls this on
/// the main thread, so the hop in the body is effectively a no-op.
private final class StoreProductDelegate: NSObject, SKStoreProductViewControllerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true)
        let onFinish = self.onFinish
        Task { @MainActor in onFinish() }
    }
}

// MARK: - SafariDelegate

/// Clears the "presenting" guard when the user dismisses the Safari sheet. Retained
/// per-sheet via an associated object (like `StoreProductDelegate`). `SFSafariViewController`
/// dismisses itself, so this only resets the guard. Delivered on the main thread.
private final class SafariDelegate: NSObject, SFSafariViewControllerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
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
    let completion: (URL) -> Void
    /// The session driving this resolution. Held so it can be invalidated on
    /// completion: a delegate-based URLSession otherwise retains its delegate
    /// (and an operation-queue thread) indefinitely until `invalidate` is called.
    var session: URLSession?
    private var completed = false

    init(completion: @escaping (URL) -> Void) {
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

        let scheme = redirectURL.scheme?.lowercased() ?? ""
        let host = redirectURL.host?.lowercased() ?? ""

        // Stop at App Store URLs or non-HTTP schemes
        if host.contains("apps.apple.com") || host.contains("itunes.apple.com")
            || scheme == "itms-apps" || scheme == "itms" {
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
        if let url { completion(url) }
    }
}

#endif
