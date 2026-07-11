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
/// Completion-based (not `async`) on purpose: the flush engine runs on GCD so its launch-time
/// work never touches the Swift Concurrency task allocator — see the concurrency note in
/// `TelemetryManager` and .cursor/skills/swift-concurrency-task-shape/SKILL.md. The completion
/// may be invoked on any thread/queue; the manager re-hops onto its own serial queue.
protocol TelemetrySending: Sendable {
    func send(_ body: Data, completion: @escaping @Sendable (TelemetryAck) -> Void)
}

/// Production sender: posts to `POST /telemetry/events` via `SimulaAPI`, reusing its
/// auth + consent headers. The request is **not** self-instrumented (the URLSession
/// telemetry delegate skips the `/telemetry` path — recursion guard).
final class ApiTelemetrySender: TelemetrySending {
    private let apiKey: String
    private let api: SimulaAPI

    init(apiKey: String, api: SimulaAPI = SimulaAPI()) {
        self.apiKey = apiKey
        self.api = api
    }

    func send(_ body: Data, completion: @escaping @Sendable (TelemetryAck) -> Void) {
        api.postTelemetry(apiKey: apiKey, body: body) { code in
            switch code {
            case 200...299:
                completion(.accepted)
            case 400...499 where code != 408 && code != 429:
                completion(.drop)
            default:
                completion(.retry) // -1 (connectivity), 5xx, 408, 429
            }
        }
    }
}
