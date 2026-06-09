import Foundation

/// Outcome of one telemetry batch POST, mirroring the reward-verification drop/retry policy.
enum TelemetryAck {
    /// 2xx — events accepted; drop them from the buffer.
    case accepted
    /// Permanent client error (4xx except 408/429) — retrying won't help; drop them.
    case drop
    /// Transient (5xx / 408 / 429 / connectivity) — keep and retry with backoff.
    case retry
}

/// Sends one encoded batch. Abstracted so the manager can be tested without the network.
protocol TelemetrySending: Sendable {
    func send(_ body: Data) async -> TelemetryAck
}

/// Production sender: posts to `POST /v1/telemetry/events` via `SimulaAPI`, reusing its
/// auth + consent headers. The request is **not** self-instrumented (the URLSession
/// telemetry delegate skips the `/v1/telemetry` path — recursion guard).
final class ApiTelemetrySender: TelemetrySending {
    private let apiKey: String
    private let api: SimulaAPI

    init(apiKey: String, api: SimulaAPI = SimulaAPI()) {
        self.apiKey = apiKey
        self.api = api
    }

    func send(_ body: Data) async -> TelemetryAck {
        let code = await api.postTelemetry(apiKey: apiKey, body: body)
        switch code {
        case 200...299:
            return .accepted
        case 400...499 where code != 408 && code != 429:
            return .drop
        default:
            return .retry // -1 (connectivity), 5xx, 408, 429
        }
    }
}
