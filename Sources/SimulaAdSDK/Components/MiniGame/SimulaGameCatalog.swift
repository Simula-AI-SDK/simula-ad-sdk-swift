import Foundation
import SwiftUI

/// Cancels catalog work without creating Swift concurrency tasks in host-compiled bridges.
public final class SimulaCatalogRequest {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) { self.task = task }
    public func cancel() { task.cancel() }
}

/// An immutable catalog environment, independent of the host's process-wide ad session.
@MainActor
public final class SimulaGameCatalog {
    private let api: SimulaAPI
    private let apiKey: String
    private let primaryUserID: String?
    private var sessionTask: Task<String?, Error>?
    private var sessionPrivacy: ConsentSnapshot?
    private var sessionGeneration = 0
    private var privacySnapshot: @MainActor () -> ConsentSnapshot = { SimulaPrivacy.shared.currentSnapshot }
    private var startup: @MainActor () async -> Void = { await SimulaGameCatalog.awaitHostStartup() }

    init(
        api: SimulaAPI, apiKey: String, primaryUserID: String? = nil,
        privacySnapshot: (@MainActor () -> ConsentSnapshot)? = nil,
        startup: (@MainActor () async -> Void)? = nil
    ) {
        self.api = api
        self.apiKey = apiKey
        self.primaryUserID = primaryUserID
        if let privacySnapshot { self.privacySnapshot = privacySnapshot }
        if let startup { self.startup = startup }
    }

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

    private static func awaitHostStartup() async {
        if let provider = SimulaAds.shared { _ = await provider.ensureSession() }
    }

    /// Completion-based entry point for host toolchains; all async work stays in the SDK binary.
    @discardableResult
    public func fetch(completion: @escaping @MainActor (Result<CatalogResponse, Error>) -> Void) -> SimulaCatalogRequest {
        SimulaCatalogRequest(task: Task { await completeFetch(completion) })
    }

    private func completeFetch(_ completion: @escaping @MainActor (Result<CatalogResponse, Error>) -> Void) async {
        do {
            let result = try await fetch()
            try Task.checkCancellation()
            completion(.success(result))
        } catch { completion(.failure(error)) }
    }

    @discardableResult
    public func load(
        menuId: String, gameId: String, companionEnabled: Bool? = nil,
        width: CGFloat, height: CGFloat,
        charId: String, charName: String, charImage: String, charDesc: String? = nil,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) -> SimulaCatalogRequest {
        SimulaCatalogRequest(task: Task {
            await completeLoad(
                menuId: menuId, gameId: gameId, companionEnabled: companionEnabled,
                width: width, height: height, charId: charId, charName: charName,
                charImage: charImage, charDesc: charDesc, completion: completion
            )
        })
    }

    private func completeLoad(
        menuId: String, gameId: String, companionEnabled: Bool?, width: CGFloat, height: CGFloat,
        charId: String, charName: String, charImage: String, charDesc: String?,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) async {
        do {
            let url = try await load(
                menuId: menuId, gameId: gameId, companionEnabled: companionEnabled,
                width: width, height: height, charId: charId, charName: charName,
                charImage: charImage, charDesc: charDesc
            )
            try Task.checkCancellation()
            completion(.success(url))
        } catch { completion(.failure(error)) }
    }

    /// Initializes the exact game; menu-expiry recovery and presentation belong to the caller.
    public func load(
        menuId: String, gameId: String, companionEnabled: Bool? = nil,
        width: CGFloat, height: CGFloat,
        charId: String, charName: String, charImage: String, charDesc: String? = nil
    ) async throws -> String {
        // Reuse the canonical startup gate before reading consent for this session.
        await startup()
        try Task.checkCancellation()
        let privacy = privacySnapshot()
        if sessionPrivacy.map({ classifyPrivacyChange(from: $0, to: privacy).requiresSessionResync }) ?? true {
            sessionTask = nil
        }
        sessionPrivacy = privacy
        if sessionTask == nil {
            sessionGeneration += 1
            let api = self.api
            let apiKey = self.apiKey
            let primaryUserID = privacy.allowsPrimaryUserID ? self.primaryUserID : nil
            sessionTask = Task {
                try await api.createSession(
                    apiKey: apiKey, primaryUserID: primaryUserID, privacy: privacy,
                    applyTelemetryConfig: false
                )
            }
        }
        let generation = sessionGeneration
        let session: String?
        do { session = try await sessionTask?.value }
        catch {
            if generation == sessionGeneration { sessionTask = nil }
            throw error
        }
        do {
            // An in-flight session for older consent must never initialize a game.
            guard generation == sessionGeneration,
                  !classifyPrivacyChange(from: privacy, to: privacySnapshot()).requiresSessionResync else { throw CancellationError() }
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
            if generation == sessionGeneration {
                if case SimulaAPIError.httpError(statusCode: 401) = error { sessionTask = nil }
                if case SimulaAPIError.invalidApiKey = error { sessionTask = nil }
            }
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
        GameIframeView(
            gameId: "catalog", charID: "", charName: "", charImage: "",
            onClose: onClose, preparedIframeUrl: iframeUrl
        )
    }
}
