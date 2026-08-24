#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation

// MARK: - Bridge value types

/// Haptic styles a creative can request via `TRIGGER_HAPTIC` (PRD §3).
enum HapticStyle: String {
    case light, medium, heavy, success, error
}

/// Orientation a creative can request via `SET_ORIENTATION` (PRD §3). `auto` unlocks.
enum BridgeOrientation: String {
    case portrait, landscape, auto
}

struct CreativeAudioState: Equatable {
    let muted: Bool
    let volume: Int

    init(outputVolume: Float) {
        let normalized = outputVolume.isFinite ? min(max(outputVolume, 0), 1) : 0
        volume = min(max(Int((normalized * 100).rounded(.toNearestOrAwayFromZero)), 0), 100)
        muted = volume == 0
    }

    var payload: [String: Any] {
        ["muted": muted, "volume": volume]
    }
}

protocol CreativeAudioVolumeObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: CreativeAudioVolumeObservation {}

protocol CreativeAudioVolumeSource: AnyObject {
    var outputVolume: Float { get }
    func observe(_ onChange: @escaping (Float) -> Void) -> CreativeAudioVolumeObservation?
}

private final class SystemCreativeAudioVolumeSource: CreativeAudioVolumeSource {
    var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    func observe(_ onChange: @escaping (Float) -> Void) -> CreativeAudioVolumeObservation? {
        AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, change in
            onChange(change.newValue ?? session.outputVolume)
        }
    }
}

protocol CreativeAudioVolumePolling: AnyObject {
    func start(_ onPoll: @escaping () -> Void)
    func stop()
}

/** Fallback for iOS versions that emit output-volume KVO only while the host audio session is active. */
private final class SystemCreativeAudioVolumePoller: CreativeAudioVolumePolling {
    // KVO remains the fast path. This only closes inactive-session gaps, so sub-second polling is enough.
    private static let interval: TimeInterval = 0.75

    private var timer: Timer?
    private var onPoll: (() -> Void)?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    func start(_ onPoll: @escaping () -> Void) {
        stop()
        self.onPoll = onPoll

        let center = NotificationCenter.default
        backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopTimer()
        }
        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.startTimer()
            self.onPoll?()
        }

        if UIApplication.shared.applicationState != .background {
            startTimer()
        }
    }

    func stop() {
        stopTimer()
        let center = NotificationCenter.default
        if let backgroundObserver { center.removeObserver(backgroundObserver) }
        if let foregroundObserver { center.removeObserver(foregroundObserver) }
        backgroundObserver = nil
        foregroundObserver = nil
        onPoll = nil
    }

    private func startTimer() {
        guard timer == nil, onPoll != nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.onPoll?()
        }
        timer.tolerance = Self.interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stop()
    }
}

/// Something whose allowed interface orientations the bridge can pin (the presenter's
/// hosting controller). Kept as a protocol so `CreativeBridge` holds it without the
/// hosting controller's generic `Content` leaking in.
protocol OrientationLockable: AnyObject {
    var orientationMask: UIInterfaceOrientationMask { get set }
    /// Push the current `orientationMask` to the system (re-evaluates supported
    /// orientations and, on iOS 16+, requests a geometry update).
    func applyOrientationLock()
}

// MARK: - CreativeBridge

/// The native side of the WebView ↔ SDK bridge (PRD §3). An HTML creative posts a JSON
/// envelope `{ type, requestId?, payload? }` via `window.postMessage`; this routes it to
/// a native action and, for `GET_*` queries, posts a reply back into the page echoing the
/// same `requestId`.
///
/// `GET_AUDIO_STATE` returns `{ muted, volume }`, where `volume` is the output-volume percentage
/// from 0 to 100. Loaded creative pages also receive `AUDIO_STATE_CHANGED` with that payload when
/// the normalized state changes.
///
/// Created by the rewarded / interstitial presenter (which owns the window + hosting
/// controller the orientation handler needs). The presenting view observes `earlyComplete`
/// to reveal its close button immediately on `AD_EARLY_COMPLETE`.
final class CreativeBridge: ObservableObject {
    /// Flipped to `true` on `AD_EARLY_COMPLETE`. The presenting view observes this and
    /// shows the close button / grants the reward immediately, bypassing the play timer.
    @Published var earlyComplete = false

