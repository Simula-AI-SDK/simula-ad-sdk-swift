import Foundation

/// Cross-platform-testable iOS retention policy. Android uses the same business limits with
/// Android-native low-RAM/heap signals; iOS uses physical RAM plus lifecycle/memory callbacks.
enum SimulaWebViewPolicy {
    static let normalIdleCap = 1
    static let normalRetainedCap = 3
    static let constrainedRetainedCap = 1
    static let cooldown: TimeInterval = 5 * 60
    private static let constrainedRamBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static func isMemoryConstrained(totalRamBytes: UInt64) -> Bool {
        totalRamBytes <= constrainedRamBytes
    }

    static func idleCap(totalRamBytes: UInt64) -> Int {
        isMemoryConstrained(totalRamBytes: totalRamBytes) ? 0 : normalIdleCap
    }

    static func retainedCap(totalRamBytes: UInt64) -> Int {
        isMemoryConstrained(totalRamBytes: totalRamBytes) ? constrainedRetainedCap : normalRetainedCap
    }

    static func blockedUntil(
        current: TimeInterval,
        now: TimeInterval,
        event: SimulaWebViewLifecycleEvent
    ) -> TimeInterval {
        switch event {
        case .background:
            return current
        case .memoryPressure, .rendererDeath:
            return max(current, now + cooldown)
        }
    }

    static func canRetain(
        maxIdle: Int,
        idleCount: Int,
        applicationActive: Bool,
        now: TimeInterval,
        blockedUntil: TimeInterval
    ) -> Bool {
        prewarmDecision(
            maxIdle: maxIdle,
            idleCount: idleCount,
            applicationActive: applicationActive,
            now: now,
            blockedUntil: blockedUntil
        ) == .warm
    }

    static func prewarmDecision(
        maxIdle: Int,
        idleCount: Int,
        applicationActive: Bool,
        now: TimeInterval,
        blockedUntil: TimeInterval
    ) -> SimulaWebViewPrewarmDecision {
        if maxIdle <= 0 { return .constrained }
        if idleCount >= maxIdle { return .full }
        if !applicationActive { return .inactive }
        if now < blockedUntil { return .cooldown }
        return .warm
    }
}

enum SimulaWebViewLifecycleEvent {
    case background
    case memoryPressure
    case rendererDeath
}

enum SimulaWebViewPrewarmDecision: String, Hashable {
    case warm = "warmed"
    case constrained
    case full
    case cooldown
    case inactive
}

enum CreativeActivationClaim: Equatable {
    case none
    case newGesture
    case duplicateGesture
}

enum CreativeActivationEvent: Equatable {
    case pointerDown(type: String, trusted: Bool)
    case pointerUp(type: String, trusted: Bool)
    case pointerCancel(trusted: Bool)
    case mouseDown(trusted: Bool)
    case touchStart(trusted: Bool)
    case touchEnd(trusted: Bool)
    case touchCancel(trusted: Bool)
    case keyDown(key: String, repeatKey: Bool, trusted: Bool)
    case click(trusted: Bool)
}

/// Cross-platform model of the document-start activation fallback used when
/// `navigator.userActivation` is unavailable on older WebKit versions.
struct CreativeUserActivationState: Equatable {
    private(set) var gestureSequence = 0
    private(set) var claimedGesture = -1
    private(set) var trustedEventDispatch = false
    private var awaitingClick = false
    private var contactPending = false
    private var cancelledContact = false

