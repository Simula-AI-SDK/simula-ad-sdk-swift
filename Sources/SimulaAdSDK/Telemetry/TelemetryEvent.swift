import Foundation

// MARK: - Event type discriminators (the wire `type` field)

enum TelemetryType {
    static let network = "network"
    static let operation = "operation"
    static let lifecycle = "ad_lifecycle"
    static let error = "error"
    static let meta = "meta"
}

// MARK: - TelemetryEvent

/// A single telemetry datum. One flat, optional-field shape covers every `type` so the
/// batch is a homogeneous JSON array the backend can stream-parse on the `type`
/// discriminator (mirrors the existing best-effort tracking payloads, which also use
/// loosely-typed bodies, and the Kotlin SDK's `TelemetryEvent`).
///
/// `durationMs` is measured with a **monotonic** clock by the caller; `timestamp` is
/// wall-clock epoch **milliseconds** (matching the Kotlin SDK). Never put PII in
/// `name`/`message` — see `TelemetryManager`
/// for sanitization + consent rules. `count` aggregates repeated errors of the same
/// signature. `eventId` is a per-event idempotency key (also used internally to remove
/// flushed events without positional races).
struct TelemetryEvent: Codable, Equatable, Sendable {
    let type: String
    let name: String
    let eventId: String
    let timestamp: Double
    var durationMs: Int?
    var statusCode: Int?
    var responseBytes: Int64?
    var requestBytes: Int64?
    var failureClass: String?
    var success: Bool?
    var adFormat: String?
    var adUnitId: String?
    var adId: String?
    var serveId: String?
    var errorCode: String?
    var message: String?
    var breadcrumb: String?
    var cacheHit: Bool?
    var retryCount: Int?
    /// Occurrence count for a deduped error signature (mutable so repeats aggregate in place).
    var count: Int?

    enum CodingKeys: String, CodingKey {
        case type, name
        case eventId = "event_id"
        case timestamp
        case durationMs = "duration_ms"
        case statusCode = "status_code"
        case responseBytes = "response_bytes"
        case requestBytes = "request_bytes"
        case failureClass = "failure_class"
        case success
        case adFormat = "ad_format"
        case adUnitId = "ad_unit_id"
        case adId = "ad_id"
        case serveId = "serve_id"
        case errorCode = "error_code"
        case message, breadcrumb
        case cacheHit = "cache_hit"
        case retryCount = "retry_count"
        case count
    }

    init(type: String, name: String, eventId: String, timestamp: Double) {
        self.type = type
        self.name = name
        self.eventId = eventId
        self.timestamp = timestamp
    }
}

// MARK: - TelemetryEnvelope

/// The batch wrapper: per-process/device context sent once, plus the `events` array.
/// Built fresh on each flush so the latest `sessionId` / consent-gated PII is attached.
struct TelemetryEnvelope: Codable {
    let sdkVersion: String
    let platform: String
    let osVersion: String
    let deviceModel: String
    let hostAppId: String
    let devMode: Bool
    var sessionId: String?
    // Consent-gated: only populated when the resolved ConsentSnapshot allows.
    var primaryUserId: String?
    var advertisingId: String?
    let events: [TelemetryEvent]

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case platform
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case hostAppId = "host_app_id"
        case devMode = "dev_mode"
        case sessionId = "session_id"
        case primaryUserId = "primary_user_id"
        case advertisingId = "advertising_id"
        case events
    }
}
