import Foundation
import CoreFoundation

public enum SimulaAPIEnvironment: Hashable, Sendable {
    case production
    case staging

    private static let productionBaseURL = "https://simula-api-701226639755.us-central1.run.app"

    var baseURLString: String {
        switch self {
        case .production:
            return Self.productionBaseURL
        case .staging:
            #if SIMULA_DEV_ARTIFACT
            return "https://simula-api-staging-701226639755.us-central1.run.app"
            #else
            // Stable artifacts do not contain or expose a staging endpoint.
            return Self.productionBaseURL
            #endif
        }
    }

    var sendsIPv4Beacon: Bool { self == .production }
}

struct SimulaArtifactEnvironmentPolicy: Equatable, Sendable {
    static let stagingInfoPlistKey = "SimulaStagingEnvironmentEnabled"

    let allowsStaging: Bool
    let stagingOptInEnabled: Bool

    static let current = SimulaArtifactEnvironmentPolicy(
        allowsStaging: {
            #if SIMULA_DEV_ARTIFACT
            return true
            #else
            return false
            #endif
        }(),
        stagingOptInEnabled: isEnabled(
            infoDictionaryValue: Bundle.main.object(forInfoDictionaryKey: stagingInfoPlistKey)
        )
    )

    static func isEnabled(infoDictionaryValue: Any?) -> Bool {
        guard let number = infoDictionaryValue as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

    var defaultEnvironment: SimulaAPIEnvironment {
        allowsStaging && stagingOptInEnabled ? .staging : .production
    }
}

/// The first SDK request freezes the host-configured backend for the process.
final class ProcessAPIEnvironmentSelection: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: SimulaArtifactEnvironmentPolicy
    private var selected: SimulaAPIEnvironment?

    init(policy: SimulaArtifactEnvironmentPolicy = .current) {
        self.policy = policy
    }

    func configure(_ requested: SimulaAPIEnvironment) -> Bool {
        guard requested == .production || policy.defaultEnvironment == .staging else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let selected else {
            self.selected = requested
            return true
        }
        return selected == requested
    }

    func environmentForRequest() -> SimulaAPIEnvironment {
        lock.lock()
        defer { lock.unlock() }
        guard let selected else {
            let environment = policy.defaultEnvironment
            self.selected = environment
            return environment
        }
        return selected
    }

    var resolvedEnvironment: SimulaAPIEnvironment {
        lock.lock(); defer { lock.unlock() }
        return selected ?? .production
    }

    var effectiveEnvironment: SimulaAPIEnvironment? {
        lock.lock(); defer { lock.unlock() }
        return selected
    }

}

enum SimulaEnvironmentStorageNames {
    static func beaconFileName(for environment: SimulaAPIEnvironment) -> String {
        environment == .production ? "pending_beacons.json" : "pending_beacons_staging.json"
    }

    static func beaconLegacyKey(for environment: SimulaAPIEnvironment) -> String {
        environment == .production ? "simula_pending_beacons" : "simula_pending_beacons_staging"
    }

    static func rewardFileName(for environment: SimulaAPIEnvironment) -> String {
        environment == .production
            ? "pending_reward_verifications.json"
            : "pending_reward_verifications_staging.json"
    }

    static func rewardLegacyKey(for environment: SimulaAPIEnvironment) -> String {
        environment == .production
            ? "simula_pending_reward_verifications"
            : "simula_pending_reward_verifications_staging"
    }

    static func telemetryKey(for environment: SimulaAPIEnvironment) -> String {
        environment == .production
            ? "simula_pending_telemetry_events"
            : "simula_pending_telemetry_events_staging"
    }

    static func crashFileName(for environment: SimulaAPIEnvironment) -> String {
        environment == .production ? "pending_crashes.txt" : "pending_crashes_staging.txt"
    }

    static func sdkLastVersionKey(for environment: SimulaAPIEnvironment) -> String {
        environment == .production ? "simula_sdk_last_version" : "simula_sdk_last_version_staging"
    }
}

let processAPIEnvironmentSelection = ProcessAPIEnvironmentSelection()
