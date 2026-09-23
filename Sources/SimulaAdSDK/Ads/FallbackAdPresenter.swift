import Foundation

enum FallbackOutcome: Equatable, Sendable {
    case completed
    case noContent
    case loadingTimeout
    case fetchFailure
    case presentationUnavailable
    case hostUnavailable

    var unavailableReason: String? {
        switch self {
        case .completed: return nil
        case .noContent: return "no_content"
        case .loadingTimeout: return "loading_timeout"
        case .fetchFailure: return "fetch_failure"
        case .presentationUnavailable: return "presentation_unavailable"
        case .hostUnavailable: return "host_unavailable"
        }
    }

    /// Fallback delivery is best-effort. Once the playable earned a reward, infrastructure/content
    /// unavailability must not revoke it; this keeps that policy explicit at the decision point.
    func shouldVerifyEarnedReward(_ earned: Bool) -> Bool { earned }

    var videoPlanCloseReason: String? {
        switch self {
        case .completed: return nil
        case .noContent: return FullscreenVideoTerminationReason.noNextStep
        case .loadingTimeout: return FullscreenVideoTerminationReason.nextStepTimeout
        case .fetchFailure, .presentationUnavailable, .hostUnavailable:
            return FullscreenVideoTerminationReason.nextStepFailed
        }
    }
}

enum FallbackVideoReadiness: Equatable, Sendable {
    case mount
    case prepare
}

func fallbackVideoReadiness(isVideo: Bool, hasPreparedPlayer: Bool) -> FallbackVideoReadiness {
    isVideo && !hasPreparedPlayer ? .prepare : .mount
}

struct FallbackTelemetryIdentifiers: Equatable, Sendable {
    let adId: String
    let serveId: String?

    static func rewarded(impressionId: String) -> FallbackTelemetryIdentifiers {
        FallbackTelemetryIdentifiers(adId: impressionId, serveId: nil)
    }

    static func interstitial(impressionId: String) -> FallbackTelemetryIdentifiers {
        FallbackTelemetryIdentifiers(adId: impressionId, serveId: impressionId)
    }
}

enum FallbackFetchStatus: Equatable, Sendable {
    case content
    case noContent
    case failure
}

enum FallbackFetchResult: Sendable {
    case content([FallbackAd], preparedVideos: [Int: FullscreenVideoPreparationToken])
    case noContent
    case failure

    var status: FallbackFetchStatus {
        switch self {
        case .content: return .content
        case .noContent: return .noContent
        case .failure: return .failure
        }
    }
}

let fallbackFetchMaximumAttempts = 2
let fallbackFetchRetryDelay: TimeInterval = 0.25

func fetchFallbackAdsWithRetry(
    fetch: @escaping @Sendable () async throws -> [FallbackAd],
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
    }
) async throws -> [FallbackAd] {
    for attempt in 1...fallbackFetchMaximumAttempts {
        try Task.checkCancellation()
        do {
            return try await fetch()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard attempt < fallbackFetchMaximumAttempts else { throw error }
            try await sleep(fallbackFetchRetryDelay)
        }
    }
    throw SimulaAPIError.invalidResponse
}

@MainActor
final class FallbackPrefetchOwnership {
    private(set) var consumedByLoadingPresenter = false

    func transferToLoadingPresenter(windowInstalled: Bool) {
        guard windowInstalled else { return }
        consumedByLoadingPresenter = true
    }
}

/// Owns exactly one fallback video resource across repeated view construction. A prepared token is
/// released only after a successful claim; failed claims discard only inactive preparation before
/// falling back to a cold resource.
@MainActor
final class FallbackVideoOwnership<Resource: AnyObject, Token> {
    private(set) var resource: Resource?
    private var cleanup: (() -> Void)?

    init(
        token: Token?,
        claim: (Token) -> Resource?,
        discardUnclaimed: (Token) -> Void,
        makeCold: () -> Resource,
        releaseClaimed: @escaping (Token) -> Void,
        stopCold: @escaping (Resource) -> Void
    ) {
        if let token, let claimed = claim(token) {
            resource = claimed
            cleanup = {
                withExtendedLifetime(claimed) {
                    releaseClaimed(token)
                }
            }
        } else {
            if let token { discardUnclaimed(token) }
            let cold = makeCold()
            resource = cold
            cleanup = { stopCold(cold) }
        }
    }

    func release() {
        guard let cleanup else { return }
        self.cleanup = nil
        resource = nil
        cleanup()
    }

    deinit {
        guard let cleanup else { return }
        DispatchQueue.main.async {
            cleanup()
        }
    }
}

func retainedFallbackVideoResource<Resource: AnyObject>(
    requestedIndex: Int,
    ownershipIndex: Int?,
    resource: Resource?
) -> Resource? {
    requestedIndex == ownershipIndex ? resource : nil
}

func allowsV2FallbackPreparation(
    primaryUsesVideoPlanV2: Bool,
    primaryV2VideoStarted: Bool
) -> Bool {
    !primaryUsesVideoPlanV2 || primaryV2VideoStarted
}

func upcomingFallbackVideoIndices(
    _ ads: [FallbackAd],
    allowV2Preparation: Bool = true
) -> [Int] {
    let usesVideoPlanV2 = ads.contains(where: \.usesVideoPlanV2Contract)
    if usesVideoPlanV2 {
        guard allowV2Preparation else { return [] }
        return ads.indices.first(where: { ads[$0].usesVideoPlanV2 }).map { [$0] } ?? []
    }
    return ads.indices.prefix(2).filter {
        if case .video = ads[$0].creativeContent { return true }
        return false
    }
}

func nextV2FallbackVideoIndex(in ads: [FallbackAd], after currentIndex: Int) -> Int? {
    guard ads.indices.contains(currentIndex), ads[currentIndex].usesVideoPlanV2 else { return nil }
    return ads.indices.dropFirst(currentIndex + 1).first { ads[$0].usesVideoPlanV2 }
}

