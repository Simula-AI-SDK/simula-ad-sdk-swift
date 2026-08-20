import Foundation

/// Pure token ownership used by the process-wide fullscreen presentation registry.
struct FullscreenPresentationOwnership<Token: Hashable> {
    private var activeTokens: Set<Token> = []

    var isPrewarmEligible: Bool { activeTokens.isEmpty }

    @discardableResult
    mutating func claim(_ token: Token) -> Bool {
        activeTokens.insert(token).inserted
    }

    @discardableResult
    mutating func release(_ token: Token) -> Bool {
        activeTokens.remove(token) != nil
    }
}

/// Pure two-phase completion state for the primary-to-fallback window handoff.
struct FullscreenPresentationLeaseCompletion {
    private var primaryTeardownFinished = false
    private var postCloseTeardownFinished = false
    private var releaseIssued = false

    mutating func finishPrimaryTeardown() -> Bool {
        primaryTeardownFinished = true
        return issueReleaseIfFinished()
    }

    mutating func finishPostCloseTeardown() -> Bool {
        postCloseTeardownFinished = true
        return issueReleaseIfFinished()
    }

    private mutating func issueReleaseIfFinished() -> Bool {
        guard primaryTeardownFinished, postCloseTeardownFinished, !releaseIssued else { return false }
        releaseIssued = true
        return true
    }
}

/// One process-wide view of SDK interstitial and rewarded presentation activity.
@MainActor
final class FullscreenPresentationRegistry {
    static let shared = FullscreenPresentationRegistry()

    private var ownership = FullscreenPresentationOwnership<UUID>()

    private init() {}

    func claim() -> FullscreenPresentationLease {
        let token = UUID()
        ownership.claim(token)
        return FullscreenPresentationLease(token: token, registry: self)
    }

    /// Keeps the final eligibility check and speculative allocation in one main-actor turn.
    func prewarmIfEligible(_ prewarm: () -> Void) {
        guard ownership.isPrewarmEligible else { return }
        prewarm()
    }

    fileprivate func release(_ token: UUID) {
        ownership.release(token)
    }
}

/// Presentation-scoped ownership. A stale or repeated finish can only release this lease's token.
@MainActor
final class FullscreenPresentationLease {
    private let token: UUID
    private weak var registry: FullscreenPresentationRegistry?
    private var completion = FullscreenPresentationLeaseCompletion()

    fileprivate init(token: UUID, registry: FullscreenPresentationRegistry) {
        self.token = token
        self.registry = registry
    }

    func finishPrimaryTeardown() {
        if completion.finishPrimaryTeardown() { release() }
    }

    func finishPostCloseTeardown() {
        if completion.finishPostCloseTeardown() { release() }
    }

    /// Used when no presentation window was launched.
    func releaseAfterPresentationFailure() {
        release()
    }

    private func release() {
        registry?.release(token)
        registry = nil
    }
}
