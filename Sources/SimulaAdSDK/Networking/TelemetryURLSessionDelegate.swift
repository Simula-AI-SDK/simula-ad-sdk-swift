import Foundation

/// Session-wide task delegate that harvests `URLSessionTaskMetrics` for every request on the
/// SDK's shared `URLSession` and forwards a `network` telemetry event — precise DNS/connect/TLS
/// timing and byte counts, for free, with no per-call-site changes.
///
/// Metrics arrive in `didFinishCollecting` (before the error is final), so they're stashed by
/// task id and emitted in `didCompleteWithError` where both status and error are settled.
/// `@unchecked Sendable`: the stash is guarded by `lock`.
final class TelemetryURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = TelemetryURLSessionDelegate()

    private let lock = NSLock()
    private var metricsByTask: [Int: URLSessionTaskMetrics] = [:]
    /// Bound the stash so an entry whose `didCompleteWithError` never fires (it's removed there) can't
    /// accumulate for the process lifetime. Entries are normally consumed within one request.
    private let maxTrackedTasks = 256

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        // Drop stale orphans wholesale if we somehow accumulate past the cap (cheap; this rarely trips).
        if metricsByTask.count >= maxTrackedTasks { metricsByTask.removeAll(keepingCapacity: true) }
        metricsByTask[task.taskIdentifier] = metrics
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let metrics = metricsByTask.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let url = task.originalRequest?.url,
              isFirstPartyTelemetryURL(url),
              let route = normalizedTelemetryRoute(url.path) else { return }

        let method = task.originalRequest?.httpMethod ?? "GET"
        let status = (task.response as? HTTPURLResponse)?.statusCode
        var durationMs = 0
        var requestBytes: Int64 = 0
        var responseBytes: Int64 = 0
        if let metrics {
            durationMs = Int(metrics.taskInterval.duration * 1000)
            if let last = metrics.transactionMetrics.last {
                requestBytes = last.countOfRequestBodyBytesSent
                responseBytes = last.countOfResponseBodyBytesReceived
            }
        }
        Telemetry.shared.recordNetwork(
            path: route,
            method: method,
            statusCode: status,
            durationMs: durationMs,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            failureClass: telemetryFailureClass(statusCode: status, error: error)
        )
    }
}

/// First-party gate for network telemetry: the SDK's shared session also carries third-party
/// traffic (mini-game cover CDN fetches), and those paths aren't in the route registry — each
/// one would otherwise emit a low-value `GET /unknown` event and crowd the bounded buffer.
/// Only requests to the API's own host are recorded. Pure so it's unit-testable.
func isFirstPartyTelemetryURL(_ url: URL) -> Bool {
    guard let base = URL(string: API_BASE_URL),
          let apiHost = base.host?.lowercased(),
          let apiScheme = base.scheme?.lowercased() else { return false }
    return url.scheme?.lowercased() == apiScheme && url.host?.lowercased() == apiHost
}

/// Low-cardinality route registry for first-party network telemetry. Dynamic identifiers are
/// replaced with templates, sensitive/recursive routes are dropped, and an unregistered route
/// fails closed to `/unknown` rather than sending its raw path.
func normalizedTelemetryRoute(_ path: String) -> String? {
    let segments = path.split(separator: "/").map(String.init)
    guard !segments.isEmpty else { return "/unknown" }
    if segments.first == "telemetry" ||
        (segments.count >= 2 && segments[0] == "v1" && segments[1] == "telemetry") ||
        segments.contains("ppid") { return nil }

    if segments.count == 3, segments[0] == "load", segments[1] == "fallbacks" {
        return "/load/fallbacks/:id"
    }
    if segments.count == 3, segments[0] == "impressions" {
        let allowedActions = Set(["shown", "seen", "click", "interest", "report"])
        guard allowedActions.contains(segments[2]) else { return "/unknown" }
        return "/impressions/:id/\(segments[2])"
    }

    let exactRoutes = Set([
        "/session/create",
        "/frequency-cap/status",
        "/minigames/catalog",
        "/character-selector",
        "/load/interstitial",
        "/load/native",
        "/load/rewarded",
        "/minigames/verify-reward",
        "/minigames/init",
        "/minigames/menu/track/click",
    ])
    return exactRoutes.contains(path) ? path : "/unknown"
}

/// Maps a transport error / HTTP status to a low-cardinality failure class for telemetry.
func telemetryFailureClass(statusCode: Int?, error: Error?) -> String? {
    if let error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .cannotFindHost, .dnsLookupFailed:
                return "dns"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "tls"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dataNotAllowed:
                return "connection"
            default:
                return "unknown"
            }
        }
        return "unknown"
    }
    guard let statusCode else { return nil }
    return (200...399).contains(statusCode) ? nil : "http_\(statusCode)"
}