func discardedFallbackVideoPreparationIndices(
    in ads: [FallbackAd],
    around currentIndex: Int,
    preparedIndices: Set<Int>
) -> [Int] {
    let retainedIndices: Set<Int>
    if ads.contains(where: \.usesVideoPlanV2Contract) {
        let nextPreparedVideo = preparedIndices
            .filter { $0 >= currentIndex && ads.indices.contains($0) && ads[$0].usesVideoPlanV2 }
            .min()
        retainedIndices = nextPreparedVideo.map { Set([$0]) } ?? []
    } else {
        retainedIndices = Set([currentIndex, currentIndex + 1])
    }
    return preparedIndices.subtracting(retainedIndices).sorted()
}

func boundedFallbackVideoPreparationIndices(
    in ads: [FallbackAd],
    around currentIndex: Int,
    preparedIndices: Set<Int>
) -> Set<Int> {
    let eligible = [currentIndex, currentIndex + 1].filter { index in
        ads.indices.contains(index) && ads[index].mediaType == .video
    }
    return preparedIndices.intersection(eligible.prefix(2))
}

#if os(iOS)
@MainActor
func prepareUpcomingFallbackVideos(
    _ ads: [FallbackAd],
    allowV2Preparation: Bool = true
) async -> [Int: FullscreenVideoPreparationToken] {
    var prepared: [Int: FullscreenVideoPreparationToken] = [:]
    let indices = upcomingFallbackVideoIndices(ads, allowV2Preparation: allowV2Preparation)
    for index in indices {
        if let token = await prepareFallbackVideo(ads[index]) { prepared[index] = token }
    }
    return prepared
}

@MainActor
func prepareFallbackVideo(_ ad: FallbackAd) async -> FullscreenVideoPreparationToken? {
    guard case .video(let remoteURL, let posterURL) = ad.creativeContent else { return nil }
    let lease: VideoAssetLease
    do { lease = try await VideoAssetCache.shared.acquire(remoteURL) }
    catch { return nil }
    guard !Task.isCancelled else {
        lease.release()
        return nil
    }
    let token = FullscreenVideoPreparationPool.shared.prepare(
        url: lease.localURL,
        posterURL: posterURL,
        startsMuted: !ad.usesVideoPlanV2,
        stallTimeout: ad.usesVideoPlanV2
            ? FullscreenVideoPlayer.videoPlanV2StallTimeout
            : FullscreenVideoPlayer.preparationTimeout,
        assetLease: lease
    )
    if token == nil { lease.release() }
    return token
}

@MainActor
func preparingImmediateV2FallbackIfNeeded(_ result: FallbackFetchResult) -> FallbackFetchResult {
    // ES1 video follows a playable primary and is prepared during the initial fallback fetch.
    result
}

@MainActor
func prepareUpcomingFallbackVideos(
    _ ads: [FallbackAd],
    allowV2Preparation: Bool = true,
    prepare: (URL, URL?) -> FullscreenVideoPreparationToken?
) -> [Int: FullscreenVideoPreparationToken] {
    var prepared: [Int: FullscreenVideoPreparationToken] = [:]
    for index in upcomingFallbackVideoIndices(ads, allowV2Preparation: allowV2Preparation) {
        let ad = ads[index]
        guard case .video(let url, let posterURL) = ad.creativeContent else { continue }
        prepared[index] = prepare(url, posterURL)
    }
    return prepared
}

@MainActor
func releasePreparedFallbackVideos(in result: FallbackFetchResult?) {
    guard case .content(_, let preparedVideos) = result else { return }
    discardPreparedFallbackVideos(preparedVideos)
}

@MainActor
func discardPreparedFallbackVideos(
    _ preparedVideos: [Int: FullscreenVideoPreparationToken]
) {
    discardPreparedFallbackVideos(preparedVideos) {
        FullscreenVideoPreparationPool.shared.discardPrepared($0)
    }
}

@MainActor
func discardPreparedFallbackVideos(
    _ preparedVideos: [Int: FullscreenVideoPreparationToken],
    discard: (FullscreenVideoPreparationToken) -> Void
) {
    preparedVideos.values.forEach(discard)
}

@MainActor
func acceptPreparedFallbackContent(
    ads: [FallbackAd],
    preparedVideos: [Int: FullscreenVideoPreparationToken]
) -> Bool {
    acceptPreparedFallbackContent(
        ads: ads,
        preparedVideos: preparedVideos,
        discard: { FullscreenVideoPreparationPool.shared.discardPrepared($0) }
    )
}

@MainActor
func acceptPreparedFallbackContent(
    ads: [FallbackAd],
    preparedVideos: [Int: FullscreenVideoPreparationToken],
    discard: (FullscreenVideoPreparationToken) -> Void
) -> Bool {
    guard !ads.isEmpty else {
        discardPreparedFallbackVideos(preparedVideos, discard: discard)
        return false
    }
    return true
}

@MainActor
func makeFallbackVideoOwnership(
    url: URL,
    posterURL: URL?,
    token: FullscreenVideoPreparationToken?,
    startsMuted: Bool = true,
    stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout
) -> FallbackVideoOwnership<FullscreenVideoPlayer, FullscreenVideoPreparationToken> {
    makeFallbackVideoOwnership(
        url: url,
        posterURL: posterURL,
        token: token,
        startsMuted: startsMuted,
        stallTimeout: stallTimeout,
        pool: FullscreenVideoPreparationPool.shared,
        makePlayer: {
            FullscreenVideoPlayer(
                url: $0,
                posterURL: $1,
                startsMuted: startsMuted,
                stallTimeout: stallTimeout
            )
        }
    )
}

@MainActor
func makeFallbackVideoOwnership(
    url: URL,
    posterURL: URL?,
    token: FullscreenVideoPreparationToken?,
    startsMuted: Bool = true,
    stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout,
    pool: FullscreenVideoPreparationPool,
    makePlayer: (URL, URL?) -> FullscreenVideoPlayer
) -> FallbackVideoOwnership<FullscreenVideoPlayer, FullscreenVideoPreparationToken> {
    FallbackVideoOwnership(
        token: token,
        claim: {
            pool.claim(
                $0,
                url: url,
                posterURL: posterURL,
                startsMuted: startsMuted,
                stallTimeout: stallTimeout
            )
        },
        discardUnclaimed: { pool.discardPrepared($0) },
        makeCold: { makePlayer(url, posterURL) },
        releaseClaimed: { pool.release($0) },
        stopCold: { $0.stop() }
    )
}
#endif

