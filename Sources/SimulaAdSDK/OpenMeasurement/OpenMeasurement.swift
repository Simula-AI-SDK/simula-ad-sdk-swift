//
//  OpenMeasurement.swift
//  SimulaAdSDK
//
//  Process-wide entry point for IAB Open Measurement (OMID): one-time activation,
//  cached Partner + OM JS service script, and the HTML-injection helper.
//
//  Measurement must never break an ad — every OMID call is guarded and any failure
//  disables OM for the process while the ad renders unmeasured. OMID iOS is
//  main-thread-only, so the whole surface is `@MainActor`.
//

#if os(iOS) && canImport(OMSDK_Simulaad)
import Foundation
import WebKit
import OMSDK_Simulaad

@MainActor
enum OpenMeasurement {

    /// Partner name issued by IAB Tech Lab — must match the SDK namespace ("Simulaad").
    private static let partnerName = "Simulaad"

    private static var enabled = false
    private static var partner: OMIDSimulaadPartner?
    private static var omidJS: String?

    /// True only when the host opted in AND OMID activated successfully.
    static var isActive: Bool {
        enabled && OMIDSimulaadSDK.shared.isActive
    }

    /// The cached OMID partner; nil until `activate` succeeds.
    static var cachedPartner: OMIDSimulaadPartner? { partner }

    /// Activate OMID once, at SDK init. Cheap, main-thread; the ~50KB service-script
    /// read is pushed to a detached Task so nothing touches disk on an ad path.
    /// Idempotent and safe to call repeatedly (e.g. from both entry points).
    static func activate(enabled: Bool) {
        guard enabled else { Self.enabled = false; return }
        guard !Self.enabled else { return } // already activated

        if !OMIDSimulaadSDK.shared.isActive {
            OMIDSimulaadSDK.shared.activate()
        }
        guard OMIDSimulaadSDK.shared.isActive,
              let p = OMIDSimulaadPartner(name: partnerName, versionString: SIMULA_SDK_VERSION) else {
            Telemetry.shared.recordError(signature: "om:activate")
            Self.enabled = false
            return
        }
        partner = p
        Self.enabled = true

        // Warm the service-script cache off the main thread.
        Task.detached(priority: .utility) {
            let js = loadBundledJS()
            await MainActor.run { OpenMeasurement.omidJS = js }
        }
    }

    /// Splice the OMID service script into `html` so a verification script referenced by
    /// the creative can run. Returns `html` unchanged when OM is inactive or on any
    /// failure — the ad renders normally, just unmeasured.
    static func injectOMID(intoHTML html: String) async -> String {
        guard isActive else { return html }
        let cached: String?
        if let omidJS { cached = omidJS } else { cached = await ensureJSLoaded() }
        guard let js = cached else { return html }
        do {
            return try OMIDSimulaadScriptInjector.injectScriptContent(js, intoHTML: html)
        } catch {
            Telemetry.shared.recordError(signature: "om:inject", message: error.localizedDescription)
            return html
        }
    }

    /// Inject the OMID service script into a live `webView` whose page we don't author —
    /// the remote-URL surfaces (rewarded game / minigame / fallback). An HTML ad session
    /// needs the service running in the page, so the caller starts the session only after
    /// this resolves `true`. Returns `false` when OM is inactive or the script can't be
    /// read; the ad then renders unmeasured.
    @discardableResult
    static func injectServiceScript(into webView: WKWebView) async -> Bool {
        guard isActive else { return false }
        let cached: String?
        if let omidJS { cached = omidJS } else { cached = await ensureJSLoaded() }
        guard let js = cached else { return false }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in cont.resume() }
        }
        return true
    }

    /// Loads + caches the service script if the activation-time read hasn't finished yet.
    private static func ensureJSLoaded() async -> String? {
        if let omidJS { return omidJS }
        let js = await Task.detached(priority: .userInitiated) { loadBundledJS() }.value
        omidJS = js
        return js
    }

    /// Reads the bundled `omsdk-v1.js`. Safe off the main actor.
    private nonisolated static func loadBundledJS() -> String? {
        guard let url = Bundle.module.url(forResource: "omsdk-v1", withExtension: "js"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            Telemetry.shared.recordError(signature: "om:js_read")
            return nil
        }
        return content
    }
}

#else

/// No-op stub for platforms without the OMID framework (e.g. macOS). Keeps the
/// cross-platform call sites (`SimulaAds`, `SimulaInterstitialAd`) compiling.
@MainActor
enum OpenMeasurement {
    static var isActive: Bool { false }
    static func activate(enabled: Bool) {}
    static func injectOMID(intoHTML html: String) async -> String { html }
}

#endif
