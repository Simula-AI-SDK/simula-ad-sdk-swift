import Foundation

// MARK: - SimulaValidationError

/// Errors thrown during provider configuration validation (translates `validation.ts`)
public enum SimulaValidationError: LocalizedError, Sendable {
    case missingApiKey
    case emptyApiKey
    case invalidDevModeType
    case invalidPrimaryUserIDType
    case invalidPrivacyConsentType

    public var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "SimulaProvider requires a valid \"apiKey\" (non-empty string)"
        case .emptyApiKey:
            return "SimulaProvider \"apiKey\" cannot be an empty string"
        case .invalidDevModeType:
            return "Invalid \"devMode\" type. Must be a boolean"
        case .invalidPrimaryUserIDType:
            return "Invalid \"primaryUserID\" type. Must be a string"
        case .invalidPrivacyConsentType:
            return "Invalid \"hasPrivacyConsent\" type. Must be a boolean"
        }
    }
}

// MARK: - validateSimulaProviderProps

/// Validates the configuration passed to SimulaProvider.
/// In Swift, most type checks are handled at compile time. This validates runtime constraints.
/// Translates `validateSimulaProviderProps` from validation.ts
public func validateSimulaProviderProps(apiKey: String) throws {
    guard !apiKey.isEmpty else {
        throw SimulaValidationError.emptyApiKey
    }
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SimulaValidationError.emptyApiKey
    }
}