enum FallbackLoadingResolution: Equatable, Sendable {
    case presentContent
    case finish(FallbackOutcome)
    case stale
}

func canAdvanceFallback(renderedIndex: Int, currentIndex: Int, clickHandoffIndex: Int?) -> Bool {
    renderedIndex == currentIndex && clickHandoffIndex != renderedIndex
}

func canHandleFallbackScreenCallback(renderedIndex: Int, currentIndex: Int) -> Bool {
    renderedIndex == currentIndex
}

enum FallbackCreativeFailureResolution: Equatable, Sendable {
    case ignore
    case advance
    case finishUnavailable
}

enum FallbackLoadingSurface: Equatable, Sendable {
    case initialFetch(generation: Int)
    case videoPreparation(index: Int, generation: UUID)
}

enum FallbackLoadingSkipResolution: Equatable, Sendable {
    case cancelInitialFetch
    case resolveVideoPreparationFailure(FallbackCreativeFailureResolution)
    case stale
}

func fallbackLoadingSkipResolution(
    surface: FallbackLoadingSurface,
    activeInitialFetchGeneration: Int?,
    currentIndex: Int,
    currentVideoPreparationGeneration: UUID?,
    screenCount: Int
) -> FallbackLoadingSkipResolution {
    switch surface {
    case .initialFetch(let generation):
        return activeInitialFetchGeneration == generation ? .cancelInitialFetch : .stale
    case .videoPreparation(let renderedIndex, let generation):
        guard renderedIndex == currentIndex,
              currentVideoPreparationGeneration == generation else { return .stale }
        return .resolveVideoPreparationFailure(fallbackCreativeFailureResolution(
            renderedIndex: renderedIndex,
            currentIndex: currentIndex,
            screenCount: screenCount
        ))
    }
}

func fallbackCreativeFailureResolution(
    renderedIndex: Int,
    currentIndex: Int,
    screenCount: Int
) -> FallbackCreativeFailureResolution {
    guard renderedIndex == currentIndex, screenCount > 0,
          (0..<screenCount).contains(currentIndex) else { return .ignore }
    return currentIndex + 1 < screenCount ? .advance : .finishUnavailable
}

struct FallbackTerminalAdvanceState: Equatable, Sendable {
    private(set) var pendingIndex: Int?

    mutating func request(index: Int, blocked: Bool) -> Bool {
        if blocked {
            pendingIndex = index
            return false
        }
        pendingIndex = nil
        return true
    }

    mutating func blockersDidClear(currentIndex: Int) -> Int? {
        guard pendingIndex == currentIndex else { return nil }
        pendingIndex = nil
        return currentIndex
    }

    mutating func clear() {
        pendingIndex = nil
    }
}

/// Pure one-presentation state machine. Generation ownership makes a timeout and a late fetch
/// mutually exclusive, while terminal transitions return an outcome only once.
struct FallbackPresentationCoordinator: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case loading(Int)
        case presenting(Int)
        case terminal(FallbackOutcome)
    }

    private(set) var generation = 0
    private(set) var phase = Phase.idle

    mutating func beginLoading() -> Int {
        generation += 1
        phase = .loading(generation)
        return generation
    }

    mutating func beginPresenting() -> Int {
        generation += 1
        phase = .presenting(generation)
        return generation
    }

    mutating func resolveLoading(
        generation expectedGeneration: Int,
        status: FallbackFetchStatus
    ) -> FallbackLoadingResolution {
        guard phase == .loading(expectedGeneration) else { return .stale }
        switch status {
        case .content:
            phase = .presenting(expectedGeneration)
            return .presentContent
        case .noContent:
            phase = .terminal(.noContent)
            return .finish(.noContent)
        case .failure:
            phase = .terminal(.fetchFailure)
            return .finish(.fetchFailure)
        }
    }

    mutating func loadingTimedOut(generation expectedGeneration: Int) -> FallbackOutcome? {
        guard phase == .loading(expectedGeneration) else { return nil }
        phase = .terminal(.loadingTimeout)
        return .loadingTimeout
    }

    mutating func completedPresentedContent() -> FallbackOutcome? {
        guard case .presenting = phase else { return nil }
        phase = .terminal(.completed)
        return .completed
    }

    mutating func presentationUnavailable() -> FallbackOutcome? {
        guard case .terminal = phase else {
            phase = .terminal(.presentationUnavailable)
            return .presentationUnavailable
        }
        return nil
    }
}

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - FallbackAdPresenter

/// Presents the post-close fallback ad screens (`AdOverlayView`) full-screen in a dedicated
/// `UIWindow`, mirroring the declarative minigame's post-game ad flow. Used by
/// `SimulaInterstitialAd` and `SimulaRewardedAd` after the primary creative is dismissed: the host
/// fetches the serve's fallback screens (`GET /load/fallbacks/{impressionId}`) and shows them here,
/// one per close tap, in reveal order.
///
/// The window is hosted above `.normal` (independent of the host's view-controller stack), the
/// same pattern as `InterstitialPresenter`. `onFinish` reports exactly why the window ended.
@MainActor
final class FallbackAdPresenter {
    private static let loadingDeadlineNanos: UInt64 = 2_000_000_000
    private static let videoPreparationDeadlineNanos: UInt64 = 10_000_000_000
    private var window: UIWindow?
    /// One opaque host survives loading and every screen swap. Replacing its root view lets SwiftUI
    /// dismantle the previous representable before creating the next one, so only one fallback
    /// WebView is owned at a time.
    private var hostingController: UIHostingController<AnyView>?
    private var onFinish: ((FallbackOutcome) -> Void)?
    private var presentationLease: FullscreenPresentationLease?
    private var ads: [FallbackAd] = []
    private var index = 0
    /// The host's key window, captured before we take key. Restored on dismiss so the host
    /// regains touch/keyboard focus.
    private weak var originalKeyWindow: UIWindow?
    /// Deliberate self-retention while the window is on screen. The end screens must survive
    /// their owning ad object: a host can release the ad mid-unit (e.g. React Native's
    /// `destroy()` on unmount, or an error handler reacting to the auto-preload's LOAD_FAILED —
    /// which lands exactly while an end screen is up), and since UIKit does not retain windows,
    /// dropping the last reference to this presenter would deallocate the window and skip the
    /// remaining screens (and, on the rewarded flow, the close/verification that follows them).
    /// Set on a successful `present`, released in `dismiss` (the only teardown path).
    private var retainedWhilePresenting: FallbackAdPresenter?

