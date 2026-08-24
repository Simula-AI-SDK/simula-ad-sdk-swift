import Foundation

enum ProcessApiKeyClaim: Equatable, Sendable {
    case owner
    case compatible
    case incompatible(effectiveApiKey: String)

    var isCompatible: Bool {
        switch self {
        case .owner, .compatible: return true
        case .incompatible: return false
        }
    }
}

/// Lock-only process ownership for the API key shared by telemetry, sessions, ads, and beacons.
/// The first valid SDK entry point wins; later matching entry points may share that ownership.
final class ProcessApiKeyOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var apiKey: String?

    func claim(_ candidate: String) -> ProcessApiKeyClaim {
        lock.lock()
        defer { lock.unlock() }
        guard let apiKey else {
            self.apiKey = candidate
            return .owner
        }
        return apiKey == candidate ? .compatible : .incompatible(effectiveApiKey: apiKey)
    }

    var effectiveApiKey: String? {
        lock.lock(); defer { lock.unlock() }
        return apiKey
    }
}

func claimProcessApiKeyIfValid(
    _ apiKey: String,
    ownership: ProcessApiKeyOwnership,
    reportInvalid: (String) -> Void
) -> Bool {
    do {
        try validateSimulaProviderProps(apiKey: apiKey)
    } catch {
        reportInvalid(error.localizedDescription)
        return false
    }
    return ownership.claim(apiKey).isCompatible
}

let processApiKeyOwnership = ProcessApiKeyOwnership()
