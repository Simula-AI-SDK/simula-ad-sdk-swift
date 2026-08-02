import Foundation

let maxExtraParameterEntries = 10
let maxExtraParameterKeyLength = 64
let maxExtraParameterValueLength = 256

private let extraParametersWarning =
    "[SimulaSDK] Some extraParameters entries were ignored because they are invalid or exceed SDK limits."

func warnInvalidExtraParameters() {
    print(extraParametersWarning)
}

/// Returns a bounded wire snapshot. Invalid publisher input is ignored rather than failing an ad load.
func normalizeExtraParameters(
    _ parameters: [String: String],
    warn: () -> Void = warnInvalidExtraParameters
) -> [String: String]? {
    let valid = parameters
        .filter { key, value in
            key.unicodeScalars.count <= maxExtraParameterKeyLength &&
                value.unicodeScalars.count <= maxExtraParameterValueLength &&
                !key.hasPrefix("$") &&
                !key.contains(".")
        }
        .sorted { $0.key < $1.key }

    if valid.count != parameters.count || valid.count > maxExtraParameterEntries {
        warn()
    }
    guard !valid.isEmpty else { return nil }
    return Dictionary(uniqueKeysWithValues: valid.prefix(maxExtraParameterEntries).map { ($0.key, $0.value) })
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
