import Foundation
import SwiftUI

/// An immutable catalog environment, independent of the host's process-wide ad session.
@MainActor
public final class SimulaGameCatalog {
    private let api: SimulaAPI
    private let apiKey: String
    private let primaryUserID: String?
    private var sessionTask: Task<String?, Error>?

    /// Staging requires a development artifact and the host's explicit capability.
    public init?(apiKey: String, environment: SimulaAPIEnvironment, primaryUserID: String?) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              environment == .production || SimulaArtifactEnvironmentPolicy.current.defaultEnvironment == .staging else { return nil }
        self.api = SimulaAPI(environment: environment)
        self.apiKey = apiKey
        self.primaryUserID = primaryUserID
    }

    public func fetch() async throws -> CatalogResponse {
        try await api.fetchCatalog()
    }

    /// Initializes the exact game; menu-expiry recovery and presentation belong to the caller.
    public func load(
        menuId: String, gameId: String, companionEnabled: Bool? = nil,
        width: CGFloat, height: CGFloat,
        charId: String, charName: String, charImage: String, charDesc: String? = nil
    ) async throws -> String {
        // Reuse the canonical startup gate before reading consent for this session.
        if let provider = SimulaAds.shared { _ = await provider.ensureSession() }
        try Task.checkCancellation()
        if sessionTask == nil {
            let api = self.api
            let apiKey = self.apiKey
            let primaryUserID = self.primaryUserID
            let privacy = SimulaPrivacy.shared.currentSnapshot
            sessionTask = Task {
                try await api.createSession(
                    apiKey: apiKey, primaryUserID: primaryUserID, privacy: privacy,
                    applyTelemetryConfig: false
                )
            }
        }
        let session: String?
        do { session = try await sessionTask?.value }
        catch { sessionTask = nil; throw error }
        do {
            guard let sid = session, !sid.isEmpty else {
                sessionTask = nil
                throw SimulaAPIError.invalidResponse
            }
            try Task.checkCancellation()
            let result = try await api.getMinigame(InitMinigameRequest(
                gameType: gameId, sessionId: sid, currencyMode: false, w: width, h: height,
                charId: charId, charName: charName, charImage: charImage, charDesc: charDesc,
                delegateChar: true, menuId: menuId
            ), companionEnabled: companionEnabled)
            guard URL(string: result.iframeUrl)?.scheme == "https" else { throw SimulaAPIError.invalidResponse }
            return result.iframeUrl
        } catch {
            if case SimulaAPIError.httpError(statusCode: 401) = error { sessionTask = nil }
            if case SimulaAPIError.invalidApiKey = error { sessionTask = nil }
            throw error
        }
    }
}

/// The native player for a URL returned by `SimulaGameCatalog.load`.
public struct CatalogGamePlayer: View {
    private let iframeUrl: String
    private let onClose: () -> Void

    public init(iframeUrl: String, onClose: @escaping () -> Void) {
        self.iframeUrl = iframeUrl
        self.onClose = onClose
    }

    public var body: some View {
        if let provider = SimulaAds.shared {
            GameIframeView(
                gameId: "catalog", charID: "", charName: "", charImage: "",
                onClose: onClose, preparedIframeUrl: iframeUrl
            ).environmentObject(provider)
        }
    }
}
