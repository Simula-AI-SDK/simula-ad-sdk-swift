#if os(iOS)
import Foundation

/// Failure cases a ``NativeAdSlot`` surfaces through its `onError`. Scoped to the four outcomes an
/// inline native slot can actually produce, unlike the imperative ``SimulaAdError`` whose
/// `show()`/`load()` lifecycle cases (not-ready, stale, duplicate-request, already-showing,
/// no-presentation-context, unsupported-platform) can never apply to a feed slot. Mirrors the Kotlin
/// SDK's `NativeAdError`.
public enum NativeAdError: Sendable {
    /// `SimulaAds.initialize` was never called.
    case notInitialized
    /// A server session could not be created — bad API key / network, or a 401 on the ad request.
    case noSession
    /// The server returned no creative for this slot (no fill). The slot also collapses to zero height.
    case noFill
    /// A network or decoding error occurred while loading the creative.
    case network
}

extension NativeAdError {
    /// Stable, low-cardinality code for this error, used as the `error_code` on telemetry events.
    /// Matches the imperative ``SimulaAdError/telemetryCode`` strings for the shared cases.
    var telemetryCode: String {
        switch self {
        case .notInitialized: return "not_initialized"
        case .noSession: return "no_session"
        case .noFill: return "no_fill"
        case .network: return "network"
        }
    }

    /// Maps an internal load-path ``SimulaAdError`` to the public native taxonomy. Only the four native
    /// outcomes can occur on the native load path; any other case maps defensively to `.network` so an
    /// unexpected error is never dropped.
    init(_ error: SimulaAdError) {
        switch error {
        case .notInitialized: self = .notInitialized
        case .noSession: self = .noSession
        case .noFill: self = .noFill
        case .network: self = .network
        default: self = .network
        }
    }
}
#endif