    mutating func observe(_ event: CreativeActivationEvent) {
        switch event {
        case .pointerDown(let type, let trusted):
            guard trusted else { return }
            if type.lowercased() == "touch" || type.lowercased() == "pen" {
                disarmForPendingContact()
            } else {
                beginGesture()
            }
        case .pointerUp(let type, let trusted):
            guard trusted else { return }
            if type.lowercased() == "touch" || type.lowercased() == "pen" {
                guard contactPending else { return }
                contactPending = false
            }
            beginGesture()
        case .pointerCancel(let trusted), .touchCancel(let trusted):
            guard trusted else { return }
            contactPending = false
            awaitingClick = false
            trustedEventDispatch = false
            cancelledContact = true
        case .mouseDown(let trusted):
            guard trusted, !contactPending else { return }
            beginGesture()
        case .touchStart(let trusted):
            guard trusted else { return }
            disarmForPendingContact()
        case .touchEnd(let trusted):
            guard trusted, contactPending else { return }
            contactPending = false
            beginGesture()
        case .keyDown(let key, let repeatKey, let trusted):
            guard trusted, !repeatKey, qualifiesKeyboardKey(key) else { return }
            beginKeyboardGesture()
        case .click(let trusted):
            guard trusted, !cancelledContact, !contactPending else { return }
            if !awaitingClick { beginGesture() } else { trustedEventDispatch = true }
            awaitingClick = false
        }
    }

    mutating func claim(navigatorIsActive: Bool) -> CreativeActivationClaim {
        guard gestureSequence > 0 else { return .none }
        if claimedGesture == gestureSequence { return .duplicateGesture }
        guard !contactPending, !cancelledContact,
              navigatorIsActive || trustedEventDispatch else { return .none }
        claimedGesture = gestureSequence
        return .newGesture
    }

    mutating func expireMacrotask() {
        trustedEventDispatch = false
        cancelledContact = false
    }

    private mutating func disarmForPendingContact() {
        contactPending = true
        awaitingClick = false
        trustedEventDispatch = false
        cancelledContact = false
    }

    private mutating func beginGesture() {
        cancelledContact = false
        if !awaitingClick { gestureSequence += 1 }
        awaitingClick = true
        trustedEventDispatch = true
    }

    private mutating func beginKeyboardGesture() {
        cancelledContact = false
        gestureSequence += 1
        awaitingClick = true
        trustedEventDispatch = true
    }

    private func qualifiesKeyboardKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        if normalized == "escape" || normalized == "esc" { return false }
        return !["alt", "altgraph", "capslock", "control", "ctrl", "fn", "fnlock",
                  "hyper", "meta", "numlock", "scrolllock", "shift", "super", "symbol",
                  "symbollock"].contains(normalized)
    }
}