    /// auto_store_redirect END_SCREEN_N shares one route lifecycle with the current fallback WebView.
    private var autoStoreRedirect: AutoStoreRedirect?
    private var currentRouteLifecycle: AttributionRouteLifecycle?
    /// Fired when a user taps an end-screen CTA — surfaces the publisher click on the parent ad.
    private var onAdClick: ((ClickInteraction) -> Void)?
    private var onFallbackGateOpened: ((Bool) -> Void)?
    /// The primary serve's CTA routing context, threaded into each end screen's WebView so its CTA
    /// opens deterministically (in-app store sheet from the raw `ios_store_url` + background tracker
    /// fire) instead of resolving the tracker's redirect chain. Defaults keep today's behavior.
    private var ctaTrackingUrl: String?
    private var ctaDestination: AdDestination = .appstore
    private var ctaStoreOpen: StoreOpen = .skstoreproduct
    private var ctaStoreUrl: String?
    private var attribution: AdAttribution?
    private var telemetryAdFormat = "interstitial"
    private var telemetryAdUnitId: String?
    private var telemetryServeId: String?
    private var loadingDeadlineTask: Task<Void, Never>?
    private var onLoadingTimeout: (() -> Void)?
    private var isLoading = false
    private var presentationCoordinator = FallbackPresentationCoordinator()
    private var loadingGeneration: Int?
    private var clickHandoffIndex: Int?
    private var presentationBlockedIndex: Int?
    private var terminalAdvanceState = FallbackTerminalAdvanceState()
    private var terminalFailureIndex: Int?
    private var videoPlanScope: VideoPlanPresentationScope?
    /// Retain only process-pooled preparation tokens for the current and immediately-next fallback.
    private var videoPreparations: [Int: FullscreenVideoPreparationToken] = [:]
    private var videoOwnershipIndex: Int?
    private var videoOwnership: FallbackVideoOwnership<
        FullscreenVideoPlayer,
        FullscreenVideoPreparationToken
    >?
    private var videoPreparationTasks: [Int: Task<Void, Never>] = [:]
    private var videoPreparationGenerations: [Int: UUID] = [:]
    private var currentVideoPreparationDeadlineTask: Task<Void, Never>?

    /// Presents the fallback ad screens in order. Returns `true` if they were presented; `false`
    /// when `ads` is empty or no window scene was available (`onFinish` is then never called).
    @discardableResult
    func present(
        ads: [FallbackAd],
        preparedVideos: [Int: FullscreenVideoPreparationToken] = [:],
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        onFallbackGateOpened: ((Bool) -> Void)? = nil,
        telemetryAdFormat: String = "interstitial",
        telemetryAdUnitId: String? = nil,
        telemetryServeId: String? = nil,
        videoPlanScope: VideoPlanPresentationScope? = nil,
        presentationLease: FullscreenPresentationLease,
        onFinish: @escaping (FallbackOutcome) -> Void
    ) -> Bool {
        guard acceptPreparedFallbackContent(ads: ads, preparedVideos: preparedVideos) else { return false }
        videoPreparations = boundedPreparedVideos(preparedVideos, ads: ads, around: 0)
        _ = presentationCoordinator.beginPresenting()
        let didPresent = beginPresentation(
            ads: ads,
            startsLoading: false,
            originalKeyWindow: originalKeyWindow,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            onAdClick: onAdClick,
            onFallbackGateOpened: onFallbackGateOpened,
            telemetryAdFormat: telemetryAdFormat,
            telemetryAdUnitId: telemetryAdUnitId,
            telemetryServeId: telemetryServeId,
            videoPlanScope: videoPlanScope,
            presentationLease: presentationLease,
            onFinish: onFinish
        )
        if !didPresent {
            videoPreparations.values.forEach { FullscreenVideoPreparationPool.shared.release($0) }
            videoPreparations.removeAll()
        }
        return didPresent
    }

    /// Installs an SDK-owned opaque fallback window synchronously while fallback prefetch is still
    /// in flight. The same window and hosting controller are reused when `resolveLoading` supplies
    /// the screens, preventing the primary presenter from exposing the host app during handoff.
    func presentLoading(
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String? = nil,
        ctaDestination: AdDestination = .appstore,
        ctaStoreOpen: StoreOpen = .skstoreproduct,
        ctaStoreUrl: String? = nil,
        attribution: AdAttribution? = nil,
        autoStoreRedirect: AutoStoreRedirect? = nil,
        onAdClick: ((ClickInteraction) -> Void)? = nil,
        onFallbackGateOpened: ((Bool) -> Void)? = nil,
        telemetryAdFormat: String = "interstitial",
        telemetryAdUnitId: String? = nil,
        telemetryServeId: String? = nil,
        videoPlanScope: VideoPlanPresentationScope? = nil,
        onLoadingTimeout: @escaping () -> Void,
        presentationLease: FullscreenPresentationLease,
        onFinish: @escaping (FallbackOutcome) -> Void
    ) -> Int? {
        let generation = presentationCoordinator.beginLoading()
        loadingGeneration = generation
        let didPresent = beginPresentation(
            ads: [],
            startsLoading: true,
            originalKeyWindow: originalKeyWindow,
            ctaTrackingUrl: ctaTrackingUrl,
            ctaDestination: ctaDestination,
            ctaStoreOpen: ctaStoreOpen,
            ctaStoreUrl: ctaStoreUrl,
            attribution: attribution,
            autoStoreRedirect: autoStoreRedirect,
            onAdClick: onAdClick,
            onFallbackGateOpened: onFallbackGateOpened,
            telemetryAdFormat: telemetryAdFormat,
            telemetryAdUnitId: telemetryAdUnitId,
            telemetryServeId: telemetryServeId,
            videoPlanScope: videoPlanScope,
            presentationLease: presentationLease,
            onFinish: onFinish
        )
        guard didPresent else {
            loadingGeneration = nil
            return nil
        }
        self.onLoadingTimeout = onLoadingTimeout
        loadingDeadlineTask = Task { [weak self] in await self?.runLoadingDeadline(generation: generation) }
        return generation
    }

