//
//  OMAdSession.swift
//  SimulaAdSDK
//
//  Wraps a single OMID ad session with idempotent, fully-guarded lifecycle calls.
//  iOS-only (OMID is iOS-only and uses UIKit); construct via the static factories.
//

#if os(iOS) && canImport(OMSDK_Simulaad)
import Foundation
import UIKit
import WebKit
import OMSDK_Simulaad

@MainActor
final class OMAdSession {

    private let session: OMIDSimulaadAdSession
    private let events: OMIDSimulaadAdEvents
    /// The web view OMID measured; held weakly and flushed ~1s after `finish()`.
    private weak var measuredWebView: WKWebView?

    private var loadedFired = false
    private var impressionFired = false
    private var finished = false

    private init(session: OMIDSimulaadAdSession, events: OMIDSimulaadAdEvents, webView: WKWebView?) {
        self.session = session
        self.events = events
        self.measuredWebView = webView
    }

    /// HTML ad session for a server-rendered creative (OM JS already spliced into the
    /// HTML via `OpenMeasurement.injectOMID`). The creative does not emit OMID events,
    /// so impression ownership is NATIVE and we fire loaded/impression ourselves at
    /// first paint. Nil when OM is inactive or session creation throws.
    static func startHTMLSession(webView: WKWebView, impressionId: String?) -> OMAdSession? {
        guard OpenMeasurement.isActive, let partner = OpenMeasurement.cachedPartner else { return nil }
        do {
            let config = try OMIDSimulaadAdSessionConfiguration(
                creativeType: .htmlDisplay,
                impressionType: .beginToRender,
                impressionOwner: .nativeOwner,
                mediaEventsOwner: .noneOwner,
                isolateVerificationScripts: false
            )
            let context = try OMIDSimulaadAdSessionContext(
                partner: partner,
                webView: webView,
                contentUrl: nil,
                customReferenceIdentifier: impressionId
            )
            return try begin(config: config, context: context, mainView: webView, measuredWebView: webView)
        } catch {
            Telemetry.shared.recordError(signature: "om:html_session", message: error.localizedDescription)
            return nil
        }
    }

    /// Native-display session for a remote-URL surface (rewarded game / minigame /
    /// fallback) whose page can't be injected. Created only when `verifications` is
    /// non-empty — the session exists solely to run vendor scripts against the
    /// registered view. Nil when OM is inactive, no service script is cached, no usable
    /// verification resource survives, or creation throws.
    static func startNativeSession(
        adView: UIView,
        verifications: [AdVerification],
        impressionId: String?
    ) -> OMAdSession? {
        guard OpenMeasurement.isActive, !verifications.isEmpty,
              let partner = OpenMeasurement.cachedPartner,
              let js = OpenMeasurement.cachedOMIDJS else { return nil }
        let resources = verifications.compactMap { $0.toResource() }
        guard !resources.isEmpty else { return nil }
        do {
            let config = try OMIDSimulaadAdSessionConfiguration(
                creativeType: .nativeDisplay,
                impressionType: .beginToRender,
                impressionOwner: .nativeOwner,
                mediaEventsOwner: .noneOwner,
                isolateVerificationScripts: false
            )
            let context = try OMIDSimulaadAdSessionContext(
                partner: partner,
                script: js,
                resources: resources,
                contentUrl: nil,
                customReferenceIdentifier: impressionId
            )
            return try begin(config: config, context: context, mainView: adView, measuredWebView: adView as? WKWebView)
        } catch {
            Telemetry.shared.recordError(signature: "om:native_session", message: error.localizedDescription)
            return nil
        }
    }

    /// Create the session, register the ad view, build AdEvents, then start — OMID's
    /// required order on iOS (AdEvents before `start()`).
    private static func begin(
        config: OMIDSimulaadAdSessionConfiguration,
        context: OMIDSimulaadAdSessionContext,
        mainView: UIView,
        measuredWebView: WKWebView?
    ) throws -> OMAdSession {
        let session = try OMIDSimulaadAdSession(configuration: config, adSessionContext: context)
        session.mainAdView = mainView
        let events = try OMIDSimulaadAdEvents(adSession: session)
        session.start()
        return OMAdSession(session: session, events: events, webView: measuredWebView)
    }

    func fireLoaded() {
        guard !loadedFired, !finished else { return }
        loadedFired = true
        do { try events.loaded() }
        catch { Telemetry.shared.recordError(signature: "om:loaded", message: error.localizedDescription) }
    }

    func fireImpression() {
        guard !impressionFired, !finished else { return }
        impressionFired = true
        do { try events.impressionOccurred() }
        catch { Telemetry.shared.recordError(signature: "om:impression", message: error.localizedDescription) }
    }

    /// Register an SDK-chrome view that overlaps the ad so OMID excludes it from
    /// viewability calculations. No-op-safe (guarded).
    func addFriendlyObstruction(_ view: UIView, purpose: OMIDFriendlyObstructionType, reason: String?) {
        do { try session.addFriendlyObstruction(view, purpose: purpose, detailedReason: reason) }
        catch { Telemetry.shared.recordError(signature: "om:obstruction", message: error.localizedDescription) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        session.finish()
        // OMID requires the web view to outlive the session by ≥1s so the verification
        // script can flush; the pool keeps it retained and defers the reset.
        if let webView = measuredWebView {
            WebViewPool.shared.markForDelayedRelease(webView)
        }
    }
}

private extension AdVerification {
    /// Build an OMID verification resource, dropping entries with a malformed URL.
    func toResource() -> OMIDSimulaadVerificationScriptResource? {
        guard let url = URL(string: javascriptResourceUrl) else { return nil }
        if let vendorKey, let parameters = verificationParameters {
            return OMIDSimulaadVerificationScriptResource(url: url, vendorKey: vendorKey, parameters: parameters)
        }
        return OMIDSimulaadVerificationScriptResource(url: url)
    }
}

#endif