    /// The hosting controller whose `supportedInterfaceOrientations` we pin for
    /// `SET_ORIENTATION`. Set by the presenter once the window exists.
    weak var orientationHost: OrientationLockable?
    /// The presentation window — its `windowScene` is used to read/lock orientation.
    weak var window: UIWindow?

    private let audioVolumeSource: CreativeAudioVolumeSource
    private let audioVolumePoller: CreativeAudioVolumePolling
    private var audioObservation: CreativeAudioVolumeObservation?
    private var audioEventReply: ((String) -> Void)?
    private var lastSentAudioState: CreativeAudioState?
    private var audioPageGeneration: UInt64 = 0

    init(
        audioVolumeSource: CreativeAudioVolumeSource = SystemCreativeAudioVolumeSource(),
        audioVolumePoller: CreativeAudioVolumePolling = SystemCreativeAudioVolumePoller()
    ) {
        self.audioVolumeSource = audioVolumeSource
        self.audioVolumePoller = audioVolumePoller
    }

    deinit {
        audioObservation?.invalidate()
        audioVolumePoller.stop()
    }

    // MARK: Entry point

    /// Handle one envelope from the creative. `reply` delivers a JS string back into the
    /// page (the coordinator binds it to `webView.evaluateJavaScript`). All work runs on
    /// the main thread (UIKit + `@Published` + JS evaluation).
    func handle(_ json: String, reply: @escaping (String) -> Void) {
        if Thread.isMainThread {
            process(json, reply: reply)
        } else {
            DispatchQueue.main.async { [weak self] in self?.process(json, reply: reply) }
        }
    }

    private func process(_ json: String, reply: @escaping (String) -> Void) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else {
            return
        }
        // Preserve the requestId's original JSON type (string or number) so the reply
        // echoes it verbatim.
        let requestId = root["requestId"]
        let payload = root["payload"] as? [String: Any] ?? [:]

        switch type {
        // Events
        case "AD_EARLY_COMPLETE":
            earlyComplete = true

        // Commands
        case "TRIGGER_HAPTIC":
            if let raw = payload["style"] as? String, let style = HapticStyle(rawValue: raw) {
                triggerHaptic(style)
            }
        case "SET_ORIENTATION":
            if let raw = payload["orientation"] as? String, let o = BridgeOrientation(rawValue: raw) {
                setOrientation(o)
            }

        // Queries (request/response)
        case "GET_DEVICE_CONTEXT":
            sendMessage(type: type, requestId: requestId, payload: deviceContext(), reply: reply)
        case "GET_AUDIO_STATE":
            sendMessage(type: type, requestId: requestId, payload: currentAudioState().payload, reply: reply)
        case "GET_ORIENTATION":
            sendMessage(type: type, requestId: requestId, payload: ["orientation": currentOrientation()], reply: reply)

        default:
            return // Unknown type: ignore (don't record telemetry for it).
        }