func creativeUserActivationScriptSource(nonce: String) -> String {
    """
    (function() {
      var originalOpen = window.open;
      var nativeHandler = window.webkit && window.webkit.messageHandlers
        ? window.webkit.messageHandlers.simulaSDK
        : null;
      var postNative = nativeHandler && typeof nativeHandler.postMessage === 'function'
        ? nativeHandler.postMessage.bind(nativeHandler)
        : null;
      var nativeStringify = JSON.stringify.bind(JSON);
      var capturedUserActivation = navigator.userActivation;
      var nativeSetTimeout = window.setTimeout.bind(window);
      var trustedEventDispatch = false;
      var trustedEventEpoch = 0;
      var trustedEventTimestamp = -1;
      var gestureSequence = 0;
      var claimedGesture = -1;
      var awaitingClick = false;
      var contactPending = false;
      var cancelledContact = false;

      function clearTrustedDispatchLater(epoch) {
        nativeSetTimeout(function() {
          if (trustedEventEpoch === epoch) { trustedEventDispatch = false; }
        }, 0);
      }

      function markTrustedDispatch(event) {
        trustedEventEpoch += 1;
        trustedEventTimestamp = Number(event.timeStamp || 0);
        trustedEventDispatch = true;
        clearTrustedDispatchLater(trustedEventEpoch);
      }

      function beginGesture(event) {
        cancelledContact = false;
        if (!awaitingClick) { gestureSequence += 1; }
        awaitingClick = true;
        markTrustedDispatch(event);
      }

      function beginKeyboardGesture(event) {
        cancelledContact = false;
        gestureSequence += 1;
        awaitingClick = true;
        markTrustedDispatch(event);
      }

      function disarmPendingContact() {
        contactPending = true;
        awaitingClick = false;
        trustedEventDispatch = false;
        trustedEventEpoch += 1;
        cancelledContact = false;
      }

      function cancelContact() {
        contactPending = false;
        awaitingClick = false;
        trustedEventDispatch = false;
        trustedEventEpoch += 1;
        cancelledContact = true;
        var epoch = trustedEventEpoch;
        nativeSetTimeout(function() {
          if (trustedEventEpoch === epoch) { cancelledContact = false; }
        }, 0);
      }

      function isModifierOnlyKey(key) {
        return ['alt','altgraph','capslock','control','ctrl','fn','fnlock','hyper','meta',
          'numlock','scrolllock','shift','super','symbol','symbollock'].indexOf(key) !== -1;
      }

      function observeTrustedEvent(event) {
        if (!event || event.isTrusted !== true) { return; }
        var type = event.type;
        var pointerType = String(event.pointerType || '').toLowerCase();
        if (type === 'pointerdown') {
          if (pointerType === 'touch' || pointerType === 'pen') { disarmPendingContact(); }
          else { beginGesture(event); }
        } else if (type === 'pointerup') {
          if (pointerType === 'touch' || pointerType === 'pen') {
            if (!contactPending) { return; }
            contactPending = false;
          }
          beginGesture(event);
        } else if (type === 'pointercancel' || type === 'touchcancel') {
          cancelContact();
        } else if (type === 'touchstart') {
          disarmPendingContact();
        } else if (type === 'touchend') {
          if (!contactPending) { return; }
          contactPending = false;
          beginGesture(event);
        } else if (type === 'mousedown') {
          if (!contactPending) { beginGesture(event); }
        } else if (type === 'keydown') {
          var key = String(event.key || '').toLowerCase();
          if (event.repeat === true || key === 'escape' || key === 'esc' || isModifierOnlyKey(key)) { return; }
          beginKeyboardGesture(event);
        } else if (type === 'click') {
          if (cancelledContact || contactPending) { return; }
          if (!awaitingClick) { beginGesture(event); }
          else { markTrustedDispatch(event); }
          awaitingClick = false;
        }
      }

      ['click', 'pointerdown', 'pointerup', 'pointercancel', 'mousedown',
       'touchstart', 'touchend', 'touchcancel', 'keydown'].forEach(function(name) {
        window.addEventListener(name, observeTrustedEvent, true);
      });

      function hasActiveUserGesture() {
        if (contactPending || cancelledContact) { return false; }
        if (capturedUserActivation && capturedUserActivation.isActive === true) { return true; }
        return trustedEventDispatch && trustedEventTimestamp >= 0;
      }

      function resolvedURL(value) {
        if (value === undefined || value === null) { return null; }
        try { return new URL(String(value), document.baseURI).href; }
        catch (_) { return null; }
      }

      function forwardCTA(value) {
        if (!postNative || gestureSequence === 0) { return false; }
        if (claimedGesture === gestureSequence) { return true; }
        if (!hasActiveUserGesture()) { return false; }
        var url = resolvedURL(value);
        if (!url) { return false; }
        claimedGesture = gestureSequence;
        try {
          postNative(nativeStringify({
            type: 'SIMULA_CTA_OPEN',
            url: url,
            activation_nonce: '\(nonce)'
          }));
          return true;
        } catch (_) {
          if (claimedGesture === gestureSequence) { claimedGesture = -1; }
          return false;
        }
      }

      window.open = function() {
        if (arguments.length > 0 && forwardCTA(arguments[0])) { return null; }
        return originalOpen.apply(window, arguments);
      };

      window.addEventListener('click', function(event) {
        if (!event.isTrusted || !hasActiveUserGesture()) { return; }
        var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
        if (!anchor || String(anchor.target).toLowerCase() !== '_blank') { return; }
        if (forwardCTA(anchor.href)) { event.preventDefault(); }
      }, true);
    })();
    """
}

struct SimulaWebViewPrewarmSkipGate {
    private var reported: Set<SimulaWebViewPrewarmDecision> = []

    mutating func shouldRecord(_ decision: SimulaWebViewPrewarmDecision) -> Bool {
        guard decision != .warm else { return false }
        return reported.insert(decision).inserted
    }
}