    private func runLoadingDeadline(generation: Int) async {
        do { try await Task.sleep(nanoseconds: Self.loadingDeadlineNanos) } catch { return }
        guard !Task.isCancelled else { return }
        loadingDidTimeout(generation: generation)
    }

    private func beginPresentation(
        ads: [FallbackAd],
        startsLoading: Bool,
        originalKeyWindow: UIWindow?,
        ctaTrackingUrl: String?,
        ctaDestination: AdDestination,
        ctaStoreOpen: StoreOpen,
        ctaStoreUrl: String?,
        attribution: AdAttribution?,
        autoStoreRedirect: AutoStoreRedirect?,
        onAdClick: ((ClickInteraction) -> Void)?,
        onFallbackGateOpened: ((Bool) -> Void)?,
        telemetryAdFormat: String,
        telemetryAdUnitId: String?,
        telemetryServeId: String?,
        videoPlanScope: VideoPlanPresentationScope?,
        presentationLease: FullscreenPresentationLease,
        onFinish: @escaping (FallbackOutcome) -> Void
    ) -> Bool {
        guard window == nil,
              let scene = preferredForegroundActiveWindowScene(
                  originating: originalKeyWindow?.windowScene
              ) else { return false }
        self.ads = ads
        self.index = 0
        prepareVideoPlayers(around: 0)
        self.onFinish = onFinish
        self.ctaTrackingUrl = ctaTrackingUrl
        self.ctaDestination = ctaDestination
        self.ctaStoreOpen = ctaStoreOpen
        self.ctaStoreUrl = ctaStoreUrl
        self.attribution = attribution
        self.autoStoreRedirect = autoStoreRedirect
        self.onAdClick = onAdClick
        self.onFallbackGateOpened = onFallbackGateOpened
        self.telemetryAdFormat = telemetryAdFormat
        self.telemetryAdUnitId = telemetryAdUnitId
        self.telemetryServeId = telemetryServeId
        self.videoPlanScope = videoPlanScope
            ?? (ads.contains(where: \.usesVideoPlanV2Contract) ? VideoPlanPresentationScope() : nil)
        self.presentationLease = presentationLease
        isLoading = startsLoading
        if !startsLoading { loadingGeneration = nil }

        self.originalKeyWindow = originalKeyWindow

        let loadingSurface = loadingGeneration.map(FallbackLoadingSurface.initialFetch)
        let hosting = UIHostingController(rootView: loadingView(surface: loadingSurface))
        hosting.view.backgroundColor = .black
        hosting.view.isOpaque = true

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        // Opaque black (not clear) so the host app never shows through — both behind the
        // end screen's safe area and during the rootViewController swap between screens.
        window.backgroundColor = .black
        window.rootViewController = hosting
        self.window = window
        hostingController = hosting
        if !startsLoading { installCurrentScreen(initialOriginatingScene: scene) }
        window.makeKeyAndVisible()
        retainedWhilePresenting = self
        // Hide the status bar in hosts that opted out of VC-based appearance (e.g. React Native),
        // where `.hideStatusBar` in the end-screen view is a no-op. No-op in native hosts.
        SimulaAppStatusBar.hide()
        return true
    }

    /// Replaces the native loading surface with End Screen 1, or safely tears down when the
    /// best-effort prefetch returned no usable screens. The presenter self-retains across the await.
    func resolveLoading(with result: FallbackFetchResult, generation: Int) {
        guard window != nil, isLoading else {
            releasePreparedFallbackVideos(in: result)
            return
        }
        let resolution = presentationCoordinator.resolveLoading(
            generation: generation,
            status: result.status
        )
        guard resolution != .stale else {
            releasePreparedFallbackVideos(in: result)
            return
        }
        loadingDeadlineTask?.cancel()
        loadingDeadlineTask = nil
        onLoadingTimeout = nil
        loadingGeneration = nil
        isLoading = false
        switch resolution {
        case .presentContent:
            guard case .content(let ads, let preparedVideos) = result,
                  acceptPreparedFallbackContent(ads: ads, preparedVideos: preparedVideos) else {
                dismiss(outcome: .noContent)
                return
            }
            self.ads = ads
            if videoPlanScope == nil, ads.contains(where: \.usesVideoPlanV2Contract) {
                videoPlanScope = VideoPlanPresentationScope()
            }
            videoPreparations = boundedPreparedVideos(preparedVideos, ads: ads, around: 0)
            index = 0
            installCurrentScreen()
        case .finish(let outcome):
            dismiss(outcome: outcome)
        case .stale:
            break
        }
    }

    private func loadingDidTimeout(generation: Int) {
        guard window != nil, isLoading,
              let outcome = presentationCoordinator.loadingTimedOut(generation: generation) else { return }
        isLoading = false
        loadingGeneration = nil
        loadingDeadlineTask = nil
        let timeout = onLoadingTimeout
        onLoadingTimeout = nil
        timeout?()
        dismiss(outcome: outcome)
    }