        Telemetry.shared.recordOperation(name: "bridge_\(type.lowercased())", durationMs: 0, success: true)
    }

    // MARK: Reply

    /// Posts `{ type, requestId, payload, __simulaSdkResponse: true }` back into the page
    /// via `window.postMessage`. The injected relay drops messages carrying
    /// `__simulaSdkResponse`, so this reply is not echoed back to native.
    private func sendMessage(type: String, requestId: Any?, payload: [String: Any], reply: (String) -> Void) {
        var resp: [String: Any] = ["type": type, "payload": payload, "__simulaSdkResponse": true]
        if let requestId { resp["requestId"] = requestId }
        guard let data = try? JSONSerialization.data(withJSONObject: resp),
              let body = String(data: data, encoding: .utf8) else { return }
        // `body` is valid JSON, hence a valid JS object literal.
        reply("window.postMessage(\(body), '*');")
    }

    // MARK: Audio events

    /// Stops delivery to the old JavaScript world once a replacement main document commits.
    func pageDidCommit() {
        runOnMain { bridge in bridge.endAudioEvents() }
    }

    /// Sends one initial state after load, then observes distinct output-volume changes.
    func pageDidFinishLoading(reply: @escaping (String) -> Void) {
        runOnMain { bridge in
            bridge.endAudioEvents()
            bridge.audioEventReply = reply
            let generation = bridge.audioPageGeneration
            bridge.audioObservation = bridge.audioVolumeSource.observe { [weak bridge] volume in
                bridge?.audioVolumeChanged(volume, generation: generation)
            }
            bridge.audioVolumePoller.start { [weak bridge] in
                bridge?.audioVolumePolled(generation: generation)
            }
            bridge.publishAudioState(bridge.currentAudioState())
        }
    }

    /// Presentation teardown backstop. Idempotent and safe if dismantle also invokes it.
    func stop() {
        runOnMain { bridge in bridge.endAudioEvents() }
    }

    private func runOnMain(_ work: @escaping (CreativeBridge) -> Void) {
        if Thread.isMainThread {
            work(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                work(self)
            }
        }
    }

    private func endAudioEvents() {
        audioPageGeneration &+= 1
        audioObservation?.invalidate()
        audioObservation = nil
        audioVolumePoller.stop()
        audioEventReply = nil
        lastSentAudioState = nil
    }

    private func audioVolumeChanged(_ outputVolume: Float, generation: UInt64) {
        runOnMain { bridge in
            guard bridge.audioPageGeneration == generation else { return }
            bridge.publishAudioState(CreativeAudioState(outputVolume: outputVolume))
        }
    }

    private func audioVolumePolled(generation: UInt64) {
        runOnMain { bridge in
            guard bridge.audioPageGeneration == generation else { return }
            bridge.publishAudioState(bridge.currentAudioState())
        }
    }

    private func publishAudioState(_ state: CreativeAudioState) {
        guard let reply = audioEventReply, state != lastSentAudioState else { return }
        lastSentAudioState = state
        sendMessage(type: "AUDIO_STATE_CHANGED", requestId: nil, payload: state.payload, reply: reply)
    }

    // MARK: Handlers

    private func triggerHaptic(_ style: HapticStyle) {
        switch style {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func setOrientation(_ orientation: BridgeOrientation) {
        let mask: UIInterfaceOrientationMask
        switch orientation {
        case .portrait: mask = .portrait
        case .landscape: mask = .landscape
        case .auto: mask = .all
        }
        orientationHost?.orientationMask = mask
        orientationHost?.applyOrientationLock()
    }

    private func deviceContext() -> [String: Any] {
        [
            "darkMode": UITraitCollection.current.userInterfaceStyle == .dark,
            "locale": Locale.current.identifier,
            "osVersion": UIDevice.current.systemVersion,
        ]
    }

    /// iOS exposes no public silent-switch API; output volume is the documented media-volume proxy.
    private func currentAudioState() -> CreativeAudioState {
        CreativeAudioState(outputVolume: audioVolumeSource.outputVolume)
    }

    private func currentOrientation() -> String {
        let isLandscape = window?.windowScene?.interfaceOrientation.isLandscape ?? false
        return isLandscape ? "landscape" : "portrait"
    }
}

// MARK: - OrientationLockingHostingController

/// A `UIHostingController` whose supported interface orientations can be pinned at runtime
/// (for the bridge's `SET_ORIENTATION`). The presenter hosts the ad creative in one of these
/// so a creative can lock to portrait/landscape and back to `auto` (`.all`).
final class OrientationLockingHostingController<Content: View>: UIHostingController<Content>, OrientationLockable {
    var orientationMask: UIInterfaceOrientationMask = .all

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }

    func applyOrientationLock() {
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { _ in }
        } else {
            // Pre-iOS 16: nudge the device into the locked orientation; the overridden
            // `supportedInterfaceOrientations` keeps it there.
            let target: UIInterfaceOrientation? = orientationMask == .landscape ? .landscapeRight
                : orientationMask == .portrait ? .portrait
                : nil
            if let target {
                UIDevice.current.setValue(target.rawValue, forKey: "orientation")
            }
        }
    }
}
#endif