/// Paces required native-ad mounts without moving WebKit work off the main actor. The frame wait is
/// injected so queue order, pacing, and cancellation stay deterministic in tests.
@MainActor
final class NativeAdMountScheduler {
    typealias FrameWait = @MainActor () async -> Void
    typealias AdmissionCompletion = @MainActor (Bool) -> Void

    #if os(iOS)
    static let shared = NativeAdMountScheduler(waitForNextFrame: waitForNativeAdDisplayFrame)
    #endif

    private let waitForNextFrame: FrameWait
    private var order: [UUID] = []
    private var completions: [UUID: AdmissionCompletion] = [:]
    private var frameTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(waitForNextFrame: @escaping FrameWait) {
        self.waitForNextFrame = waitForNextFrame
    }

    var pendingCount: Int { completions.count }

    func waitForAdmission() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                enqueue(id: id) { continuation.resume(returning: $0) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
    }

    private func scheduleFrameIfNeeded() {
        guard frameTask == nil, !completions.isEmpty else { return }
        frameTask = Task { @MainActor [weak self] in await self?.runFrame() }
    }

    private func runFrame() async {
        await waitForNextFrame()
        frameTask = nil
        defer { resumeIdleWaitersIfNeeded() }
        guard !Task.isCancelled else { return }

        while !order.isEmpty {
            let id = order.removeFirst()
            if let completion = completions.removeValue(forKey: id) {
                completion(true)
                break
            }
        }
        scheduleFrameIfNeeded()
    }

    private func cancel(_ id: UUID) {
        if let index = order.firstIndex(of: id) { order.remove(at: index) }
        completions.removeValue(forKey: id)?(false)
    }

    private func enqueue(id: UUID, completion: @escaping AdmissionCompletion) {
        order.append(id)
        completions[id] = completion
        scheduleFrameIfNeeded()
    }

    @discardableResult
    func enqueueForTests(completion: @escaping AdmissionCompletion) -> UUID {
        let id = UUID()
        enqueue(id: id, completion: completion)
        return id
    }

    func cancelForTests(_ id: UUID) { cancel(id) }

