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
    /// Monotonic elapsed time since the process's first SDK initialization entry point.
    var timeSinceInitMs: Int?
    var statusCode: Int?
    var responseBytes: Int64?
    var requestBytes: Int64?
    var failureClass: String?
    var success: Bool?
    var adFormat: String?
    var adUnitId: String?
    var adId: String?
    var serveId: String?
    var interactionId: String?
    var clickSource: String?
    var errorCode: String?
    var message: String?
    var breadcrumb: String?
    /// Symbolicated SDK frames for crash/exit errors (structured, alongside the compacted message).
    var stack: [String]?
    var cacheHit: Bool?
    var retryCount: Int?
    /// Store-exit click type for store_opened/returned/abandoned: cta | store_prompt | auto_redirect.
    var trigger: String?
    /// Native load source for load_success: preload | cache | network.
    var cacheSource: String?
    /// Wall-clock staleness, stamped at flush time = clock() - timestamp. Detects offline/queued events.
    var eventAgeMs: Int?
    /// Occurrence count for a deduped error signature (mutable so repeats aggregate in place).
    var count: Int?
    /// Effective performance sampling rate when this event entered the buffer.
    var sampleRate: Double?

    enum CodingKeys: String, CodingKey {
        case type, name
        case eventId = "event_id"
        case timestamp
        case durationMs = "duration_ms"
        case timeSinceInitMs = "time_since_init_ms"
        case statusCode = "status_code"
        case responseBytes = "response_bytes"
        case requestBytes = "request_bytes"
        case failureClass = "failure_class"
        case success
        case adFormat = "ad_format"
        case adUnitId = "ad_unit_id"
        case adId = "ad_id"
        case serveId = "serve_id"
        case interactionId = "interaction_id"
        case clickSource = "click_source"
        case errorCode = "error_code"
        case message, breadcrumb, stack
        case cacheHit = "cache_hit"
        case retryCount = "retry_count"
        case trigger
        case cacheSource = "cache_source"
        case eventAgeMs = "event_age_ms"
        case count
        case sampleRate = "sample_rate"
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
    // Resolved at flush time: wifi | cellular | none | unknown. Best-effort; never blocks.
    var connectionType: String?
    // Experiment assignment for per-variant conversion analysis (server-driven). Session-scoped.
    var experimentId: String?
    var variantId: String?
    // Device/network diagnostics — always-on (like device_model/connection_type), not consent-gated.
    // Statics resolved at init; battery/carrier resolved best-effort at flush. Any field may be nil.
    var manufacturer: String?
    var locale: String?
    var deviceRamMb: Int?
    var batteryLevel: Double?
    var batteryCharging: Bool?
    var carrier: String?
    var radio: String?
    var buildType: String?
    /// Effective server-controlled performance sampling rate when every event in this batch shares
    /// one rate. Nil for mixed-rate batches; each event remains individually stamped.
    var sampleRate: Double?
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
        case connectionType = "connection_type"
        case experimentId = "experiment_id"
        case variantId = "variant_id"
        case manufacturer, locale
        case deviceRamMb = "device_ram_mb"
        case batteryLevel = "battery_level"
        case batteryCharging = "battery_charging"
        case carrier, radio
        case buildType = "build_type"
        case sampleRate = "sample_rate"
        case events
    }
}
