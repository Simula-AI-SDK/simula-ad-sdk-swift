import Foundation

/// Persists the telemetry buffer so events — especially errors — survive process death.
/// Abstracted (like the reward-verification queue's persistence) so the engine can be
/// unit-tested with an isolated `UserDefaults`.
protocol TelemetryStoring: Sendable {
    func load() -> [TelemetryEvent]
    func save(_ events: [TelemetryEvent])
}

/// Real store: a single `UserDefaults` entry holding the JSON-encoded buffer.
final class UserDefaultsTelemetryStore: TelemetryStoring, @unchecked Sendable {
    private let key = "simula_pending_telemetry_events"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [TelemetryEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TelemetryEvent].self, from: data)) ?? []
    }

    func save(_ events: [TelemetryEvent]) {
        if events.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
        }
    }
}
