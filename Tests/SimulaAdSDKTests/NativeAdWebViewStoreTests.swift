#if os(iOS)
import XCTest
import WebKit
@testable import SimulaAdSDK

/// State-machine tests for `NativeAdWebViewStore` (PR #44 review fixes). iOS-only: the store and
/// `WKWebView` are `#if os(iOS)`; CI's simulator lane runs these. Each test uses fresh UUID
/// impression ids and evicts what it created, so the shared store never leaks state across tests.
@MainActor
final class NativeAdWebViewStoreTests: XCTestCase {
    private final class StubDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {}

    private let delegate = StubDelegate()

    private func attach(_ id: String, key: String = "creative") -> (webView: WKWebView, alreadyLoaded: Bool) {
        NativeAdWebViewStore.shared.attach(
            impressionId: id,
            creativeKey: key,
            delegate: delegate,
            onMessage: { _ in }
        )
    }

    private func cleanup(_ webView: WKWebView, id: String) {
        _ = NativeAdWebViewStore.shared.detach(webView, impressionId: id)
        NativeAdWebViewStore.shared.evict(impressionId: id)
    }

    /// A session detached before its creative load finished must NOT reattach as `alreadyLoaded` —
    /// the remount has to issue the load itself or the slot stays empty.
    func testReattachRequiresCompletedLoad() {
        let id = UUID().uuidString
        let first = attach(id)
        XCTAssertFalse(first.alreadyLoaded)
        XCTAssertTrue(NativeAdWebViewStore.shared.detach(first.webView, impressionId: id))

        let second = attach(id)
        XCTAssertFalse(second.alreadyLoaded, "never-finished session must be rebuilt, not reattached")
        cleanup(second.webView, id: id)
    }

    /// The healthy path: load finished, detached, reattached — same view, no reload.
    func testReattachAfterSuccessfulLoadReturnsSameViewWithoutReload() {
        let id = UUID().uuidString
        let first = attach(id)
        NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(first.webView))
        XCTAssertTrue(NativeAdWebViewStore.shared.detach(first.webView, impressionId: id))

        let second = attach(id)
        XCTAssertTrue(second.alreadyLoaded)
        XCTAssertTrue(second.webView === first.webView, "reattach must hand back the retained view")
        cleanup(second.webView, id: id)
    }

    /// `markUnusable` from the main thread must land synchronously: a detach in the same runloop
    /// turn destroys the session instead of retaining the dead view.
    func testMarkUnusableIsSynchronousOnMainThread() {
        let id = UUID().uuidString
        let first = attach(id)
        NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(first.webView))
        NativeAdWebViewStore.markUnusable(viewID: ObjectIdentifier(first.webView))
        // No runloop spin between mark and detach — this is exactly the race being guarded.
        XCTAssertTrue(NativeAdWebViewStore.shared.detach(first.webView, impressionId: id))

        let second = attach(id)
        XCTAssertFalse(second.alreadyLoaded, "unusable session must be destroyed, not reattached")
        cleanup(second.webView, id: id)
    }

    /// A changed creative under the same impression id rebuilds fresh (stale-creative guard).
    func testReattachWithDifferentCreativeKeyRebuildsFresh() {
        let id = UUID().uuidString
        let first = attach(id, key: "creative-a")
        NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(first.webView))
        _ = NativeAdWebViewStore.shared.detach(first.webView, impressionId: id)

        let second = attach(id, key: "creative-b")
        XCTAssertFalse(second.alreadyLoaded)
        XCTAssertFalse(second.webView === first.webView)
        cleanup(second.webView, id: id)
    }

    /// Consent change: idle sessions are destroyed immediately; attached (on-screen) ones are
    /// flagged so scroll-out destroys them — neither may serve under the stale data store.
    func testConsentChangeEvictsIdleAndFlagsAttached() {
        let idleId = UUID().uuidString
        let attachedId = UUID().uuidString

        let idle = attach(idleId)
        NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(idle.webView))
        _ = NativeAdWebViewStore.shared.detach(idle.webView, impressionId: idleId)

        let attached = attach(attachedId)
        NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(attached.webView))

        NativeAdWebViewStore.shared.evictAllForConsentChange()

        // Idle session was destroyed — next attach rebuilds fresh.
        let idleAgain = attach(idleId)
        XCTAssertFalse(idleAgain.alreadyLoaded)

        // Attached session was flagged — destroyed on detach, never reattached.
        _ = NativeAdWebViewStore.shared.detach(attached.webView, impressionId: attachedId)
        let attachedAgain = attach(attachedId)
        XCTAssertFalse(attachedAgain.alreadyLoaded)

        cleanup(idleAgain.webView, id: idleId)
        cleanup(attachedAgain.webView, id: attachedId)
    }

    /// Batch eviction (cache-eviction path) drops idle retained sessions for the given ids.
    func testEvictAllImpressionIdsDropsIdleSessions() {
        let id = UUID().uuidString
        let first = attach(id)
        NativeAdWebViewStore.markLoadSucceeded(viewID: ObjectIdentifier(first.webView))
        _ = NativeAdWebViewStore.shared.detach(first.webView, impressionId: id)

        NativeAdWebViewStore.shared.evictAll(impressionIds: [id, "unknown-id"])

        let second = attach(id)
        XCTAssertFalse(second.alreadyLoaded, "evicted session must not be reattached")
        cleanup(second.webView, id: id)
    }
}
#endif
