import Foundation

enum SimulaAPIEnvironment: Hashable, Sendable {
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
    let allowsStaging: Bool

    static let current = SimulaArtifactEnvironmentPolicy(
        allowsStaging: {
            #if SIMULA_DEV_ARTIFACT
            return true
            #else
            return false
            #endif
        }()
    )

    func environment(devMode: Bool) -> SimulaAPIEnvironment {
        devMode && allowsStaging ? .staging : .production
    }
}

struct ProcessAPIEnvironmentClaim: Equatable, Sendable {
    let requested: SimulaAPIEnvironment
    let effective: SimulaAPIEnvironment

    var isCompatible: Bool { requested == effective }
}

/// The first SDK entry or direct API request freezes one backend for the process. Later entries
/// targeting another backend become inert instead of mixing sessions, queues, or telemetry.
final class ProcessAPIEnvironmentSelection: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: SimulaArtifactEnvironmentPolicy
    private var selected: SimulaAPIEnvironment?

    init(policy: SimulaArtifactEnvironmentPolicy = .current) {
        self.policy = policy
    }

    func claim(devMode: Bool) -> ProcessAPIEnvironmentClaim {
        claim(policy.environment(devMode: devMode))
    }

    func environmentForRequest() -> SimulaAPIEnvironment {
        claim(.production).effective
    }

    var effectiveEnvironment: SimulaAPIEnvironment? {
        lock.lock(); defer { lock.unlock() }
        return selected
    }

    private func claim(_ requested: SimulaAPIEnvironment) -> ProcessAPIEnvironmentClaim {
        lock.lock()
        defer { lock.unlock() }
        guard let selected else {
            self.selected = requested
            return ProcessAPIEnvironmentClaim(requested: requested, effective: requested)
        }
        return ProcessAPIEnvironmentClaim(requested: requested, effective: selected)
    }
}

func claimProcessAPIEnvironmentIfValid(
    apiKey: String,
    devMode: Bool,
    selection: ProcessAPIEnvironmentSelection,
    reportInvalid: (String) -> Void
) -> ProcessAPIEnvironmentClaim? {
    do {
        try validateSimulaProviderProps(apiKey: apiKey)
    } catch {
        reportInvalid(error.localizedDescription)
        return nil
    }
    return selection.claim(devMode: devMode)
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
