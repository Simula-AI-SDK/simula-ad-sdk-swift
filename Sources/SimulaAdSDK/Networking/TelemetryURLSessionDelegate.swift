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

        guard let url = task.originalRequest?.url else { return }
        // Recursion guard: never record the telemetry delivery request itself.
        if url.path.hasPrefix("/v1/telemetry") { return }
        // Never record the ppid-update request — its path embeds the PPID (consent-gated PII).
        if url.path.contains("/ppid/") { return }

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
            path: url.path,
            method: method,
            statusCode: status,
            durationMs: durationMs,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            failureClass: telemetryFailureClass(statusCode: status, error: error)
        )
    }
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