    func waitForIdleForTests() async {
        if frameTask == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard frameTask == nil else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

#if os(iOS)
import WebKit
import UIKit
import os

@MainActor
private final class NativeAdDisplayLinkWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var displayLink: CADisplayLink?

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func start() {
        let displayLink = CADisplayLink(target: self, selector: #selector(frameDidArrive))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func frameDidArrive() {
        displayLink?.invalidate()
        displayLink = nil
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitForNativeAdDisplayFrame() async {
    await withCheckedContinuation { continuation in
        NativeAdDisplayLinkWaiter(continuation: continuation).start()
    }
}

// MARK: - MessageForwarder

/// A stable `WKScriptMessageHandler` installed on a web view at creation time.
///
/// A web view is prewarmed *before* the per-instance coordinator that ultimately
/// wants its messages exists, so we can't register the coordinator directly.
/// Instead we register this forwarder up front (the only reliable way to attach a
/// handler is before the web view is created) and simply repoint its `onMessage`
/// closure when the view is handed out. The closure captures the coordinator
/// weakly, so it introduces no retain cycle through the content controller.
enum WebViewForwardedMessage {
    case page(String)
    case userActivatedCTA(URL)
}

let creativeBridgeMaxMessageUTF16Characters = 64 * 1024
let creativeBridgeCapabilityKey = "__simulaSdkCapability"

func authenticatedCreativeBridgeMessage(_ message: String, expectedCapability: String) -> String? {
    guard message.utf16.count <= creativeBridgeMaxMessageUTF16Characters,
          let data = message.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          root[creativeBridgeCapabilityKey] as? String == expectedCapability else {
        return nil
    }
    return message
}

func creativeRootGuardScriptSource() -> String {
    """
    var isTop = window === window.top;
    var isDirectSrcdoc = false;
    if (!isTop) {
      try {
        isDirectSrcdoc = window.parent === window.top && window.frameElement &&
          window.frameElement.hasAttribute('srcdoc') &&
          window.frameElement === window.top.document.querySelector('iframe[srcdoc]') &&
          String(window.location.href) === 'about:srcdoc';
      } catch (_) {}
    }
    if (!isTop && !isDirectSrcdoc) { return; }
    """
}

func creativeBridgeRelayScriptSource(capability: String) -> String {
    """
    (function() {
      'use strict';
      \(creativeRootGuardScriptSource())
      var bridgeCapability = '\(capability)';
      var nativeHandler = window.webkit && window.webkit.messageHandlers
        ? window.webkit.messageHandlers.simulaSDK
        : null;
      var nativePost = nativeHandler && typeof nativeHandler.postMessage === 'function'
        ? nativeHandler.postMessage.bind(nativeHandler)
        : null;
      var nativeStringify = JSON.stringify.bind(JSON);
      var nativeParse = JSON.parse.bind(JSON);
      function isCreativeRootSource(source) {
        if (source === window) { return true; }
        if (!isTop) { return false; }
        var frame;
        try { frame = document.querySelector('iframe[srcdoc]'); }
        catch (_) { return false; }
        if (!frame || frame.contentWindow !== source) { return false; }
        try { return String(source.location.href) === 'about:srcdoc'; }
        catch (_) { return false; }
      }
      window.addEventListener('message', function(event) {
        if (!nativePost || !event || event.isTrusted !== true ||
            !isCreativeRootSource(event.source)) { return; }
        try {
          var envelope = typeof event.data === 'string' ? nativeParse(event.data) : event.data;
          if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) { return; }
          // Replies and pushes belong to the creative. SDK-internal diagnostics do not: consume
          // them before later page listeners can observe them or throw and create an error loop.
          if (envelope.__simulaSdkResponse) { return; }
          if (envelope.type === 'SIMULA_JS_ERROR' || envelope.type === 'SIMULA_AD_HEIGHT') {
            if (typeof event.stopImmediatePropagation === 'function') {
              event.stopImmediatePropagation();
            }
          }
          var serialized = nativeStringify(envelope);
          if (!serialized || serialized.charAt(0) !== '{') { return; }
          nativePost('{"\(creativeBridgeCapabilityKey)":' + nativeStringify(bridgeCapability) +
            ',' + serialized.substring(1));
        } catch (_) {}
      });
    })();
    """
}

func creativeErrorCaptureScriptSource() -> String {
    """
    (function() {
      'use strict';
      \(creativeRootGuardScriptSource())
      window.addEventListener('error', function(e) {
        try {
          window.postMessage({
            type: 'SIMULA_JS_ERROR',
            message: (e && e.message) ? String(e.message) : 'error',
            line: (e && e.lineno) ? e.lineno : 0
          }, '*');
        } catch (_) {}
      });
    })();
    """
}

final class WebViewMessageForwarder: NSObject, WKScriptMessageHandler {
    private(set) var userActivationNonce = UUID().uuidString
    private(set) var bridgeCapability = UUID().uuidString
    var onMessage: ((WebViewForwardedMessage) -> Void)?

    func rotatePresentationCapabilities() {
        userActivationNonce = UUID().uuidString
        bridgeCapability = UUID().uuidString
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String,
              body.utf16.count <= creativeBridgeMaxMessageUTF16Characters else { return }
        switch CreativeCTAOpenMessage.authenticate(body, expectedNonce: userActivationNonce) {
        case .accepted(let url):
            onMessage?(.userActivatedCTA(url))
        case .rejected:
            return
        case .notMessage:
            guard let authenticated = authenticatedCreativeBridgeMessage(
                body,
                expectedCapability: bridgeCapability
            ) else { return }
            onMessage?(.page(authenticated))
        }
    }
}

// MARK: - WebViewPool

/// Reuses `WKWebView` instances and supports explicit prewarming for demand and ready fullscreen ads.
///
/// The first `WKWebView` an app creates is expensive: it allocates the view,
/// initializes WebKit, and brings up a Web Content process. By creating a web
/// view *before* the user taps a game (when the menu opens), that cost overlaps
/// with menu browsing and the `getMinigame` network round-trip instead of being
/// paid serially right before the game must appear.
///
/// (WebKit manages Web Content process sharing automatically on iOS 15+, so no
/// explicit `WKProcessPool` is needed — the win here is the prewarm handoff.)
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()

    /// JS → native channel name. Must match the injected script below.
    static let messageHandlerName = "simulaSDK"

    private struct Pooled {
        let webView: WKWebView
        let forwarder: WebViewMessageForwarder
        /// Whether this view was built with a persistent data store. Tracked so a
        /// consent change (which flips the storage policy) doesn't hand back a view
        /// with a stale policy.
        let persistent: Bool
    }
    private var idle: [Pooled] = []
    /// Views currently handed out to a representable, retained so `release` can
    /// reset and re-pool them on `dismantleUIView` (recycling) instead of letting
    /// them deallocate and tear down their Web Content process.
    private var active: [ObjectIdentifier: Pooled] = [:]

    /// One spare matches Android and is enough for sequential game/post-game use. Constrained
    /// devices keep no speculative idle view; a required acquire still builds cold.
    private let maxIdle = SimulaWebViewPolicy.idleCap(totalRamBytes: ProcessInfo.processInfo.physicalMemory)
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var poolingBlockedUntil: TimeInterval = 0
    private var prewarmSkipGate = SimulaWebViewPrewarmSkipGate()
    private let signposter = OSSignposter(subsystem: "ad.simula.sdk", category: "WebView")

    var allowsRetention: Bool {
        SimulaWebViewPolicy.canRetain(
            maxIdle: maxIdle,
            idleCount: idle.count,
            applicationActive: applicationActive && UIApplication.shared.applicationState == .active,
            now: ProcessInfo.processInfo.systemUptime,
            blockedUntil: poolingBlockedUntil
        )
    }

    /// Native retained views have their own cap; they share only lifecycle/cooldown eligibility.
    var allowsNativeRetention: Bool {
        applicationActive
            && UIApplication.shared.applicationState == .active
            && ProcessInfo.processInfo.systemUptime >= poolingBlockedUntil
    }

    private init() {
        // Each idle web view keeps a Web Content process resident. Under memory pressure, drop the
        // warm buffer so the SDK isn't holding a tens-of-MB floor in the host (a cold `acquire` simply
        // rebuilds one). `active` views are on screen, so they're deliberately left untouched.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryPressure() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleActive() }
        }
    }

    /// Seals `window.postMessage` payloads from the top or direct srcdoc creative root before they
    /// reach the stable native message handler. Reinstalled with fresh presentation capabilities.
    private static func postMessageScript(capability: String) -> WKUserScript {
        WKUserScript(
            source: creativeBridgeRelayScriptSource(capability: capability),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Forwards creative JS errors (`window.onerror`) to native via the same `simulaSDK` handler, where
    /// the coordinator records them as telemetry. Document-start so early errors are caught too.
    private static let errorCaptureScript = WKUserScript(
        source: creativeErrorCaptureScriptSource(),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// Handles popup CTAs before WebKit can race `createWebViewWith` ahead of an asynchronous script
    /// message. During active user activation, `window.open` and trusted target=_blank clicks are
    /// suppressed synchronously and forwarded as a structured message over the existing bridge.
    /// The per-WebView nonce and bound native handler are captured before creative code runs. Direct
    /// page calls to the public handler therefore cannot forge a billable activation message.
    private static func userActivationScript(nonce: String) -> WKUserScript {
        WKUserScript(
            source: creativeUserActivationScriptSource(nonce: nonce),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    static func installUserScripts(
        on controller: WKUserContentController,
        nonce: String,
        bridgeCapability: String
    ) {
        controller.removeAllUserScripts()
        controller.addUserScript(postMessageScript(capability: bridgeCapability))
        controller.addUserScript(errorCaptureScript)
        controller.addUserScript(userActivationScript(nonce: nonce))
    }

    private func makePooled() -> Pooled {
        let interval = signposter.beginInterval("WebViewCreate")
        defer { signposter.endInterval("WebViewCreate", interval) }
        let forwarder = WebViewMessageForwarder()

        let controller = WKUserContentController()
        controller.add(forwarder, name: WebViewPool.messageHandlerName)
        WebViewPool.installUserScripts(
            on: controller,
            nonce: forwarder.userActivationNonce,
            bridgeCapability: forwarder.bridgeCapability
        )

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = controller

        // Honor TCF Purpose 1 / GDPR: when on-device storage is not permitted, use a
        // non-persistent data store so cookies & localStorage stay in memory for the
        // session and nothing is written to disk. In-session functionality is intact.
        let persistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        if !persistent {
            config.websiteDataStore = .nonPersistent()
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        return Pooled(webView: webView, forwarder: forwarder, persistent: persistent)
    }

    /// Fully dismantle a view we're **discarding** (not re-pooling). `WKUserContentController.add`
    /// holds a strong reference to the forwarder; without removing the handler, the controller keeps
    /// the forwarder (and anything it captures) alive until the system eventually reaps the dropped
    /// `WKWebView` — a leak in long sessions. Re-pooled views deliberately keep their handler.
    private func teardown(_ pooled: Pooled) {
        pooled.forwarder.onMessage = nil
        pooled.webView.stopLoading()
        pooled.webView.navigationDelegate = nil
        pooled.webView.uiDelegate = nil
        pooled.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: WebViewPool.messageHandlerName)
    }

    /// Create a warm web view ahead of time, if the pool has room. Loads
    /// `about:blank` to bring up the Web Content process so the later real load
    /// starts warm. The coordinator ignores `about:blank` navigations, so this
    /// never reaches the consumer's load callbacks. Skips use the sampled operation pipeline and
    /// are bounded to one event per canonical reason for the process.
    func prewarm(trigger: String = "demand") {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let decision = SimulaWebViewPolicy.prewarmDecision(
            maxIdle: maxIdle,
            idleCount: idle.count,
            applicationActive: applicationActive && UIApplication.shared.applicationState == .active,
            now: ProcessInfo.processInfo.systemUptime,
            blockedUntil: poolingBlockedUntil
        )
        guard decision == .warm else {
            if prewarmSkipGate.shouldRecord(decision) {
                recordPrewarm(startNanos: startNanos, trigger: trigger, result: decision.rawValue)
            }
            return
        }
        let interval = signposter.beginInterval("WebViewPrewarm")
        defer { signposter.endInterval("WebViewPrewarm", interval) }
        let pooled = makePooled()
        if let blank = URL(string: "about:blank") {
            pooled.webView.load(URLRequest(url: blank))
        }
        idle.append(pooled)
        recordPrewarm(startNanos: startNanos, trigger: trigger, result: decision.rawValue)
    }

    private func recordPrewarm(startNanos: UInt64, trigger: String, result: String) {
        Telemetry.shared.recordOperation(
            name: "webview_prewarm",
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000),
            success: true,
            breadcrumb: "trigger=\(Self.prewarmTrigger(trigger));result=\(result)",
            timeSinceInitMs: SDKInitializationOrigin.shared.timeSinceInitMs()
        )
    }

    /// Returns a web view wired to `delegate` and `onMessage`, reusing a prewarmed one when available.
    /// Acquiring never refills speculatively; only explicit demand or gated fullscreen-ready work may prewarm.
    func acquire(
        delegate: WKNavigationDelegate & WKUIDelegate,
        onMessage: @escaping (WebViewForwardedMessage) -> Void,
        surface: String? = nil
    ) -> WKWebView {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        // Drop any prewarmed views whose storage policy no longer matches the
        // current consent, then reuse a matching one (or build fresh).
        let wantPersistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        while let last = idle.last, last.persistent != wantPersistent {
            teardown(last)
            idle.removeLast()
        }
        let reusedWarm = idle.last != nil
        let pooled = idle.popLast() ?? makePooled()

        pooled.forwarder.rotatePresentationCapabilities()
        Self.installUserScripts(
            on: pooled.webView.configuration.userContentController,
            nonce: pooled.forwarder.userActivationNonce,
            bridgeCapability: pooled.forwarder.bridgeCapability
        )
        pooled.forwarder.onMessage = onMessage
        pooled.webView.navigationDelegate = delegate
        pooled.webView.uiDelegate = delegate

        active[ObjectIdentifier(pooled.webView)] = pooled

        // Warm (pool hit) vs cold (had to create) — surfaces prewarm effectiveness + cold cost.
        Telemetry.shared.recordOperation(
            name: reusedWarm ? "webview_acquire_warm" : "webview_acquire_cold",
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000),
            success: true,
            breadcrumb: Self.acquireBreadcrumb(surface),
            timeSinceInitMs: SDKInitializationOrigin.shared.timeSinceInitMs()
        )
        return pooled.webView
    }

    /// Transfers ownership of an active (handed-out) web view to the caller — the native-ad
    /// retained store — so a later `release` no-ops instead of resetting it to `about:blank`.
    /// Returns the stable message forwarder wired at creation (the new owner re-points its
    /// `onMessage` on each reattach); `nil` when the view isn't pool-active (already released
    /// or adopted), in which case ownership does not transfer.
    func adopt(_ webView: WKWebView) -> WebViewMessageForwarder? {
        active.removeValue(forKey: ObjectIdentifier(webView))?.forwarder
    }

    /// Reset a finished web view and return it to the pool (or discard if full /
    /// privacy mismatch). Idempotent: a second call for the same view no-ops
    /// because `active` no longer holds it.
    func release(_ webView: WKWebView) {
        guard let pooled = active.removeValue(forKey: ObjectIdentifier(webView)) else {
            return
        }
        pooled.webView.stopLoading()
        pooled.webView.navigationDelegate = nil
        pooled.webView.uiDelegate = nil
        pooled.forwarder.onMessage = nil

        // Only re-pool when the storage policy still matches current consent; a
        // mismatched view is dropped so the next acquire builds a fresh one.
        let wantPersistent = SimulaPrivacy.shared.currentSnapshot.allowsLocalStorage
        if pooled.persistent == wantPersistent && allowsRetention {
            // Tear down the DOM only when recycling. Starting an about:blank load immediately
            // before discarding can race callbacks into a deallocated WebView.
            if let blank = URL(string: "about:blank") {
                pooled.webView.load(URLRequest(url: blank))
            }
            idle.append(pooled)
        } else {
            // Not re-pooled → discard it fully so the content controller doesn't retain the forwarder.
            teardown(pooled)
        }
    }

    /// Flushes prewarmed idle web views. Called on a consent change so the next
    /// view is built with a data store matching the new storage policy (a
    /// prewarmed view bakes its policy in at creation time).
    func clear() {
        let interval = signposter.beginInterval("WebViewPoolClear")
        defer { signposter.endInterval("WebViewPoolClear", interval) }
        idle.forEach { teardown($0) }
        idle.removeAll()
    }

    private func handleMemoryPressure() {
        poolingBlockedUntil = SimulaWebViewPolicy.blockedUntil(
            current: poolingBlockedUntil,
            now: ProcessInfo.processInfo.systemUptime,
            event: .memoryPressure
        )
        clear()
    }

    func handleRendererDeath() {
        poolingBlockedUntil = SimulaWebViewPolicy.blockedUntil(
            current: poolingBlockedUntil,
            now: ProcessInfo.processInfo.systemUptime,
            event: .rendererDeath
        )
        clear()
    }

    private func handleBackground() {
        applicationActive = false
        clear()
    }

    private func handleActive() {
        applicationActive = true
        // Demand callers may prewarm after the cooldown; never allocate automatically here.
    }

    private static func prewarmTrigger(_ value: String) -> String {
        switch value {
        case "minigame_menu", "minigame_game", "interstitial_ready", "rewarded_ready":
            return value
        default:
            return "demand"
        }
    }

    private static func acquireBreadcrumb(_ surface: String?) -> String? {
        switch surface {
        case "interstitial", "rewarded":
            return "surface=\(surface ?? "")"
        default:
            return nil
        }
    }
}
#endif