    /// END_SCREEN_N: open the primary ad's store once, when the fallback screen whose index matches
    /// the configured trigger is presented (index 0 = END SCREEN 1, index 1 = END SCREEN 2).
    private func fireAutoStoreRedirectIfMatching(
        renderedIndex: Int,
        sourceIndex: Int,
        lifecycle: AttributionRouteLifecycle
    ) {
        guard let redirect = autoStoreRedirect, redirect.enabled,
              let trigger = AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: sourceIndex),
              redirect.trigger == trigger, window != nil, self.index == renderedIndex else { return }
        lifecycle.automaticRoutes.requestAutomaticRoute(scope: lifecycle.automaticRouteScope) {
            let execution = AttributionRouteExecution(
                originatingScene: self.window?.windowScene,
                isActive: {
                    self.window != nil
                        && self.index == renderedIndex
                        && UIApplication.shared.applicationState == .active
                },
                onOutcome: { outcome in
                    recordAttributionRoute(outcome: outcome, source: .autoRedirect)
                }
            )
            CreativeCTARouter.open(
                trackingUrl: self.ctaTrackingUrl,
                destination: self.ctaDestination,
                storeOpen: self.ctaStoreOpen,
                storeUrl: self.ctaStoreUrl,
                attribution: self.attribution,
                execution: execution
            )
        }
    }

    /// `.id` gives each screen fresh overlay state while the opaque host itself stays installed.
    private func adView(at index: Int, initialOriginatingScene: UIWindowScene? = nil) -> AnyView {
        guard ads.indices.contains(index) else { return loadingView(surface: nil) }
        let ad = ads[index]
        let isFinalScreen = index == ads.indices.last
        let videoRoute = ad.mediaType == .video ? fallbackVideoCTARoute(
            ad: ad,
            parentTrackingUrl: ctaTrackingUrl,
            parentDestination: ctaDestination,
            parentStoreOpen: ctaStoreOpen,
            parentStoreUrl: ctaStoreUrl,
            allowsParentFallback: true
        ) : nil
        let usesVideoRoute = ad.mediaType == .video
        currentRouteLifecycle?.deactivate()
        let routeLifecycle = AttributionRouteLifecycle()
        currentRouteLifecycle = routeLifecycle
        return AnyView(AdOverlayView(
            ad: ad,
            onClose: { [weak self] in self?.advance(from: index) },
            onCreativeFailure: { [weak self] in self?.failCreativeAfterTerminal(from: index) },
            onVideoCompleted: ad.usesVideoPlanV2
                ? { [weak self] in self?.advanceAfterTerminal(from: index) }
                : nil,
            onVideoStarted: ad.usesVideoPlanV2
                ? { [weak self] in self?.prepareImmediateNextVideo(after: index) }
                : nil,
            onGateOpened: onFallbackGateOpened.map { callback in
                { callback(isFinalScreen) }
            },
            videoPlayer: retainedVideoPlayer(at: index),
            videoPlanScope: videoPlanScope,
            initialOriginatingScene: initialOriginatingScene ?? window?.windowScene,
            expectsVideoPlanNextStep: index + 1 < ads.count,
            adId: ad.adId,
            nativeClickBeaconV1Enabled: ad.usesVideoPlanV2Contract || ad.nativeClickBeaconV1Enabled,
            closeBehavior: ad.closeBehavior,
            telemetryAdFormat: telemetryAdFormat,
            telemetryAdUnitId: telemetryAdUnitId,
            telemetryServeId: telemetryServeId,
            onAdClick: { [weak self] interaction in self?.onAdClick?(interaction) },
            onClickHandoffPendingChanged: { [weak self] pending in
                guard let self, self.index == index else { return }
                if pending {
                    self.clickHandoffIndex = index
                } else if self.clickHandoffIndex == index {
                    self.clickHandoffIndex = nil
                    self.completePendingTerminalAdvanceIfPossible(at: index)
                }
            },
            onPresentationBlockedChanged: { [weak self] blocked in
                guard let self, self.index == index else { return }
                if blocked {
                    self.presentationBlockedIndex = index
                } else if self.presentationBlockedIndex == index {
                    self.presentationBlockedIndex = nil
                    self.completePendingTerminalAdvanceIfPossible(at: index)
                }
            },
            ctaTrackingUrl: usesVideoRoute ? videoRoute?.trackingUrl : ctaTrackingUrl,
            ctaDestination: usesVideoRoute ? (videoRoute?.destination ?? .appstore) : ctaDestination,
            ctaStoreOpen: usesVideoRoute ? (videoRoute?.storeOpen ?? .skstoreproduct) : ctaStoreOpen,
            ctaStoreUrl: usesVideoRoute ? videoRoute?.storeUrl : ctaStoreUrl,
            attribution: usesVideoRoute && videoRoute?.source != .parent ? nil : attribution,
            routeLifecycle: routeLifecycle,
            onScreenMounted: { [weak self] in
                guard let self, canHandleFallbackScreenCallback(
                    renderedIndex: index,
                    currentIndex: self.index
                ) else { return false }
                self.prepareImmediateNextVideo(after: index)
                self.fireAutoStoreRedirectIfMatching(
                    renderedIndex: index,
                    sourceIndex: ad.sourceIndex,
                    lifecycle: routeLifecycle
                )
                return true
            }
        ).id(index))
    }

    private func loadingView(surface: FallbackLoadingSurface?) -> AnyView {
        AnyView(
            ZStack {
                Color.black
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                if let surface {
                    Button(action: { [weak self] in self?.cancelLoadingSurface(surface: surface) }) {
                        Text("Skip")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .ignoresSafeArea()
        )
    }

    private func cancelLoadingSurface(surface: FallbackLoadingSurface) {
        guard window != nil else { return }
        switch fallbackLoadingSkipResolution(
            surface: surface,
            activeInitialFetchGeneration: isLoading ? loadingGeneration : nil,
            currentIndex: index,
            currentVideoPreparationGeneration: videoPreparationGenerations[index],
            screenCount: ads.count
        ) {
        case .cancelInitialFetch:
            guard let outcome = presentationCoordinator.presentationUnavailable() else { return }
            let cancelFetch = onLoadingTimeout
            onLoadingTimeout = nil
            cancelFetch?()
            dismiss(outcome: outcome)
        case .resolveVideoPreparationFailure(.advance),
             .resolveVideoPreparationFailure(.finishUnavailable):
            let failedIndex = index
            releaseVideoPreparation(at: failedIndex)
            failCreativeAfterTerminal(from: failedIndex)
        case .resolveVideoPreparationFailure(.ignore):
            return
        case .stale:
            return
        }
    }

    /// Reveal the next screen on each close tap; tear down after the last one.
    private func advance(from renderedIndex: Int) {
        guard window != nil,
              canAdvanceFallback(
                renderedIndex: renderedIndex,
                currentIndex: index,
                clickHandoffIndex: clickHandoffIndex
              ) else { return }
        clickHandoffIndex = nil
        presentationBlockedIndex = nil
        terminalAdvanceState.clear()
        releaseVideoPreparation(at: index)
        index += 1
        if index < ads.count {
            installCurrentScreen()
        } else {
            guard let outcome = presentationCoordinator.completedPresentedContent() else { return }
            dismiss(outcome: outcome)
        }
    }

    private func advanceAfterTerminal(from renderedIndex: Int) {
        guard window != nil, renderedIndex == index else { return }
        terminalFailureIndex = nil
        guard terminalAdvanceState.request(
            index: renderedIndex,
            blocked: clickHandoffIndex == renderedIndex || presentationBlockedIndex == renderedIndex
        ) else { return }
        clickHandoffIndex = nil
        advance(from: renderedIndex)
    }

    private func failCreativeAfterTerminal(from renderedIndex: Int) {
        guard window != nil, renderedIndex == index else { return }
        terminalFailureIndex = renderedIndex
        guard terminalAdvanceState.request(
            index: renderedIndex,
            blocked: clickHandoffIndex == renderedIndex || presentationBlockedIndex == renderedIndex
        ) else { return }
        resolveCreativeFailure(from: renderedIndex)
    }

    private func resolveCreativeFailure(from renderedIndex: Int) {
        terminalFailureIndex = nil
        switch fallbackCreativeFailureResolution(
            renderedIndex: renderedIndex,
            currentIndex: index,
            screenCount: ads.count
        ) {
        case .ignore:
            return
        case .advance:
            clickHandoffIndex = nil
            advance(from: renderedIndex)
        case .finishUnavailable:
            guard let outcome = presentationCoordinator.presentationUnavailable() else { return }
            dismiss(outcome: outcome)
        }
    }

    private func completePendingTerminalAdvanceIfPossible(at renderedIndex: Int) {
        guard clickHandoffIndex != renderedIndex,
              presentationBlockedIndex != renderedIndex,
              let pendingIndex = terminalAdvanceState.blockersDidClear(currentIndex: renderedIndex) else { return }
        if terminalFailureIndex == pendingIndex {
            resolveCreativeFailure(from: pendingIndex)
        } else {
            advance(from: pendingIndex)
        }
    }

    private func prepareVideoPlayers(around currentIndex: Int) {
        let retained = Set([currentIndex, currentIndex + 1])
        let discardedIndices = videoPreparations.keys.filter { !retained.contains($0) }
        for playerIndex in discardedIndices {
            releaseVideoPreparation(at: playerIndex)
        }
        for playerIndex in videoPreparationTasks.keys.filter({ !retained.contains($0) }) {
            videoPreparationGenerations.removeValue(forKey: playerIndex)
            videoPreparationTasks.removeValue(forKey: playerIndex)?.cancel()
        }
    }

    private func installCurrentScreen(initialOriginatingScene: UIWindowScene? = nil) {
        guard window != nil, ads.indices.contains(index) else { return }
        prepareVideoPlayers(around: index)
        let currentPlayer = ads[index].mediaType == .video ? retainedVideoPlayer(at: index) : nil
        if fallbackVideoReadiness(
            isVideo: ads[index].mediaType == .video,
            hasPreparedPlayer: currentPlayer != nil
        ) == .prepare {
            scheduleVideoPreparation(at: index)
            guard let generation = videoPreparationGenerations[index] else {
                failCreativeAfterTerminal(from: index)
                return
            }
            hostingController?.rootView = loadingView(surface: .videoPreparation(
                index: index,
                generation: generation
            ))
            armCurrentVideoPreparationDeadline(at: index)
            return
        }
        currentVideoPreparationDeadlineTask?.cancel()
        currentVideoPreparationDeadlineTask = nil
        hostingController?.rootView = adView(
            at: index,
            initialOriginatingScene: initialOriginatingScene
        )
    }

    private func boundedPreparedVideos(
        _ prepared: [Int: FullscreenVideoPreparationToken],
        ads: [FallbackAd],
        around currentIndex: Int
    ) -> [Int: FullscreenVideoPreparationToken] {
        let retained = boundedFallbackVideoPreparationIndices(
            in: ads,
            around: currentIndex,
            preparedIndices: Set(prepared.keys)
        )
        for (index, token) in prepared where !retained.contains(index) {
            FullscreenVideoPreparationPool.shared.release(token)
        }
        return prepared.filter { retained.contains($0.key) }
    }

    private func prepareImmediateNextVideo(after currentIndex: Int) {
        scheduleVideoPreparation(at: currentIndex + 1)
    }

    private func scheduleVideoPreparation(at playerIndex: Int) {
        guard ads.indices.contains(playerIndex), ads[playerIndex].mediaType == .video,
              videoPreparations[playerIndex] == nil,
              videoOwnershipIndex != playerIndex,
              videoPreparationTasks[playerIndex] == nil else { return }
        let ad = ads[playerIndex]
        let generation = UUID()
        videoPreparationGenerations[playerIndex] = generation
        videoPreparationTasks[playerIndex] = Task { [weak self] in
            _ = await self?.runVideoPreparation(
                at: playerIndex,
                ad: ad,
                generation: generation
            )
        }
    }

    private func runVideoPreparation(
        at playerIndex: Int,
        ad: FallbackAd,
        generation: UUID
    ) async {
        let token = await prepareFallbackVideo(ad)
        guard videoPreparationGenerations[playerIndex] == generation else {
            FullscreenVideoPreparationPool.shared.release(token)
            return
        }
        videoPreparationGenerations.removeValue(forKey: playerIndex)
        videoPreparationTasks.removeValue(forKey: playerIndex)
        guard !Task.isCancelled, window != nil,
              ads.indices.contains(playerIndex),
              ads[playerIndex].adId == ad.adId,
              playerIndex == index || playerIndex == index + 1 else {
            FullscreenVideoPreparationPool.shared.release(token)
            return
        }
        guard let token else {
            if playerIndex == index { failCreativeAfterTerminal(from: playerIndex) }
            return
        }
        videoPreparations[playerIndex] = token
        if playerIndex == index { installCurrentScreen() }
    }

    private func armCurrentVideoPreparationDeadline(at playerIndex: Int) {
        guard let generation = videoPreparationGenerations[playerIndex] else { return }
        currentVideoPreparationDeadlineTask?.cancel()
        currentVideoPreparationDeadlineTask = Task { [weak self] in
            _ = await self?.runCurrentVideoPreparationDeadline(
                at: playerIndex,
                generation: generation
            )
        }
    }

    private func runCurrentVideoPreparationDeadline(at playerIndex: Int, generation: UUID) async {
        do { try await Task.sleep(nanoseconds: Self.videoPreparationDeadlineNanos) } catch { return }
        guard !Task.isCancelled, window != nil, index == playerIndex,
              videoPreparationGenerations[playerIndex] == generation else { return }
        videoPreparationGenerations.removeValue(forKey: playerIndex)
        videoPreparationTasks.removeValue(forKey: playerIndex)?.cancel()
        currentVideoPreparationDeadlineTask = nil
        failCreativeAfterTerminal(from: playerIndex)
    }

    private func retainedVideoPlayer(at playerIndex: Int) -> FullscreenVideoPlayer? {
        guard ads.indices.contains(playerIndex),
              case .video(_, let posterURL) = ads[playerIndex].creativeContent else {
            releaseVideoOwnership()
            return nil
        }
        if let player = retainedFallbackVideoResource(
            requestedIndex: playerIndex,
            ownershipIndex: videoOwnershipIndex,
            resource: videoOwnership?.resource
        ) {
            return player
        }
        releaseVideoOwnership()
        guard let token = videoPreparations.removeValue(forKey: playerIndex) else { return nil }
        guard let localURL = FullscreenVideoPreparationPool.shared.localURL(for: token) else {
            FullscreenVideoPreparationPool.shared.release(token)
            return nil
        }
        let ownership = makeFallbackVideoOwnership(
            url: localURL,
            posterURL: posterURL,
            token: token,
            startsMuted: !ads[playerIndex].usesVideoPlanV2,
            stallTimeout: ads[playerIndex].usesVideoPlanV2
                ? FullscreenVideoPlayer.videoPlanV2StallTimeout
                : FullscreenVideoPlayer.preparationTimeout
        )
        videoOwnershipIndex = playerIndex
        videoOwnership = ownership
        if ads[playerIndex].usesVideoPlanV2, let player = ownership.resource {
            player.setMuted(videoPlanScope?.isMuted ?? false)
            player.attachVideoPlanScope(videoPlanScope)
        }
        return ownership.resource
    }

    private func releaseVideoPreparation(at playerIndex: Int) {
        videoPreparationGenerations.removeValue(forKey: playerIndex)
        videoPreparationTasks.removeValue(forKey: playerIndex)?.cancel()
        if playerIndex == index {
            currentVideoPreparationDeadlineTask?.cancel()
            currentVideoPreparationDeadlineTask = nil
        }
        if videoOwnershipIndex == playerIndex { releaseVideoOwnership() }
        FullscreenVideoPreparationPool.shared.release(videoPreparations.removeValue(forKey: playerIndex))
    }

    private func releaseVideoOwnership() {
        videoOwnership?.release()
        videoOwnership = nil
        videoOwnershipIndex = nil
    }

    /// Tears down the presentation window and fires the close callback once.
    private func dismiss(outcome: FallbackOutcome) {
        // Capture locals and clear `self`'s references before invoking the callback: releasing
        // the self-retention below may leave the callback's owner as the last reference to this
        // presenter, so `self` can be deallocated by the time the callback returns. The caller's
        // reference keeps `self` alive through this method itself.
        let win = window
        let hostKeyWindow = originalKeyWindow
        let shouldRestoreHostKeyWindow = win?.isKeyWindow == true
        loadingDeadlineTask?.cancel()
        loadingDeadlineTask = nil
        onLoadingTimeout = nil
        isLoading = false
        loadingGeneration = nil
        clickHandoffIndex = nil
        presentationBlockedIndex = nil
        terminalAdvanceState.clear()
        terminalFailureIndex = nil
        let videoPlanScope = videoPlanScope
        self.videoPlanScope = nil
        videoPlanScope?.closePendingHandoff(reason: outcome.videoPlanCloseReason)
        videoPlanScope?.cancel()
        videoPreparationTasks.values.forEach { $0.cancel() }
        videoPreparationTasks.removeAll()
        videoPreparationGenerations.removeAll()
        currentVideoPreparationDeadlineTask?.cancel()
        currentVideoPreparationDeadlineTask = nil
        releaseVideoOwnership()
        videoPreparations.values.forEach { FullscreenVideoPreparationPool.shared.release($0) }
        videoPreparations.removeAll()
        currentRouteLifecycle?.deactivate()
        currentRouteLifecycle = nil
        window = nil
        hostingController = nil
        originalKeyWindow = nil
        let callback = onFinish
        onFinish = nil
        onFallbackGateOpened = nil
        let presentationLease = presentationLease
        self.presentationLease = nil
        retainedWhilePresenting = nil
        win?.isHidden = true
        win?.rootViewController = nil
        if shouldRestoreHostKeyWindow {
            hostKeyWindow?.makeKey()
        }
        callback?(outcome)
        // Balanced with the present-time hide(); ref count keeps the bar hidden if the close
        // callback opens another presenter, restoring the host only when the last one ends.
        SimulaAppStatusBar.restore()
        presentationLease?.finishPostCloseTeardown()
    }

}
#endif
