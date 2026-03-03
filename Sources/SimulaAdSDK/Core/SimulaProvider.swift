import Foundation
import SwiftUI
import Combine

// MARK: - SimulaProvider

/// The central state manager for the Simula Ad SDK.
/// Translates the React Context pattern from SimulaProvider.tsx.
///
/// Usage:
/// ```swift
/// SimulaProviderView(apiKey: "your-key") {
///     ContentView()
/// }
/// ```
///
/// Inside child views:
/// ```swift
/// @EnvironmentObject var simula: SimulaProvider
/// ```
public final class SimulaProvider: ObservableObject {
    // MARK: - Configuration (set once at init)

    /// The API key for authenticating with Simula services
    public let apiKey: String

    /// Whether the SDK is in development mode
    public let devMode: Bool

    /// Optional primary user identifier
    public let primaryUserID: String?

    /// Privacy consent flag. When false, suppresses collection of PII.
    public let hasPrivacyConsent: Bool

    // MARK: - Session State

    /// The server session ID, set after successful session creation
    @Published public private(set) var sessionId: String?

    // MARK: - Ad Caching Infrastructure (matching Flutter/React SDK)

    /// Cache of fetched ads keyed by "slot:position"
    private var adCache: [String: AdData] = [:]

    /// Cache of measured heights keyed by "slot:position"
    private var heightCache: [String: CGFloat] = [:]

    /// Set of "slot:position" keys that returned no-fill
    private var noFillSet: Set<String> = []

    // MARK: - Internal

    private let api: SimulaAPI

    // MARK: - Init

    public init(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true
    ) {
        // Validate at init (matches React's validateSimulaProviderProps call)
        do {
            try validateSimulaProviderProps(apiKey: apiKey)
        } catch {
            // In React, this throws and prevents render. In Swift, we assert in debug.
            assertionFailure("[SimulaSDK] \(error.localizedDescription)")
        }

        self.apiKey = apiKey
        self.devMode = devMode
        self.primaryUserID = primaryUserID
        self.hasPrivacyConsent = hasPrivacyConsent
        self.api = SimulaAPI()
    }

    // MARK: - Session Management

    /// Creates a session with the server. Called automatically by `SimulaProviderView`.
    /// Translates the `useEffect(() => { ensureSession() }, [...])` from SimulaProvider.tsx.
    @MainActor
    public func createSession() async {
        let effectiveUserID = hasPrivacyConsent ? primaryUserID : nil
        do {
            let id = try await api.createSession(
                apiKey: apiKey,
                devMode: devMode,
                primaryUserID: effectiveUserID
            )
            if let id = id {
                self.sessionId = id
            }
        } catch {
            print("[SimulaSDK] Failed to create session: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Key Helper

    /// Creates a cache key from slot and position (translates `getCacheKey` from SimulaProvider.tsx)
    private func cacheKey(slot: String, position: Int) -> String {
        "\(slot):\(position)"
    }

    // MARK: - Ad Cache Methods

    /// Get cached ad for a slot/position (translates `getCachedAd`)
    public func getCachedAd(slot: String, position: Int) -> AdData? {
        adCache[cacheKey(slot: slot, position: position)]
    }

    /// Cache an ad for a slot/position (translates `cacheAd`)
    public func cacheAd(slot: String, position: Int, ad: AdData) {
        adCache[cacheKey(slot: slot, position: position)] = ad
    }

    /// Get cached height for a slot/position (translates `getCachedHeight`)
    public func getCachedHeight(slot: String, position: Int) -> CGFloat? {
        heightCache[cacheKey(slot: slot, position: position)]
    }

    /// Cache height for a slot/position (translates `cacheHeight`)
    public func cacheHeight(slot: String, position: Int, height: CGFloat) {
        heightCache[cacheKey(slot: slot, position: position)] = height
    }

    /// Check if a slot/position has no fill (translates `hasNoFill`)
    public func hasNoFill(slot: String, position: Int) -> Bool {
        noFillSet.contains(cacheKey(slot: slot, position: position))
    }

    /// Mark a slot/position as having no fill (translates `markNoFill`)
    public func markNoFill(slot: String, position: Int) {
        noFillSet.insert(cacheKey(slot: slot, position: position))
    }
}

// MARK: - SimulaProviderView

/// A SwiftUI wrapper view that provides `SimulaProvider` to its children via EnvironmentObject.
/// This is the direct equivalent of `<SimulaProvider apiKey="...">` in React.
///
/// Usage:
/// ```swift
/// SimulaProviderView(apiKey: "your-api-key", devMode: true) {
///     MyAppContent()
/// }
/// ```
public struct SimulaProviderView<Content: View>: View {
    @StateObject private var provider: SimulaProvider
    private let content: () -> Content

    public init(
        apiKey: String,
        devMode: Bool = false,
        primaryUserID: String? = nil,
        hasPrivacyConsent: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._provider = StateObject(wrappedValue: SimulaProvider(
            apiKey: apiKey,
            devMode: devMode,
            primaryUserID: primaryUserID,
            hasPrivacyConsent: hasPrivacyConsent
        ))
        self.content = content
    }

    public var body: some View {
        content()
            .environmentObject(provider)
            .task {
                await provider.createSession()
            }
    }
}
