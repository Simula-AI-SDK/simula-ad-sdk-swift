import Foundation

let maxExtraParameterEntries = 10
let maxExtraParameterKeyLength = 64
let maxExtraParameterValueLength = 256

private final class ExtraParametersWarningState: @unchecked Sendable {
    static let shared = ExtraParametersWarningState()

    private let lock = NSLock()
    private var didLog = false
    private var didRecordTelemetry = false

    func claimLog() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !didLog else { return false }
        didLog = true
        return true
    }

    func claimTelemetry() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !didRecordTelemetry else { return false }
        didRecordTelemetry = true
        return true
    }
}

func warnInvalidExtraParametersLocally() {
    guard ExtraParametersWarningState.shared.claimLog() else { return }
    print("[SimulaAdSDK] Invalid or excess publisher metadata was ignored. Keys must be non-empty, at most 64 characters, and contain neither '.' nor a leading '$'; values are limited to 256 characters and each impression accepts at most 10 entries.")
}

func warnInvalidExtraParameters() {
    warnInvalidExtraParametersLocally()
    guard ExtraParametersWarningState.shared.claimTelemetry() else { return }
    Telemetry.shared.recordOperation(
        name: "extra_parameters_invalid",
        durationMs: 0,
        success: false,
        failureClass: "invalid_or_over_limit"
    )
}

/// Returns a bounded wire snapshot. Invalid publisher input is ignored rather than failing an ad load.
func normalizeExtraParameters(
    _ parameters: [String: String],
    warn: () -> Void = warnInvalidExtraParameters
) -> [String: String]? {
    let valid = parameters
        .filter { key, value in
            !key.isEmpty &&
                key.unicodeScalars.count <= maxExtraParameterKeyLength &&
                value.unicodeScalars.count <= maxExtraParameterValueLength &&
                !key.hasPrefix("$") &&
                !key.contains(".")
        }
        .sorted { utf16LexicographicallyPrecedes($0.key, $1.key) }

    if valid.count != parameters.count || valid.count > maxExtraParameterEntries {
        warn()
    }
    guard !valid.isEmpty else { return nil }
    return Dictionary(uniqueKeysWithValues: valid.prefix(maxExtraParameterEntries).map { ($0.key, $0.value) })
}

/// Merges duplicate impression metadata with incoming keys taking priority, including when the
/// combined set exceeds the wire cap. Both inputs are normalized so legacy persisted values remain
/// safe to send.
func mergeExtraParameters(
    existing: [String: String]?,
    newest: [String: String],
    warn: () -> Void = warnInvalidExtraParameters
) -> [String: String]? {
    var shouldWarn = false
    let incoming = normalizeExtraParameters(newest, warn: { shouldWarn = true }) ?? [:]
    let prior = normalizeExtraParameters(existing ?? [:], warn: { shouldWarn = true }) ?? [:]
    var merged = incoming

    for key in prior.keys.sorted(by: utf16LexicographicallyPrecedes) where merged[key] == nil {
        guard merged.count < maxExtraParameterEntries else {
            shouldWarn = true
            break
        }
        merged[key] = prior[key]
    }
    if shouldWarn { warn() }
    return merged.isEmpty ? nil : merged
}

/// Matches Kotlin `String.compareTo` and JavaScript `Array.sort` for deterministic wire capping.
private func utf16LexicographicallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
}

/// Main-actor-owned configuration used by imperative full-screen ad instances.
final class ExtraParametersStore {
    private var parameters: [String: String] = [:]
    private let warn: () -> Void

    init(warn: @escaping () -> Void = warnInvalidExtraParameters) {
        self.warn = warn
    }

    func set(key: String, value: String) {
        guard let entry = normalizeExtraParameters([key: value], warn: warn) else { return }
        if parameters[key] == nil, parameters.count >= maxExtraParameterEntries {
            warn()
            return
        }
        parameters[key] = entry[key]
    }

    func replace(with replacement: [String: String]) {
        parameters = normalizeExtraParameters(replacement, warn: warn) ?? [:]
    }

    func snapshot() -> [String: String]? {
        parameters.isEmpty ? nil : parameters
    }
}
