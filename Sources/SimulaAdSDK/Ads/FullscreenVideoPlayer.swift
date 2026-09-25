import Foundation

let videoPlanV2EligibleStallTimeout: TimeInterval = 8

struct VideoPlaybackGate: Equatable, Sendable {
    let configuredDelay: TimeInterval
    private(set) var duration: TimeInterval?
    private(set) var played: TimeInterval = 0
    private(set) var mediaPosition: TimeInterval = 0
    private(set) var ended = false

    init(configuredDelay: TimeInterval) {
        self.configuredDelay = min(TimeInterval(maxCloseDelaySeconds), max(0, configuredDelay))
    }

    mutating func update(
        duration: TimeInterval?,
        played: TimeInterval,
        mediaPosition: TimeInterval? = nil,
        ended: Bool = false
    ) {
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        }
        if played.isFinite {
            self.played = max(self.played, max(0, played))
        }
        self.mediaPosition = resolvedVideoMediaPosition(
            sample: mediaPosition ?? played,
            fallback: self.mediaPosition
        )
        self.ended = self.ended || ended
    }

    var gateDuration: TimeInterval? {
        min(configuredDelay, duration ?? configuredDelay)
    }

    var isUnlocked: Bool {
        if configuredDelay <= 0 { return true }
        guard let gateDuration else { return ended }
        return ended || played >= gateDuration
    }

    var progress: Double {
        if configuredDelay <= 0 { return 1 }
        guard let gateDuration else { return 0 }
        guard gateDuration > 0 else { return 1 }
        return min(1, max(0, played / gateDuration))
    }

    var secondsRemaining: Int {
        guard let gateDuration else { return Int(configuredDelay.rounded(.up)) }
        return Int(max(0, gateDuration - played).rounded(.up))
    }

    var reachedAssetMidpoint: Bool {
        guard let duration else { return false }
        return mediaPosition >= duration / 2
    }

    var earnedCompletionReason: RewardCompletionReason? {
        guard isUnlocked else { return nil }
        if played >= configuredDelay { return .durationElapsed }
        return .videoCompleted
    }
}

func resolvedVideoMediaPosition(sample: TimeInterval, fallback: TimeInterval = 0) -> TimeInterval {
    guard sample.isFinite, sample >= 0 else {
        return fallback.isFinite ? max(0, fallback) : 0
    }
    return sample
}

func shouldPublishVideoProgress(previous: TimeInterval, next: TimeInterval) -> Bool {
    next.isFinite && next >= 0 && next != previous
}

struct VideoVisiblePlaybackClock: Equatable, Sendable {
    private var firstFrameAdmitted = false
    private(set) var firstFrameMediaTime: TimeInterval?
    private var lastMediaTime: TimeInterval?
    private(set) var playedSeconds: TimeInterval = 0

    mutating func admitFirstFrame(mediaTime: TimeInterval) {
        guard !firstFrameAdmitted else { return }
        firstFrameAdmitted = true
        guard mediaTime.isFinite else { return }
        let baseline = max(0, mediaTime)
        firstFrameMediaTime = baseline
        lastMediaTime = baseline
        playedSeconds = 0
    }

    mutating func update(mediaTime: TimeInterval) -> TimeInterval {
        guard firstFrameAdmitted, mediaTime.isFinite else { return playedSeconds }
        let sample = max(0, mediaTime)
        guard let lastMediaTime else {
            firstFrameMediaTime = sample
            self.lastMediaTime = sample
            return playedSeconds
        }
        if sample >= lastMediaTime {
            let total = playedSeconds + (sample - lastMediaTime)
            playedSeconds = total.isFinite ? total : .greatestFiniteMagnitude
        }
        self.lastMediaTime = sample
        return playedSeconds
    }
}

/// Splits admitted media time by the audio state that was in effect while each interval played.
/// Media time, rather than wall time, excludes background, StoreKit, buffering, and interruption gaps.
struct VideoAudioWatchAccounting: Equatable, Sendable {
    private var lastPlayedSeconds: TimeInterval = 0
    private(set) var mutedSeconds: TimeInterval = 0
    private(set) var unmutedSeconds: TimeInterval = 0

    mutating func update(playedSeconds: TimeInterval, isMuted: Bool) {
        guard playedSeconds.isFinite, playedSeconds >= lastPlayedSeconds else { return }
        let delta = playedSeconds - lastPlayedSeconds
        lastPlayedSeconds = playedSeconds
        if isMuted { mutedSeconds += delta } else { unmutedSeconds += delta }
    }

    var mutedMilliseconds: Int { boundedMilliseconds(mutedSeconds) }
    var unmutedMilliseconds: Int { boundedMilliseconds(unmutedSeconds) }

    private func boundedMilliseconds(_ seconds: TimeInterval) -> Int {
        let value = seconds * 1_000
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value.rounded(), Double(Int.max)))
    }
}

struct FinalVideoPlaybackSnapshot: Equatable, Sendable {
    let playedSeconds: TimeInterval
    let mutedWatchMilliseconds: Int
    let unmutedWatchMilliseconds: Int
}

func finalizeVideoPlayback(
    clock: inout VideoVisiblePlaybackClock,
    accounting: inout VideoAudioWatchAccounting,
    finalMediaTime: TimeInterval,
    isMuted: Bool
) -> FinalVideoPlaybackSnapshot {
    let playedSeconds = clock.update(mediaTime: finalMediaTime)
    accounting.update(playedSeconds: playedSeconds, isMuted: isMuted)
    return FinalVideoPlaybackSnapshot(
        playedSeconds: playedSeconds,
        mutedWatchMilliseconds: accounting.mutedMilliseconds,
        unmutedWatchMilliseconds: accounting.unmutedMilliseconds
    )
}

func shouldArmVideoStallDeadline(
    wantsPlayback: Bool,
    appActive: Bool,
    presentationBlocked: Bool,
    audioInterrupted: Bool
) -> Bool {
    wantsPlayback && appActive && !presentationBlocked && !audioInterrupted
}

/// Eight eligible seconds without media movement or newly buffered data is a dead V2 clip. App,
/// store, and Safari blockers pause the remaining budget rather than resetting it.
struct VideoProgressWatchdog: Equatable, Sendable {
    let budget: TimeInterval
    private(set) var remaining: TimeInterval
    private var lastEligibleTime: TimeInterval?
    private var lastMediaTime: TimeInterval?
    private var lastBufferedEnd: TimeInterval?

    init(budget: TimeInterval = videoPlanV2EligibleStallTimeout) {
        let bounded = max(0, budget.isFinite ? budget : videoPlanV2EligibleStallTimeout)
        self.budget = bounded
        self.remaining = bounded
    }

    mutating func observe(
        now: TimeInterval,
        eligible: Bool,
        mediaTime: TimeInterval,
        bufferedEnd: TimeInterval
    ) -> Bool {
        guard now.isFinite else { return false }
        let media = mediaTime.isFinite ? max(0, mediaTime) : (lastMediaTime ?? 0)
        let buffered = bufferedEnd.isFinite ? max(0, bufferedEnd) : (lastBufferedEnd ?? 0)
        let progressed = lastMediaTime.map { media > $0 + 0.01 } ?? false
        let downloaded = lastBufferedEnd.map { buffered > $0 + 0.01 } ?? false
        let rewound = lastMediaTime.map { media < $0 } ?? false
        lastMediaTime = media
        lastBufferedEnd = buffered

        if progressed || downloaded || rewound {
            remaining = budget
            lastEligibleTime = eligible ? now : nil
            return false
        }
        guard eligible else {
            lastEligibleTime = nil
            return false
        }
        if let previous = lastEligibleTime, now >= previous {
            remaining = max(0, remaining - (now - previous))
        }
        lastEligibleTime = now
        return remaining <= 0
    }

    mutating func reset() {
        remaining = budget
        lastEligibleTime = nil
        lastMediaTime = nil
        lastBufferedEnd = nil
    }
}

struct VideoFirstFrameDeadlineState: Equatable, Sendable {
    private(set) var armed = false
    private(set) var admitted = false
    private(set) var failed = false
    private(set) var pendingEnd = false

    mutating func arm() -> Bool {
        guard !armed, !admitted, !failed else { return false }
        armed = true
        return true
    }

    mutating func admit() -> Bool {
        guard !admitted, !failed else { return false }
        admitted = true
        armed = false
        return true
    }

    mutating func pause() {
        armed = false
    }

    mutating func timeout() -> Bool {
        guard armed, !admitted, !failed else { return false }
        armed = false
        failed = true
        pendingEnd = false
        return true
    }

    mutating func fail() {
        guard !admitted else { return }
        armed = false
        failed = true
        pendingEnd = false
    }

    mutating func deferEndUntilFrame() -> Bool {
        guard !admitted, !failed, !pendingEnd else { return false }
        pendingEnd = true
        return true
    }

    mutating func consumePendingEnd() -> Bool {
        guard admitted, pendingEnd, !failed else { return false }
        pendingEnd = false
        return true
    }
}

enum FullscreenVideoFailure: String, Equatable, Sendable {
    case preparationTimeout = "prepare_timeout"
    case playbackTimeout = "playback_timeout"
    case itemFailed = "prepare_failed"
    case playbackFailed = "playback_error"
    case firstFrameTimeout = "first_frame_timeout"
}

enum FullscreenVideoStatus: Equatable, Sendable {
    case preparing
    case ready
    case playing
    case paused
    case ended
    case failed(FullscreenVideoFailure)

    var isTerminal: Bool {
        switch self {
        case .ended, .failed:
            return true
        case .preparing, .ready, .playing, .paused:
            return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var reusableForPreparedClaim: Bool {
        switch self {
        case .preparing, .ready, .paused:
            return true
        case .playing, .ended, .failed:
            return false
        }
    }
}

enum VideoTimeControlEvent: Equatable, Sendable {
    case playing
    case paused
    case waiting
    case unknown
}

#if os(iOS)
private enum FullscreenVideoObserverEvent: Sendable {
    case ended
    case failedToPlayToEnd
    case applicationActive(Bool)
    case audioInterruptionBegan
    case audioInterruptionEnded(shouldResume: Bool)
}
#endif

enum VideoTimeControlEffect: Equatable, Sendable {
    case beganPlaying
    case paused
    case waiting
    case none
    case cancelDeadlines
}

struct VideoTimeControlTransition: Equatable, Sendable {
    let status: FullscreenVideoStatus
    let effect: VideoTimeControlEffect
}

func videoTimeControlTransition(
    status: FullscreenVideoStatus,
    stopped: Bool,
    event: VideoTimeControlEvent
) -> VideoTimeControlTransition {
    guard !stopped, !status.isTerminal else {
        return VideoTimeControlTransition(status: status, effect: .cancelDeadlines)
    }
    switch event {
    case .playing:
        return VideoTimeControlTransition(status: .playing, effect: .beganPlaying)
    case .paused:
        let nextStatus = status == .preparing ? status : .paused
        return VideoTimeControlTransition(status: nextStatus, effect: .paused)
    case .waiting:
        return VideoTimeControlTransition(status: status, effect: .waiting)
    case .unknown:
        return VideoTimeControlTransition(status: status, effect: .none)
    }
}

func fullscreenVideoReadyStatus(
    status: FullscreenVideoStatus,
    itemReadyToPlay: Bool
) -> FullscreenVideoStatus {
    guard status == .preparing, itemReadyToPlay else { return status }
    return .ready
}

func shouldPlayFullscreenVideo(
    wantsPlayback: Bool,
    requiresUserResume: Bool,
    appActive: Bool,
    presentationBlocked: Bool,
    audioInterrupted: Bool,
    itemReadyToPlay: Bool
) -> Bool {
    wantsPlayback && !requiresUserResume && appActive
        && !presentationBlocked && !audioInterrupted && itemReadyToPlay
}

func shouldReusePreparedVideoPlayer(
    status: FullscreenVideoStatus,
    isStopped: Bool,
    isActive: Bool
) -> Bool {
    !isStopped && !isActive && status.reusableForPreparedClaim
}

func shouldAcceptFullscreenVideoFirstFrameCallback(
    presentationActive: Bool,
    failureHandled: Bool,
    callbackPlayerIdentity: ObjectIdentifier,
    currentPlayerIdentity: ObjectIdentifier?,
    status: FullscreenVideoStatus,
    isStopped: Bool
) -> Bool {
    presentationActive
        && !failureHandled
        && callbackPlayerIdentity == currentPlayerIdentity
        && !status.isTerminal
        && !isStopped
}

func shouldAcceptVideoLayerReadyCallback(
    callbackGeneration: UInt64,
    installationGeneration: UInt64,
    callbackPlayerIdentity: ObjectIdentifier,
    installedPlayerIdentity: ObjectIdentifier?,
    callbackLayerIdentity: ObjectIdentifier,
    installedLayerIdentity: ObjectIdentifier,
    layerPlayerIdentity: ObjectIdentifier?,
    isReadyForDisplay: Bool,
    firstFrameReported: Bool
) -> Bool {
    callbackGeneration == installationGeneration
        && callbackPlayerIdentity == installedPlayerIdentity
        && callbackLayerIdentity == installedLayerIdentity
        && callbackPlayerIdentity == layerPlayerIdentity
        && isReadyForDisplay
        && !firstFrameReported
}

func videoSurfaceShowsFirstFrame(
    localPlayerIdentity: ObjectIdentifier?,
    currentPlayerIdentity: ObjectIdentifier
) -> Bool {
    localPlayerIdentity == currentPlayerIdentity
}

struct VideoSurfaceFirstFrameHandoffState: Equatable {
    private(set) var readyLayerPlayerIdentity: ObjectIdentifier?
    private(set) var surfaceAppeared = false
    private(set) var presentationActive = false
    private(set) var parentNotifiedForAppearance = false

    mutating func layerBecameReady(
        playerIdentity: ObjectIdentifier,
        currentPlayerIdentity: ObjectIdentifier
    ) {
        guard playerIdentity == currentPlayerIdentity else { return }
        readyLayerPlayerIdentity = playerIdentity
    }

    mutating func surfaceDidAppear() {
        surfaceAppeared = true
        parentNotifiedForAppearance = false
    }

    mutating func surfaceDidDisappear() {
        surfaceAppeared = false
        presentationActive = false
        parentNotifiedForAppearance = false
    }

    mutating func setPresentationActive(_ active: Bool) {
        presentationActive = active
    }

    func shouldAttemptParentHandoff(currentPlayerIdentity: ObjectIdentifier) -> Bool {
        surfaceAppeared
            && presentationActive
            && !parentNotifiedForAppearance
            && readyLayerPlayerIdentity == currentPlayerIdentity
    }

    mutating func parentResponded(accepted: Bool) -> Bool {
        guard accepted, !parentNotifiedForAppearance else { return false }
        parentNotifiedForAppearance = true
        return true
    }
}

func shouldShowVideoStorePrompt(enabled: Bool, reachedMidpoint: Bool, dismissUnlocked: Bool) -> Bool {
    enabled && reachedMidpoint && !dismissUnlocked
}

func progressBarGateFraction(gateSeconds: TimeInterval, mediaDuration: TimeInterval) -> Double {
    guard gateSeconds.isFinite, mediaDuration.isFinite, gateSeconds > 0,
          mediaDuration > 0, gateSeconds < mediaDuration else { return 1 }
    return gateSeconds / mediaDuration
}

func twoToneProgressSegments(progress: Double, gateFraction: Double) -> (bright: Double, dark: Double) {
    let progress = progress.isFinite ? min(1, max(0, progress)) : 0
    let gate = gateFraction.isFinite ? min(1, max(0, gateFraction)) : 1
    return (min(progress, gate), max(0, progress - gate))
}

let twoToneProgressTrackHex = "#3A3A40"
let twoToneProgressGateHex = "#1186F2"
let twoToneProgressPostGateHex = "#1156B6"

func effectiveVideoProgressBarStyle(
    isContract2Video: Bool,
    configured: ProgressBarStyle
) -> ProgressBarStyle {
    isContract2Video ? configured : .single
}

func shouldMountProgressBar(
    treatment: CloseTreatment,
    style: ProgressBarStyle,
    dismissUnlocked: Bool
) -> Bool {
    style == .twoTone || (treatment == .progressBar && !dismissUnlocked)
}

func canUseVideoControls(firstFrameAdmitted: Bool, displayAdmitted: Bool) -> Bool {
    firstFrameAdmitted && displayAdmitted
}

func shouldAutomaticallyAdvanceCompletedVideo(
    usesVideoPlanV2: Bool,
    status: FullscreenVideoStatus
) -> Bool {
    // Completion unlocks the close gate. Slot transitions require the close tap.
    false
}

enum VideoPreFirstFrameEscapeSurface: Equatable, Sendable {
    case interstitial
    case rewarded
    case fallback
}

enum VideoPreFirstFrameEscapeAction: Equatable, Sendable {
    case none
    case failInterstitialDisplay
    case finishRewardedUnearned
    case requestFallbackFailureAdvance
}

struct VideoPreFirstFrameEscapeDecision: Equatable, Sendable {
    let action: VideoPreFirstFrameEscapeAction
    let terminalEvent: VideoPlanTerminalEvent
    let telemetryStage: String
    let telemetryReason: String
}

func shouldShowVideoPreFirstFrameEscape(
    firstFrameAdmitted: Bool,
    terminal: Bool
) -> Bool {
    !firstFrameAdmitted && !terminal
}

struct VideoPreFirstFrameChromeVisibility: Equatable, Sendable {
    let showsEscape: Bool
    let showsServerControl: Bool
}

func videoPreFirstFrameChromeVisibility(
    hasVideo: Bool,
    firstFrameAdmitted: Bool,
    terminal: Bool
) -> VideoPreFirstFrameChromeVisibility {
    if hasVideo && terminal {
        return VideoPreFirstFrameChromeVisibility(
            showsEscape: false,
            showsServerControl: false
        )
    }
    let showsEscape = hasVideo && shouldShowVideoPreFirstFrameEscape(
        firstFrameAdmitted: firstFrameAdmitted,
        terminal: terminal
    )
    return VideoPreFirstFrameChromeVisibility(
        showsEscape: showsEscape,
        showsServerControl: !showsEscape
    )
}

func videoPreFirstFrameEscapeAction(
    surface: VideoPreFirstFrameEscapeSurface,
    presentationMounted: Bool,
    firstFrameAdmitted: Bool,
    terminal: Bool
) -> VideoPreFirstFrameEscapeAction {
    videoPreFirstFrameEscapeDecision(
        surface: surface,
        presentationMounted: presentationMounted,
        firstFrameAdmitted: firstFrameAdmitted,
        terminal: terminal
    )?.action ?? .none
}

func videoPreFirstFrameEscapeDecision(
    surface: VideoPreFirstFrameEscapeSurface,
    presentationMounted: Bool,
    firstFrameAdmitted: Bool,
    terminal: Bool
) -> VideoPreFirstFrameEscapeDecision? {
    guard presentationMounted,
          shouldShowVideoPreFirstFrameEscape(
              firstFrameAdmitted: firstFrameAdmitted,
              terminal: terminal
          ) else { return nil }
    let action: VideoPreFirstFrameEscapeAction
    switch surface {
    case .interstitial: action = .failInterstitialDisplay
    case .rewarded: action = .finishRewardedUnearned
    case .fallback: action = .requestFallbackFailureAdvance
    }
    return VideoPreFirstFrameEscapeDecision(
        action: action,
        terminalEvent: .userClose,
        telemetryStage: FullscreenVideoTelemetryStage.close,
        telemetryReason: FullscreenVideoTerminationReason.preFirstFrameCancel
    )
}

enum FullscreenVideoTelemetryStage {
    static let start = "video_start"
    static let complete = "video_complete"
    static let fail = "video_fail"
    static let muteToggle = "video_mute_toggle"
    static let mute = "video_mute" // decode/analytics alias; V2 emits `video_mute_toggle`.
    static let unmute = "video_unmute" // decode/analytics alias.
    static let duration = "video_duration"
    static let quartile = "video_duration"
    static let pause = "video_pause"
    static let resume = "video_resume"
    static let close = "video_close"
    static let handoff = "video_handoff"
    static let skoverlayShown = "skoverlay_shown"
    static let skoverlayDismissed = "skoverlay_dismissed"
    static let skoverlayFailed = "skoverlay_failed"
}

enum FullscreenVideoTerminationReason {
    static let completed = "completed"
    static let failed = "failed"
    static let user = "user"
    static let preFirstFrameCancel = "pre_first_frame_cancel"
    static let noNextStep = "no_next_step"
    static let nextStepFailed = "next_step_failed"
    static let nextStepTimeout = "next_step_timeout"
    static let backgrounded = "backgrounded"
    static let storePresented = "store_presented"
    static let audioInterruption = "audio_interruption"
    static let playback = "playback"

    static let canonicalVocabulary: Set<String> = [
        completed, failed, user, preFirstFrameCancel, noNextStep, nextStepFailed, nextStepTimeout,
        backgrounded, storePresented, audioInterruption, playback,
    ]
}

enum VideoPlanTerminalAction: Equatable, Sendable {
    case handoff(reason: String)
    case close(reason: String)
    case preservePendingHandoff
    case failExpectedNextStep
}

func videoPlanTerminalAction(
    reason: String,
    expectsNextStep: Bool,
    playbackStarted: Bool
) -> VideoPlanTerminalAction {
    if reason == FullscreenVideoTerminationReason.completed {
        return expectsNextStep ? .handoff(reason: reason) : .close(reason: reason)
    }
    if !playbackStarted {
        return expectsNextStep ? .preservePendingHandoff : .failExpectedNextStep
    }
    return expectsNextStep ? .handoff(reason: reason) : .close(reason: reason)
}

struct VideoQuartileState: Equatable, Sendable {
    private var emitted: Set<Int> = []

    mutating func crossed(position: TimeInterval, duration: TimeInterval?) -> [Int] {
        guard position.isFinite, position >= 0, let duration,
              duration.isFinite, duration > 0 else { return [] }
        return [50].filter { quartile in
            guard !emitted.contains(quartile), position / duration >= Double(quartile) / 100 else {
                return false
            }
            emitted.insert(quartile)
            return true
        }
    }
}

func activeVideoSegment(in segments: [VideoSegment], at position: TimeInterval) -> VideoSegment? {
    guard position.isFinite, position >= 0 else { return nil }
    return segments.first { position >= $0.startSeconds && position < $0.endSeconds }
        ?? segments.last.flatMap { position >= $0.endSeconds ? $0 : nil }
}

struct VideoPauseTelemetryState: Equatable, Sendable {
    private var startedAt: TimeInterval?
    private var reason: String?

    mutating func pause(
        now: TimeInterval,
        reasonProvider: () -> String
    ) -> String? {
        guard startedAt == nil, now.isFinite else { return nil }
        let reason = reasonProvider()
        startedAt = now
        self.reason = reason
        return reason
    }

    mutating func resume(now: TimeInterval) -> (reason: String, pausedMs: Double)? {
        guard let startedAt, now.isFinite, now >= startedAt else { return nil }
        let result = (reason ?? FullscreenVideoTerminationReason.playback, (now - startedAt) * 1_000)
        self.startedAt = nil
        reason = nil
        return result
    }
}

enum VideoSurfaceTelemetryEvent: Equatable, Sendable {
    case segment(VideoSegmentTelemetryEvent)
    case quartile(Int)
    case pause(reason: String)
    case resume(reason: String, pausedMs: Double)
}

func recordFullscreenVideoLifecycle(
    stage: String,
    adFormat: String,
    adUnitId: String?,
    adId: String?,
    serveId: String?,
    isVideoPlanV2: Bool,
    creative: Creative?,
    behavior: AdBehavior?,
    muted: Bool?,
    mutedWatchMs: Int? = nil,
    unmutedWatchMs: Int? = nil,
    errorCode: String? = nil,
    videoPositionS: Double? = nil,
    durationS: Double? = nil,
    quartile: Int? = nil,
    reason: String? = nil,
    pausedMs: Double? = nil,
    msToNextStepReady: Double? = nil,
    secondsSinceVideoStart: Double? = nil,
    visibleS: Double? = nil,
    on: String? = nil,
    segmentEvent: VideoSegmentTelemetryEvent? = nil
) {
    if isVideoPlanV2, creative?.segments.isEmpty == false, segmentEvent == nil,
       stage == FullscreenVideoTelemetryStage.start || stage == FullscreenVideoTelemetryStage.complete { return }
    guard isVideoPlanV2 else {
        Telemetry.shared.recordLifecycle(
            stage: stage,
            adFormat: adFormat,
            adUnitId: adUnitId,
            adId: adId,
            serveId: serveId,
            errorCode: errorCode
        )
        return
    }
    let style = resolvedVideoChromeStyle(
        requested: behavior?.video.style ?? .cornerCTA,
        hasAppIcon: validatedCreativeURL(creative?.appIconUrl) != nil,
        hasAppName: creative?.videoChromeTitle != nil
    ).rawValue
    let overlay = effectiveVideoPlanSKOverlayConfig(isVideoPlanV2: true, config: behavior?.skoverlay)
    let mutedSeconds = segmentEvent?.mutedSeconds ?? mutedWatchMs.map { Double($0) / 1_000 }
    let unmutedSeconds = segmentEvent?.unmutedSeconds ?? unmutedWatchMs.map { Double($0) / 1_000 }
    let watchedSeconds = (mutedSeconds != nil || unmutedSeconds != nil)
        ? (mutedSeconds ?? 0) + (unmutedSeconds ?? 0)
        : nil
    let activeSegment = segmentEvent?.segment ?? activeVideoSegment(in: creative?.segments ?? [], at: videoPositionS ?? 0)
    Telemetry.shared.recordVideoLifecycle(
        stage: stage,
        adFormat: adFormat,
        adUnitId: adUnitId,
        adId: adId,
        serveId: serveId,
        errorCode: errorCode,
        clipIndex: activeSegment?.clipIndex ?? creative?.clipIndex,
        muted: muted,
        impressionId: serveId ?? adId,
        style: style,
        skoverlayEnabled: overlay != nil,
        skoverlayDelaySeconds: overlay?.delaySeconds,
        videoPositionS: segmentEvent?.position ?? videoPositionS,
        pool: activeSegment?.videoPool ?? creative?.videoPool,
        durationS: segmentEvent?.duration ?? durationS,
        quartile: quartile,
        reason: reason,
        pausedMs: pausedMs,
        watchedS: watchedSeconds,
        secondsUnmuted: unmutedSeconds,
        secondsMuted: mutedSeconds,
        msToNextStepReady: msToNextStepReady,
        secondsSinceVideoStart: secondsSinceVideoStart,
        on: on,
        visibleS: visibleS,
        error: errorCode
    )
}

struct VideoChromeConfiguration: Equatable, Sendable {
    let style: VideoChromeStyle
    let cta: String
    let appIconURL: URL?
    let title: String?
    let subtitle: String?
}

func resolvedVideoChromeStyle(
    requested: VideoChromeStyle,
    hasAppIcon: Bool,
    hasAppName: Bool
) -> VideoChromeStyle {
    switch requested {
    case .bottomBar, .floatingPill:
        return hasAppIcon ? requested : .cornerCTA
    case .bottomCard, .feedCard:
        return hasAppIcon && hasAppName ? requested : .cornerCTA
    case .cornerCTA:
        return .cornerCTA
    }
}

func effectiveVideoClosePosition(
    treatment: CloseTreatment,
    position: ClosePosition,
    progressBarStyle: ProgressBarStyle = .single
) -> ClosePosition {
    videoBottomProgressBarObstructsChrome(
        treatment: treatment,
        position: position,
        progressBarStyle: progressBarStyle
    )
        ? .topRight
        : position
}

func videoBottomProgressBarObstructsChrome(
    treatment: CloseTreatment,
    position: ClosePosition,
    progressBarStyle: ProgressBarStyle = .single
) -> Bool {
    position == .bottomLeft && (treatment == .progressBar || progressBarStyle == .twoTone)
}

func videoChromeNeedsBottomLeadingClearance(
    effectiveClosePosition: ClosePosition,
    resolvedStyle: VideoChromeStyle
) -> Bool {
    guard effectiveClosePosition == .bottomLeft else { return false }
    switch resolvedStyle {
    case .bottomBar, .bottomCard, .feedCard, .floatingPill:
        return true
    case .cornerCTA:
        return false
    }
}

func videoChromeAdditionalLeadingPadding(
    effectiveClosePosition: ClosePosition,
    resolvedStyle: VideoChromeStyle
) -> Double {
    // Existing 12pt outer padding plus 100pt reserves a conservative 112pt exclusion.
    videoChromeNeedsBottomLeadingClearance(
        effectiveClosePosition: effectiveClosePosition,
        resolvedStyle: resolvedStyle
    ) ? 100 : 0
}

func videoChromeAdditionalBottomPadding(bottomProgressBarObstructsChrome: Bool) -> Double {
    // Existing 12pt outer padding plus 26pt clears the lifted 4pt bar with an 8pt gap.
    bottomProgressBarObstructsChrome ? 26 : 0
}

func videoChromeConfiguration(
    creative: Creative?,
    behavior: AdBehavior?,
    isVideoPlanV2: Bool
) -> VideoChromeConfiguration? {
    guard isVideoPlanV2, let creative, creative.mediaType == .video else { return nil }
    let iconURL = validatedCreativeURL(creative.appIconUrl)
    let title = creative.videoChromeTitle
    return VideoChromeConfiguration(
        style: resolvedVideoChromeStyle(
            requested: behavior?.video.style ?? .cornerCTA,
            hasAppIcon: iconURL != nil,
            hasAppName: title != nil
        ),
        cta: creative.videoCTATitle,
        appIconURL: iconURL,
        title: title,
        subtitle: creative.videoChromeSubtitle
    )
}

struct FullscreenVideoPreparationToken: Hashable, Sendable {
    fileprivate let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

struct VideoPreparationRetentionPolicy: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let id: UUID
        let active: Bool
        let lastTouched: TimeInterval
    }

    let capacity: Int
    let retention: TimeInterval

    func expiredEntryIDs(_ entries: [Entry], now: TimeInterval) -> [UUID] {
        entries.filter { !$0.active && now - $0.lastTouched >= retention }.map(\.id)
    }

    func evictionCandidate(_ entries: [Entry]) -> UUID? {
        guard entries.count >= max(1, capacity) else { return nil }
        return entries.filter { !$0.active }.min { $0.lastTouched < $1.lastTouched }?.id
    }
}

struct VideoAudioTrackSnapshot<ID: Hashable & Sendable>: Equatable, Sendable {
    let id: ID
    let isAudio: Bool
    let isEnabled: Bool
}

struct VideoAudioTrackCommand<ID: Hashable & Sendable>: Equatable, Sendable {
    let id: ID
    let isEnabled: Bool
}

struct VideoAudioTrackPolicy<ID: Hashable & Sendable>: Sendable {
    private(set) var isMuted: Bool
    private(set) var originalEnabled: [ID: Bool] = [:]

    init(isMuted: Bool = true) {
        self.isMuted = isMuted
    }

    mutating func prepareMutedPlayback(
        tracks: [VideoAudioTrackSnapshot<ID>]
    ) -> [VideoAudioTrackCommand<ID>] {
        guard isMuted else { return [] }
        return disableCurrentAudioTracks(tracks)
    }

    mutating func tracksDidChange(
        _ tracks: [VideoAudioTrackSnapshot<ID>]
    ) -> [VideoAudioTrackCommand<ID>] {
        guard isMuted else { return [] }
        return reconcileCurrentAudioTracks(tracks)
    }

    mutating func remute(
        tracks: [VideoAudioTrackSnapshot<ID>]
    ) -> [VideoAudioTrackCommand<ID>] {
        isMuted = true
        return disableCurrentAudioTracks(tracks)
    }

    mutating func unmute(
        tracks: [VideoAudioTrackSnapshot<ID>]
    ) -> [VideoAudioTrackCommand<ID>] {
        guard isMuted else { return [] }
        let audioTracks = tracks.filter(\.isAudio)
        let currentIDs = Set(audioTracks.map(\.id))
        var commands = restoreRemovedAudioTracks(currentIDs: currentIDs)
        commands += audioTracks.compactMap { track -> VideoAudioTrackCommand<ID>? in
            guard track.isAudio, let original = originalEnabled[track.id],
                  track.isEnabled != original else { return nil }
            return VideoAudioTrackCommand(id: track.id, isEnabled: original)
        }
        isMuted = false
        originalEnabled.removeAll(keepingCapacity: false)
        return commands
    }

    mutating func teardown() {
        originalEnabled.removeAll(keepingCapacity: false)
    }

    private mutating func disableCurrentAudioTracks(
        _ tracks: [VideoAudioTrackSnapshot<ID>]
    ) -> [VideoAudioTrackCommand<ID>] {
        reconcileCurrentAudioTracks(tracks)
    }

    private mutating func reconcileCurrentAudioTracks(
        _ tracks: [VideoAudioTrackSnapshot<ID>]
    ) -> [VideoAudioTrackCommand<ID>] {
        let audioTracks = tracks.filter(\.isAudio)
        let currentIDs = Set(audioTracks.map(\.id))
        var commands = restoreRemovedAudioTracks(currentIDs: currentIDs)
        originalEnabled = originalEnabled.filter { currentIDs.contains($0.key) }
        commands.reserveCapacity(commands.count + audioTracks.count)
        for track in audioTracks {
            if originalEnabled[track.id] == nil {
                originalEnabled[track.id] = track.isEnabled
            }
            if track.isEnabled {
                commands.append(VideoAudioTrackCommand(id: track.id, isEnabled: false))
            }
        }
        return commands
    }

    private func restoreRemovedAudioTracks(
        currentIDs: Set<ID>
    ) -> [VideoAudioTrackCommand<ID>] {
        originalEnabled.compactMap { id, original in
            currentIDs.contains(id) ? nil : VideoAudioTrackCommand(id: id, isEnabled: original)
        }
    }
}

struct StrongVideoAudioTrackRecords<Track: AnyObject> {
    private struct Record {
        let id: UUID
        let track: Track
    }

    private var records: [Record] = []

    var count: Int { records.count }

    mutating func id(for track: Track) -> UUID {
        if let record = records.first(where: { $0.track === track }) {
            return record.id
        }
        let record = Record(id: UUID(), track: track)
        records.append(record)
        return record.id
    }

    func track(for id: UUID) -> Track? {
        records.first(where: { $0.id == id })?.track
    }

    mutating func retain(ids: Set<UUID>) {
        records.removeAll { !ids.contains($0.id) }
    }
}

enum VideoMuteControlPlacement: Equatable {
    case topLeading
    case topTrailing
    case bottomTrailing
}

func videoMuteControlPlacement(
    hasVideoChrome: Bool,
    effectiveClosePosition: ClosePosition
) -> VideoMuteControlPlacement {
    guard hasVideoChrome else { return .bottomTrailing }
    return effectiveClosePosition == .topLeft ? .topTrailing : .topLeading
}

func videoMuteTopPadding(
    hasVideoChrome: Bool,
    storePromptVisible: Bool,
    storePromptSharesMuteCorner: Bool
) -> Double {
    hasVideoChrome && storePromptVisible && storePromptSharesMuteCorner ? 64 : 12
}

func videoStorePromptSharesMuteCorner(configuredClosePosition: ClosePosition) -> Bool {
    configuredClosePosition != .bottomLeft
}

#if os(iOS)
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// One process-wide serial activation, with bounded, cancellable claims on the main actor.
/// A stalled audio daemon never blocks UI or causes additional activation workers to accumulate.
/// The SDK never deactivates the process-global session, which may also belong to the host.
@MainActor
final class VideoAudioSessionCoordinator {
    static let shared = VideoAudioSessionCoordinator()
    private static let activationQueue = DispatchQueue(label: "ad.simula.video.audio", qos: .userInitiated)
    private static let maximumClaims = 16
    private var claims = Set<UUID>()
    private var pending: [UUID: (Bool) -> Void] = [:]
    private var deadlines: [UUID: DispatchWorkItem] = [:]
    private var activated = false
    private var activating = false
    private var activationTimedOut = false
    private let activate: @Sendable () -> Bool
    private let claimTimeout: TimeInterval

    convenience init() {
        self.init(activate: { (try? AVAudioSession.sharedInstance().setActive(true)) != nil })
    }

    init(claimTimeout: TimeInterval = 10, activate: @escaping @Sendable () -> Bool) {
        self.activate = activate
        self.claimTimeout = claimTimeout
    }

    func claim(completion: @escaping (Bool) -> Void) -> UUID? {
        guard !activationTimedOut, claims.count < Self.maximumClaims else { return nil }
        let id = UUID()
        claims.insert(id)
        pending[id] = completion
        let deadline = DispatchWorkItem { [weak self] in self?.activationDeadlineExpired(id) }
        deadlines[id] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + claimTimeout, execute: deadline)
        if activated {
            DispatchQueue.main.async { [weak self] in self?.finishClaim(id, success: true) }
        } else if !activating {
            activating = true
            let operation = activate
            Self.activationQueue.async { [weak self] in
                let success = operation()
                DispatchQueue.main.async { self?.activationFinished(success) }
            }
        }
        return id
    }

    func release(_ id: UUID) {
        claims.remove(id)
        pending.removeValue(forKey: id)
        deadlines.removeValue(forKey: id)?.cancel()
        if claims.isEmpty { activated = false }
    }

    private func activationFinished(_ success: Bool) {
        activating = false
        activationTimedOut = false
        activated = success && !claims.isEmpty
        for id in Array(pending.keys) { finishClaim(id, success: success) }
    }

    private func activationDeadlineExpired(_ id: UUID) {
        guard pending[id] != nil else { return }
        // A timed-out system call is still running. Do not queue retries behind it or make
        // every later video wait another deadline; callers can immediately play muted.
        if activating { activationTimedOut = true }
        for pendingID in Array(pending.keys) { finishClaim(pendingID, success: false) }
    }

    private func finishClaim(_ id: UUID, success: Bool) {
        guard let completion = pending.removeValue(forKey: id), claims.contains(id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        if !success { release(id) }
        completion(success)
    }
}

@MainActor
final class VideoIdleTimerCoordinator {
    /// `isIdleTimerDisabled` is process-global and has no ownership token. We preserve the value
    /// sampled for the first SDK claim and restore it only while the flag is still enabled, but a
    /// host writing the same value during playback is indistinguishable from the SDK's own write.
    static let shared = VideoIdleTimerCoordinator()
    private var claims = 0
    private var hostValue = false
    private let read: () -> Bool
    private let write: (Bool) -> Void

    convenience init() {
        self.init(
            read: { UIApplication.shared.isIdleTimerDisabled },
            write: { UIApplication.shared.isIdleTimerDisabled = $0 }
        )
    }

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func claim() {
        if claims == 0 {
            hostValue = read()
            write(true)
        }
        claims += 1
    }

    func release() {
        guard claims > 0 else { return }
        claims -= 1
        if claims == 0, read() == true { write(hostValue) }
    }
}

enum VideoInterruptionEndAction: Equatable {
    case resume
    case stayPaused
    case reconcile
}

func shouldOfferVideoInterruptionResume(
    audioInterrupted: Bool,
    wantsPlayback: Bool
) -> Bool {
    audioInterrupted && wantsPlayback
}

func shouldScheduleVideoInterruptionFallback(
    audioInterrupted: Bool,
    wantsPlayback: Bool,
    resumeOffered: Bool,
    fallbackPending: Bool
) -> Bool {
    audioInterrupted && wantsPlayback && !resumeOffered && !fallbackPending
}

func videoInterruptionEndAction(
    pausedByInterruption: Bool,
    userInfo: [AnyHashable: Any]?
) -> VideoInterruptionEndAction {
    guard pausedByInterruption else { return .reconcile }
    return videoInterruptionShouldResume(userInfo) ? .resume : .stayPaused
}

@MainActor
/// Best-effort per-track isolation for tracks AVFoundation identifies as audio. Dynamic streams may
/// expose item tracks without an asset track; those remain untouched and rely on AVPlayer.isMuted.
private final class VideoAudioTrackIsolation {
    private let item: AVPlayerItem
    private var policy: VideoAudioTrackPolicy<UUID>
    private var trackRecords = StrongVideoAudioTrackRecords<AVPlayerItemTrack>()
    private var tracksObservation: NSKeyValueObservation?
    private var mediaSelectionObserver: NSObjectProtocol?
    private var tornDown = false

    init(item: AVPlayerItem, startsMuted: Bool) {
        self.item = item
        self.policy = VideoAudioTrackPolicy(isMuted: startsMuted)
        tracksObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.knownTracksDidChange() }
        }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueMediaSelectionDidChange()
        }
    }

    deinit {
        tracksObservation?.invalidate()
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
        }
    }

    func prepareMutedPlayback() {
        reconcile { policy, snapshots in
            policy.prepareMutedPlayback(tracks: snapshots)
        }
    }

    func remute() {
        reconcile { policy, snapshots in policy.remute(tracks: snapshots) }
    }

    func unmute() {
        reconcile { policy, snapshots in policy.unmute(tracks: snapshots) }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        tracksObservation?.invalidate()
        tracksObservation = nil
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
            self.mediaSelectionObserver = nil
        }
        policy.teardown()
        trackRecords.retain(ids: [])
    }

    private func knownTracksDidChange() {
        guard !tornDown else { return }
        reconcile { policy, snapshots in policy.tracksDidChange(snapshots) }
    }

    private func mediaSelectionDidChange() {
        guard !tornDown else { return }
        // Preserve baselines captured before the SDK disabled existing tracks. The notification may
        // reflect our own disabled state; only newly identifiable audio tracks capture a new baseline.
        reconcile { policy, snapshots in policy.tracksDidChange(snapshots) }
    }

    private nonisolated func enqueueMediaSelectionDidChange() {
        Task { @MainActor [weak self] in self?.deliverMediaSelectionDidChange() }
    }

    private func deliverMediaSelectionDidChange() {
        mediaSelectionDidChange()
    }

    private func snapshots() -> [VideoAudioTrackSnapshot<UUID>] {
        item.tracks.compactMap { track in
            // A nil assetTrack has no trustworthy media type. Leave it untouched and rely on
            // AVPlayer.isMuted; treating unknown tracks as audio can disable the video track.
            guard track.assetTrack?.mediaType == .audio else { return nil }
            return VideoAudioTrackSnapshot(
                id: trackRecords.id(for: track),
                isAudio: true,
                isEnabled: track.isEnabled
            )
        }
    }

    private func reconcile(
        transition: (
            inout VideoAudioTrackPolicy<UUID>,
            [VideoAudioTrackSnapshot<UUID>]
        ) -> [VideoAudioTrackCommand<UUID>]
    ) {
        let snapshots = snapshots()
        let commands = transition(&policy, snapshots)
        for command in commands {
            trackRecords.track(for: command.id)?.isEnabled = command.isEnabled
        }
        trackRecords.retain(ids: Set(policy.originalEnabled.keys))
    }
}

@MainActor
final class FullscreenVideoPlayer: ObservableObject {
    nonisolated static let preparationTimeout: TimeInterval = 10
    nonisolated static let firstFrameTimeout: TimeInterval = 10
    nonisolated static let pendingEndFrameGrace: TimeInterval = 0.5
    nonisolated static let unmatchedInterruptionFallback: TimeInterval = 1
    nonisolated static let videoPlanV2StallTimeout = videoPlanV2EligibleStallTimeout

    @Published private(set) var status: FullscreenVideoStatus = .preparing
    @Published private(set) var duration: TimeInterval?
    private(set) var playedSeconds: TimeInterval = 0
    @Published private(set) var mediaPositionSeconds: TimeInterval = 0
    @Published private(set) var isMuted = false
    @Published private(set) var requiresUserResume = false

    let player: AVPlayer
    let posterURL: URL?

    private let item: AVPlayerItem
    private let audioTrackIsolation: VideoAudioTrackIsolation
    private var itemStatusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var periodicTimeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var preparationTimeoutWorkItem: DispatchWorkItem?
    private var playbackTimeoutWorkItem: DispatchWorkItem?
    private var firstFrameTimeoutWorkItem: DispatchWorkItem?
    private var pendingEndGraceWorkItem: DispatchWorkItem?
    private var interruptionFallbackWorkItem: DispatchWorkItem?
    private var progressWatchdogWorkItem: DispatchWorkItem?
    private var visiblePlaybackClock = VideoVisiblePlaybackClock()
    private var audioWatchAccounting = VideoAudioWatchAccounting()
    private var firstFrameDeadline = VideoFirstFrameDeadlineState()
    private var wantsPlayback = false
    private var presentationBlocked = false
    private var appActive = UIApplication.shared.applicationState == .active
    private var audioInterrupted = false
    private var interruptionPausedPlayback = false
    private var stopped = false
    private let mediaObservationEnabled: Bool
    private let usesManagedAudioSession: Bool
    private let usesProgressWatchdog: Bool
    private var audioSessionClaim: UUID?
    private var audioSessionReady = false
    private var ownsIdleTimerClaim = false
    private var progressWatchdog: VideoProgressWatchdog
    private var firstFrameUptime: TimeInterval?
    private let presentationWatchID = UUID()
    private weak var videoPlanScope: VideoPlanPresentationScope?

    var isStopped: Bool { stopped }
    var hasAdmittedFirstVisualFrame: Bool { firstFrameDeadline.admitted }
    var hasActiveAudioInterruption: Bool { audioInterrupted }
    var hasPendingInterruptionFallback: Bool {
        interruptionFallbackWorkItem?.isCancelled == false
    }
    var mutedWatchMilliseconds: Int { audioWatchAccounting.mutedMilliseconds }
    var unmutedWatchMilliseconds: Int { audioWatchAccounting.unmutedMilliseconds }
    var videoPlanPresentationID: UUID { presentationWatchID }
    var currentMediaPositionSeconds: TimeInterval {
        resolvedVideoMediaPosition(
            sample: player.currentTime().seconds,
            fallback: mediaPositionSeconds
        )
    }
    var secondsSinceVideoStart: Double? {
        firstFrameUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
    }

    func attachVideoPlanScope(_ scope: VideoPlanPresentationScope?) {
        guard usesProgressWatchdog else { return }
        videoPlanScope = scope
        scope?.registerVideoPlayer(playerID: presentationWatchID)
        _ = reportPresentationWatchAccounting()
    }

    @discardableResult
    func flushPresentationWatchAccounting() -> VideoPlanPresentationWatchTotals? {
        guard usesProgressWatchdog else { return nil }
        if !stopped, firstFrameDeadline.admitted {
            let finalMediaTime = currentMediaPositionSeconds
            mediaPositionSeconds = finalMediaTime
            let finalSnapshot = finalizeVideoPlayback(
                clock: &visiblePlaybackClock,
                accounting: &audioWatchAccounting,
                finalMediaTime: finalMediaTime,
                isMuted: isMuted
            )
            playedSeconds = finalSnapshot.playedSeconds
            emitSegmentTelemetry(position: finalMediaTime)
        }
        return reportPresentationWatchAccounting()
    }

    private func reportPresentationWatchAccounting() -> VideoPlanPresentationWatchTotals? {
        videoPlanScope?.updateWatchAccounting(
            playerID: presentationWatchID,
            mutedMilliseconds: audioWatchAccounting.mutedMilliseconds,
            unmutedMilliseconds: audioWatchAccounting.unmutedMilliseconds
        )
    }

    func fireInterruptionFallbackForTests() {
        guard let workItem = interruptionFallbackWorkItem, !workItem.isCancelled else { return }
        workItem.perform()
    }

    convenience init(url: URL, posterURL: URL?) {
        self.init(
            url: url,
            posterURL: posterURL,
            startsMuted: false,
            stallTimeout: Self.preparationTimeout,
            mediaObservationEnabled: true
        )
    }

    convenience init(
        url: URL,
        posterURL: URL?,
        startsMuted: Bool,
        stallTimeout: TimeInterval
    ) {
        self.init(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout,
            mediaObservationEnabled: true
        )
    }

    static func makeStateTestingPlayer(url: URL, posterURL: URL?) -> FullscreenVideoPlayer {
        FullscreenVideoPlayer(
            url: url,
            posterURL: posterURL,
            startsMuted: false,
            stallTimeout: Self.preparationTimeout,
            mediaObservationEnabled: false
        )
    }

    private init(
        url: URL,
        posterURL: URL?,
        startsMuted: Bool,
        stallTimeout: TimeInterval,
        mediaObservationEnabled: Bool
    ) {
        self.posterURL = posterURL
        self.mediaObservationEnabled = mediaObservationEnabled
        self.usesManagedAudioSession = !startsMuted
        self.usesProgressWatchdog = stallTimeout == videoPlanV2EligibleStallTimeout
        self.progressWatchdog = VideoProgressWatchdog(budget: stallTimeout)
        // Invalid ownership degrades to an empty in-memory asset. AVPlayer never receives a remote
        // URL or /dev/null; every playable item must arrive with a retained local cache lease.
        let item = url.isFileURL && url.path != "/dev/null"
            ? AVPlayerItem(url: url)
            : AVPlayerItem(asset: AVMutableComposition())
        self.item = item
        self.player = AVPlayer(playerItem: item)
        self.audioTrackIsolation = VideoAudioTrackIsolation(item: item, startsMuted: startsMuted)
        self.isMuted = startsMuted
        player.isMuted = startsMuted
        player.actionAtItemEnd = .pause
        installObservers(mediaObservationEnabled: mediaObservationEnabled)
        if mediaObservationEnabled, appActive { schedulePreparationTimeout() }
    }

    deinit {
        preparationTimeoutWorkItem?.cancel()
        playbackTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem?.cancel()
        pendingEndGraceWorkItem?.cancel()
        interruptionFallbackWorkItem?.cancel()
        progressWatchdogWorkItem?.cancel()
        itemStatusObservation?.invalidate()
        durationObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        if let audioSessionClaim {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VideoAudioSessionCoordinator.shared.release(audioSessionClaim) }
            }
        }
        if ownsIdleTimerClaim {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VideoIdleTimerCoordinator.shared.release() }
            }
        }
    }

    func play() {
        guard !stopped else { return }
        wantsPlayback = true
        if shouldScheduleVideoInterruptionFallback(
            audioInterrupted: audioInterrupted,
            wantsPlayback: wantsPlayback,
            resumeOffered: requiresUserResume,
            fallbackPending: hasPendingInterruptionFallback
        ) {
            scheduleUnmatchedInterruptionFallback()
        }
        reconcilePlayback()
    }

    func resumeAfterInterruption() {
        guard !stopped, requiresUserResume || audioInterrupted else { return }
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        audioInterrupted = false
        interruptionPausedPlayback = false
        requiresUserResume = false
        wantsPlayback = true
        reconcilePlayback()
    }

    func setPresentationBlocked(_ blocked: Bool) {
        presentationBlocked = blocked
        reconcilePlayback()
    }

    func toggleMuted() {
        guard !stopped, firstFrameDeadline.admitted else { return }
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard !stopped, muted != isMuted else { return }
        if firstFrameDeadline.admitted {
            let mediaPosition = sampleMediaPosition()
            let snapshot = finalizeVideoPlayback(
                clock: &visiblePlaybackClock,
                accounting: &audioWatchAccounting,
                finalMediaTime: mediaPosition,
                isMuted: isMuted
            )
            mediaPositionSeconds = mediaPosition
            playedSeconds = snapshot.playedSeconds
            emitSegmentTelemetry(position: mediaPosition)
        } else {
            audioWatchAccounting.update(playedSeconds: playedSeconds, isMuted: isMuted)
        }
        _ = reportPresentationWatchAccounting()
        if !muted {
            audioTrackIsolation.unmute()
            isMuted = false
            player.isMuted = false
        } else {
            player.isMuted = true
            isMuted = true
            audioTrackIsolation.remute()
            releaseAudioSessionClaim()
        }
        reconcilePlayback()
    }

    func admitFirstVisualFrame() -> Bool {
        guard firstFrameDeadline.admit() else { return false }
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        pendingEndGraceWorkItem?.cancel()
        pendingEndGraceWorkItem = nil
        let mediaPosition = sampleMediaPosition()
        visiblePlaybackClock.admitFirstFrame(mediaTime: mediaPosition)
        firstFrameUptime = ProcessInfo.processInfo.systemUptime
        playedSeconds = 0
        emitSegmentTelemetry(position: mediaPosition)
        if usesProgressWatchdog {
            progressWatchdog.reset()
            scheduleProgressWatchdogTick()
        }
        if firstFrameDeadline.pendingEnd {
            DispatchQueue.main.async { [weak self] in self?.completePendingEndAfterFirstFrame() }
        }
        return true
    }

    func surfaceReadinessTimedOut() {
        fail(.firstFrameTimeout)
    }

    func stop() {
        guard !stopped else { return }
        _ = flushPresentationWatchAccounting()
        stopped = true
        wantsPlayback = false
        requiresUserResume = false
        firstFrameDeadline.fail()
        preparationTimeoutWorkItem?.cancel()
        preparationTimeoutWorkItem = nil
        playbackTimeoutWorkItem?.cancel()
        playbackTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        pendingEndGraceWorkItem?.cancel()
        pendingEndGraceWorkItem = nil
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        progressWatchdogWorkItem?.cancel()
        progressWatchdogWorkItem = nil
        player.pause()
        releaseAudioSessionClaim()
        releaseIdleTimerClaim()
        audioTrackIsolation.teardown()
        player.replaceCurrentItem(with: nil)
        removeObservers()
    }

    private func installObservers(mediaObservationEnabled: Bool) {
        let center = NotificationCenter.default
        if mediaObservationEnabled {
            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async { self?.handleItemStatus(item.status) }
            }
            durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async { self?.handleDuration(item.duration) }
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { self?.handleTimeControlStatus(player.timeControlStatus) }
            }
            periodicTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                // This callback only publishes the coalesced 4 Hz progress sample. Keep it direct so
                // a second queued high-frequency update path cannot accumulate behind the player.
                MainActor.assumeIsolated { self?.handlePeriodicTime(time) }
            }
            notificationObservers.append(center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in self?.enqueueObserverEvent(.ended) })
            notificationObservers.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in self?.enqueueObserverEvent(.failedToPlayToEnd) })
        }
        notificationObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.enqueueObserverEvent(.applicationActive(false)) })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.enqueueObserverEvent(.applicationActive(true)) })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.enqueueAudioInterruption(notification)
        })
    }

    /// AVFoundation and UIKit deliver these notifications on main, but publishing terminal or
    /// lifecycle state inside their callback can synchronously tear down the player from SwiftUI.
    /// Keep the Task body to one named actor method for affected Swift optimizer versions.
    private nonisolated func enqueueObserverEvent(_ event: FullscreenVideoObserverEvent) {
        Task { @MainActor [weak self] in self?.deliverObserverEvent(event) }
    }

    private nonisolated func enqueueAudioInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            enqueueObserverEvent(.audioInterruptionBegan)
        case .ended:
            enqueueObserverEvent(.audioInterruptionEnded(
                shouldResume: videoInterruptionShouldResume(notification.userInfo)
            ))
        @unknown default:
            break
        }
    }

    private func deliverObserverEvent(_ event: FullscreenVideoObserverEvent) {
        switch event {
        case .ended:
            handleEnded()
        case .failedToPlayToEnd:
            fail(.playbackFailed)
        case .applicationActive(let active):
            receiveApplicationActiveState(active)
        case .audioInterruptionBegan:
            receiveAudioInterruption(type: .began)
        case .audioInterruptionEnded(let shouldResume):
            receiveAudioInterruptionEnded(shouldResume: shouldResume)
        }
    }

    func enqueueEndedObserverCallbackForTests() {
        enqueueObserverEvent(.ended)
    }

    private func removeObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }

    private func schedulePreparationTimeout() {
        guard mediaObservationEnabled, preparationTimeoutWorkItem == nil,
              status == .preparing, appActive else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.preparationTimedOut()
        }
        preparationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.preparationTimeout, execute: workItem)
    }

    private func preparationTimedOut() {
        guard status == .preparing else { return }
        fail(.preparationTimeout)
    }

    private func handleItemStatus(_ itemStatus: AVPlayerItem.Status) {
        guard !stopped else { return }
        switch itemStatus {
        case .readyToPlay:
            updateReadyStateIfPossible()
        case .failed:
            fail(.itemFailed)
        case .unknown:
            break
        @unknown default:
            fail(.itemFailed)
        }
    }

    private func handleDuration(_ time: CMTime) {
        guard !stopped else { return }
        let seconds = time.seconds
        if seconds.isFinite, seconds > 0 {
            duration = seconds
            updateReadyStateIfPossible()
        }
    }

    private func updateReadyStateIfPossible() {
        let nextStatus = fullscreenVideoReadyStatus(
            status: status,
            itemReadyToPlay: item.status == .readyToPlay
        )
        guard nextStatus != status else { return }
        preparationTimeoutWorkItem?.cancel()
        preparationTimeoutWorkItem = nil
        status = nextStatus
        reconcilePlayback()
    }

    private func handleTimeControlStatus(_ timeControlStatus: AVPlayer.TimeControlStatus) {
        let event: VideoTimeControlEvent
        switch timeControlStatus {
        case .playing: event = .playing
        case .paused: event = .paused
        case .waitingToPlayAtSpecifiedRate: event = .waiting
        @unknown default: event = .unknown
        }
        let transition = videoTimeControlTransition(status: status, stopped: stopped, event: event)
        if transition.status != status { status = transition.status }
        switch transition.effect {
        case .beganPlaying:
            playbackTimeoutWorkItem?.cancel()
            playbackTimeoutWorkItem = nil
            scheduleFirstFrameTimeoutIfNeeded()
        case .paused:
            playbackTimeoutWorkItem?.cancel()
            playbackTimeoutWorkItem = nil
            pauseFirstFrameTimeout()
        case .waiting:
            schedulePlaybackTimeoutIfNeeded()
        case .none:
            break
        case .cancelDeadlines:
            playbackTimeoutWorkItem?.cancel()
            playbackTimeoutWorkItem = nil
            firstFrameTimeoutWorkItem?.cancel()
            firstFrameTimeoutWorkItem = nil
        }
    }

    private var segmentTelemetry = VideoSegmentTelemetryState()
    private var telemetrySegments: [VideoSegment] = []
    let segmentTelemetryEvents = PassthroughSubject<VideoSegmentTelemetryEvent, Never>()

    func configureSegmentTelemetry(_ segments: [VideoSegment]) {
        telemetrySegments = Array(segments.prefix(3))
        emitSegmentTelemetry(position: mediaPositionSeconds)
    }

    private func emitSegmentTelemetry(position: Double) {
        guard hasAdmittedFirstVisualFrame, !telemetrySegments.isEmpty else { return }
        for event in segmentTelemetry.update(
            segments: telemetrySegments, position: position, played: playedSeconds, muted: isMuted
        ) {
            segmentTelemetryEvents.send(event)
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func handlePeriodicTime(_ time: CMTime) {
        guard !stopped, firstFrameDeadline.admitted else { return }
        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0 {
            let updatedPlayedSeconds = visiblePlaybackClock.update(mediaTime: seconds)
            audioWatchAccounting.update(playedSeconds: updatedPlayedSeconds, isMuted: isMuted)
            playedSeconds = updatedPlayedSeconds
            emitSegmentTelemetry(position: seconds)
            if shouldPublishVideoProgress(previous: mediaPositionSeconds, next: seconds) {
                mediaPositionSeconds = seconds
            }
        }
    }

    private func scheduleProgressWatchdogTick() {
        guard usesProgressWatchdog, firstFrameDeadline.admitted,
              !stopped, !status.isTerminal, progressWatchdogWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.progressWatchdogTick() }
        progressWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func progressWatchdogTick() {
        progressWatchdogWorkItem = nil
        guard !stopped, !status.isTerminal else { return }
        let mediaTime = player.currentTime().seconds
        let bufferedEnd = currentBufferedEnd()
        let eligible = wantsPlayback && appActive && !presentationBlocked
            && !audioInterrupted && firstFrameDeadline.admitted
        if progressWatchdog.observe(
            now: ProcessInfo.processInfo.systemUptime,
            eligible: eligible,
            mediaTime: mediaTime,
            bufferedEnd: bufferedEnd
        ) {
            fail(.playbackTimeout)
            return
        }
        scheduleProgressWatchdogTick()
    }

    private func currentBufferedEnd() -> TimeInterval {
        item.loadedTimeRanges.compactMap { value -> TimeInterval? in
            let end = CMTimeRangeGetEnd(value.timeRangeValue).seconds
            return end.isFinite ? end : nil
        }.max() ?? 0
    }

    private func pauseProgressWatchdog() {
        guard usesProgressWatchdog, firstFrameDeadline.admitted else { return }
        _ = progressWatchdog.observe(
            now: ProcessInfo.processInfo.systemUptime,
            eligible: false,
            mediaTime: player.currentTime().seconds,
            bufferedEnd: currentBufferedEnd()
        )
        progressWatchdogWorkItem?.cancel()
        progressWatchdogWorkItem = nil
    }

    private func handleEnded() {
        guard !stopped, !isFailed else { return }
        guard firstFrameDeadline.admitted else {
            guard firstFrameDeadline.deferEndUntilFrame() else { return }
            wantsPlayback = false
            player.pause()
            releaseIdleTimerClaim()
            releaseAudioSessionClaim()
            schedulePendingEndGraceIfNeeded()
            return
        }
        completeEnded()
    }

    private func completePendingEndAfterFirstFrame() {
        guard firstFrameDeadline.consumePendingEnd() else { return }
        completeEnded()
    }

    private func completeEnded() {
        guard !stopped, !isFailed, status != .ended else { return }
        let finalMediaTime = sampleMediaPosition()
        let finalSnapshot = finalizeVideoPlayback(
            clock: &visiblePlaybackClock,
            accounting: &audioWatchAccounting,
            finalMediaTime: finalMediaTime,
            isMuted: isMuted
        )
        playedSeconds = finalSnapshot.playedSeconds
        emitSegmentTelemetry(position: finalMediaTime)
        _ = reportPresentationWatchAccounting()
        wantsPlayback = false
        playbackTimeoutWorkItem?.cancel()
        playbackTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        pendingEndGraceWorkItem?.cancel()
        pendingEndGraceWorkItem = nil
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        progressWatchdogWorkItem?.cancel()
        progressWatchdogWorkItem = nil
        releaseIdleTimerClaim()
        releaseAudioSessionClaim()
        status = .ended
    }

    @discardableResult
    func sampleMediaPosition() -> TimeInterval {
        let position = currentMediaPositionSeconds
        if shouldPublishVideoProgress(previous: mediaPositionSeconds, next: position) {
            mediaPositionSeconds = position
        }
        return position
    }

    private func fail(_ reason: FullscreenVideoFailure) {
        guard !stopped, !isFailed, status != .ended else { return }
        _ = flushPresentationWatchAccounting()
        firstFrameDeadline.fail()
        preparationTimeoutWorkItem?.cancel()
        preparationTimeoutWorkItem = nil
        playbackTimeoutWorkItem?.cancel()
        playbackTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        pendingEndGraceWorkItem?.cancel()
        pendingEndGraceWorkItem = nil
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        progressWatchdogWorkItem?.cancel()
        progressWatchdogWorkItem = nil
        wantsPlayback = false
        player.pause()
        releaseIdleTimerClaim()
        releaseAudioSessionClaim()
        status = .failed(reason)
    }

    func receiveApplicationActiveState(_ active: Bool) {
        guard !stopped else { return }
        appActive = active
        if active {
            offerResumeForUnmatchedAudioInterruption()
            schedulePreparationTimeout()
        } else {
            preparationTimeoutWorkItem?.cancel()
            preparationTimeoutWorkItem = nil
        }
        reconcilePlayback()
    }

    func receiveAudioInterruption(
        type: AVAudioSession.InterruptionType,
        userInfo: [AnyHashable: Any]? = nil
    ) {
        guard !stopped else { return }
        switch type {
        case .began:
            interruptionPausedPlayback = wantsPlayback && appActive && !presentationBlocked
            audioInterrupted = true
            reconcilePlayback()
            scheduleUnmatchedInterruptionFallback()
        case .ended:
            receiveAudioInterruptionEnded(shouldResume: videoInterruptionShouldResume(userInfo))
        @unknown default:
            break
        }
    }

    private func receiveAudioInterruptionEnded(shouldResume: Bool) {
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        audioInterrupted = false
        let action = videoInterruptionEndAction(
            pausedByInterruption: interruptionPausedPlayback,
            userInfo: [
                AVAudioSessionInterruptionOptionKey:
                    shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0,
            ]
        )
        interruptionPausedPlayback = false
        applyInterruptionEndAction(action)
    }

    func applyInterruptionEndAction(_ action: VideoInterruptionEndAction) {
        guard !stopped else { return }
        switch action {
        case .reconcile:
            requiresUserResume = false
            reconcilePlayback()
        case .resume:
            requiresUserResume = false
            reconcilePlayback()
        case .stayPaused:
            wantsPlayback = false
            requiresUserResume = true
            reconcilePlayback()
        }
    }

    private func scheduleUnmatchedInterruptionFallback() {
        interruptionFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.interruptionFallbackWorkItem = nil
            guard self.appActive else { return }
            self.offerResumeForUnmatchedAudioInterruption()
        }
        interruptionFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.unmatchedInterruptionFallback,
            execute: workItem
        )
    }

    private func offerResumeForUnmatchedAudioInterruption() {
        guard !stopped, !isFailed, status != .ended, audioInterrupted else { return }
        requiresUserResume = shouldOfferVideoInterruptionResume(
            audioInterrupted: audioInterrupted,
            wantsPlayback: wantsPlayback
        )
        reconcilePlayback()
    }

    private func reconcilePlayback() {
        guard !stopped, !isFailed, status != .ended else { return }
        if firstFrameDeadline.pendingEnd {
            if appActive && !presentationBlocked && !audioInterrupted {
                schedulePendingEndGraceIfNeeded()
            } else {
                pendingEndGraceWorkItem?.cancel()
                pendingEndGraceWorkItem = nil
            }
            releaseAudioSessionClaim()
            pauseProgressWatchdog()
            player.pause()
            return
        }
        let canPlay = shouldPlayFullscreenVideo(
            wantsPlayback: wantsPlayback,
            requiresUserResume: requiresUserResume,
            appActive: appActive,
            presentationBlocked: presentationBlocked,
            audioInterrupted: audioInterrupted,
            itemReadyToPlay: item.status == .readyToPlay
        )
        if canPlay {
            if !ownsIdleTimerClaim {
                VideoIdleTimerCoordinator.shared.claim()
                ownsIdleTimerClaim = true
            }
            if !isMuted, usesManagedAudioSession, !audioSessionReady {
                if audioSessionClaim == nil {
                    audioSessionClaim = VideoAudioSessionCoordinator.shared.claim { [weak self] success in
                        self?.audioSessionActivationFinished(success)
                    }
                    if audioSessionClaim == nil { continueWithoutAudioSession() }
                }
                return
            }
            scheduleFirstFrameTimeoutIfNeeded()
            if isMuted { audioTrackIsolation.prepareMutedPlayback() }
            player.play()
            scheduleProgressWatchdogTick()
        } else {
            releaseIdleTimerClaim()
            releaseAudioSessionClaim()
            pauseProgressWatchdog()
            playbackTimeoutWorkItem?.cancel()
            playbackTimeoutWorkItem = nil
            pauseFirstFrameTimeout()
            player.pause()
        }
    }

    private func audioSessionActivationFinished(_ success: Bool) {
        guard audioSessionClaim != nil, !stopped, !isFailed, status != .ended else { return }
        guard success else {
            continueWithoutAudioSession()
            return
        }
        audioSessionReady = true
        reconcilePlayback()
    }

    func continueWithoutAudioSession() {
        guard !stopped, !isFailed, status != .ended else { return }
        releaseAudioSessionClaim()
        Telemetry.shared.recordError(signature: "video:audio_activation_unavailable")
        setMuted(true)
    }

    private func releaseAudioSessionClaim() {
        if let audioSessionClaim { VideoAudioSessionCoordinator.shared.release(audioSessionClaim) }
        audioSessionClaim = nil
        audioSessionReady = false
    }

    private func releaseIdleTimerClaim() {
        guard ownsIdleTimerClaim else { return }
        ownsIdleTimerClaim = false
        VideoIdleTimerCoordinator.shared.release()
    }

    private func schedulePlaybackTimeoutIfNeeded() {
        guard !usesProgressWatchdog else { return }
        guard playbackTimeoutWorkItem == nil,
              shouldArmVideoStallDeadline(
                  wantsPlayback: wantsPlayback,
                  appActive: appActive,
                  presentationBlocked: presentationBlocked,
                  audioInterrupted: audioInterrupted
              ) else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.playbackTimedOut()
        }
        playbackTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.preparationTimeout, execute: workItem)
    }

    private func playbackTimedOut() {
        playbackTimeoutWorkItem = nil
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        fail(.playbackTimeout)
    }

    private func scheduleFirstFrameTimeoutIfNeeded() {
        guard mediaObservationEnabled, firstFrameDeadline.arm() else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.firstFrameTimedOut()
        }
        firstFrameTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout, execute: workItem)
    }

    private func pauseFirstFrameTimeout() {
        guard !firstFrameDeadline.admitted else { return }
        firstFrameDeadline.pause()
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
    }

    private func firstFrameTimedOut() {
        firstFrameTimeoutWorkItem = nil
        guard firstFrameDeadline.timeout() else { return }
        fail(.firstFrameTimeout)
    }

    private func schedulePendingEndGraceIfNeeded() {
        guard firstFrameDeadline.pendingEnd, pendingEndGraceWorkItem == nil,
              appActive, !presentationBlocked, !audioInterrupted else { return }
        let workItem = DispatchWorkItem { [weak self] in self?.pendingEndGraceTimedOut() }
        pendingEndGraceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pendingEndFrameGrace,
            execute: workItem
        )
    }

    private func pendingEndGraceTimedOut() {
        pendingEndGraceWorkItem = nil
        guard firstFrameDeadline.pendingEnd, !firstFrameDeadline.admitted else { return }
        fail(.firstFrameTimeout)
    }
}

func videoInterruptionShouldResume(_ userInfo: [AnyHashable: Any]?) -> Bool {
    guard let raw = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return false }
    return AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
}

@MainActor
final class FullscreenVideoPreparationPool {
    static let shared = FullscreenVideoPreparationPool()
    static let maxPreparedPlayers = 3
    static let preparedRetention: TimeInterval = 5 * 60

    private struct Entry {
        let url: URL
        let posterURL: URL?
        let startsMuted: Bool
        let stallTimeout: TimeInterval
        let player: FullscreenVideoPlayer
        let assetLease: VideoAssetLease?
        var active: Bool
        var lastTouched: TimeInterval
        var expiry: DispatchWorkItem?
    }

    private var entries: [FullscreenVideoPreparationToken: Entry] = [:]
    private let capacity: Int
    private let retention: TimeInterval
    private let retentionPolicy: VideoPreparationRetentionPolicy
    private let now: () -> TimeInterval

    convenience init() {
        self.init(capacity: Self.maxPreparedPlayers, retention: Self.preparedRetention)
    }

    convenience init(capacity: Int) {
        self.init(capacity: capacity, retention: Self.preparedRetention)
    }

    init(
        capacity: Int,
        retention: TimeInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.capacity = max(0, capacity)
        self.retention = max(0, retention)
        self.now = now
        self.retentionPolicy = VideoPreparationRetentionPolicy(
            capacity: max(0, capacity),
            retention: max(0, retention)
        )
    }

    func prepare(
        url: URL,
        posterURL: URL?,
        startsMuted: Bool = false,
        stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout,
        assetLease: VideoAssetLease? = nil
    ) -> FullscreenVideoPreparationToken? {
        guard makeRoomForPlayer() else { return nil }
        let poolAssetLease = assetLease?.retained()
        let token = FullscreenVideoPreparationToken()
        let player = FullscreenVideoPlayer(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout
        )
        entries[token] = Entry(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout,
            player: player,
            assetLease: poolAssetLease,
            active: false,
            lastTouched: now(),
            expiry: nil
        )
        scheduleExpiry(for: token)
        return token
    }

    func claim(
        _ token: FullscreenVideoPreparationToken,
        url: URL,
        posterURL: URL?,
        startsMuted: Bool = false,
        stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout
    ) -> FullscreenVideoPlayer? {
        if entries[token]?.active == true { return nil }
        if var entry = entries[token], entry.url == url, entry.posterURL == posterURL,
           entry.startsMuted == startsMuted, entry.stallTimeout == stallTimeout,
           shouldReusePreparedVideoPlayer(
               status: entry.player.status,
               isStopped: entry.player.isStopped,
               isActive: entry.active
           ) {
            entry.expiry?.cancel()
            entry.expiry = nil
            entry.active = true
            entry.lastTouched = now()
            entries[token] = entry
            return entry.player
        }
        guard let stale = entries[token], stale.url == url, stale.posterURL == posterURL,
              stale.startsMuted == startsMuted, stale.stallTimeout == stallTimeout else {
            release(token)
            return nil
        }
        stale.expiry?.cancel()
        stale.player.stop()
        let player = FullscreenVideoPlayer(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout
        )
        entries[token] = Entry(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout,
            player: player,
            assetLease: stale.assetLease,
            active: true,
            lastTouched: now(),
            expiry: nil
        )
        return player
    }

    func returnToPrepared(_ token: FullscreenVideoPreparationToken) {
        guard var entry = entries[token] else { return }
        entry.active = false
        entry.lastTouched = now()
        entries[token] = entry
        scheduleExpiry(for: token)
    }

    func release(_ token: FullscreenVideoPreparationToken?) {
        guard let token, let entry = entries.removeValue(forKey: token) else { return }
        entry.expiry?.cancel()
        entry.player.stop()
        entry.assetLease?.release()
    }

    func localURL(for token: FullscreenVideoPreparationToken) -> URL? {
        entries[token]?.url
    }

    func discardPrepared(_ token: FullscreenVideoPreparationToken?) {
        guard let token, entries[token]?.active == false else { return }
        release(token)
    }

    private func makeRoomForPlayer() -> Bool {
        purgeExpired()
        while entries.count >= capacity {
            let policyEntries = entries.map {
                VideoPreparationRetentionPolicy.Entry(
                    id: $0.key.id,
                    active: $0.value.active,
                    lastTouched: $0.value.lastTouched
                )
            }
            guard let candidateID = retentionPolicy.evictionCandidate(policyEntries),
                  let candidate = entries.keys.first(where: { $0.id == candidateID }) else { return false }
            release(candidate)
        }
        return true
    }

    private func purgeExpired() {
        let now = now()
        let policyEntries = entries.map {
            VideoPreparationRetentionPolicy.Entry(
                id: $0.key.id,
                active: $0.value.active,
                lastTouched: $0.value.lastTouched
            )
        }
        let expiredIDs = Set(retentionPolicy.expiredEntryIDs(policyEntries, now: now))
        let expired = entries.keys.filter { expiredIDs.contains($0.id) }
        expired.forEach { release($0) }
    }

    private func scheduleExpiry(for token: FullscreenVideoPreparationToken) {
        guard var entry = entries[token], !entry.active else { return }
        entry.expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.expire(token) }
        entry.expiry = work
        entries[token] = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + retention, execute: work)
    }

    private func expire(_ token: FullscreenVideoPreparationToken) {
        guard let entry = entries[token], !entry.active,
              now() - entry.lastTouched >= retention else { return }
        release(token)
    }
}

@MainActor
final class FullscreenVideoPreparationOwnership {
    enum State: Equatable {
        case ad
        case claimed
        case presentation
        case released
    }

    let token: FullscreenVideoPreparationToken
    private(set) var state = State.ad

    init(token: FullscreenVideoPreparationToken) {
        self.token = token
    }

    func claim(
        url: URL,
        posterURL: URL?,
        startsMuted: Bool = false,
        stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout
    ) -> FullscreenVideoPlayer? {
        guard state == .ad else { return nil }
        guard let player = FullscreenVideoPreparationPool.shared.claim(
            token,
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout
        ) else { return nil }
        state = .claimed
        return player
    }

    func transferToPresentation() -> Bool {
        guard state == .claimed else { return false }
        state = .presentation
        return true
    }

    func returnToAdAfterPresentationFailure() -> Bool {
        guard state == .presentation else { return false }
        FullscreenVideoPreparationPool.shared.returnToPrepared(token)
        state = .ad
        return true
    }

    func releaseFromAd() -> Bool {
        guard state == .ad || state == .claimed else { return false }
        release()
        return true
    }

    func releaseFromPresentation() -> Bool {
        guard state == .presentation else { return false }
        release()
        return true
    }

    private func release() {
        FullscreenVideoPreparationPool.shared.release(token)
        state = .released
    }

    deinit {
        guard state != .released else { return }
        let token = token
        DispatchQueue.main.async {
            FullscreenVideoPreparationPool.shared.release(token)
        }
    }
}

enum FullscreenVideoPreparationReservation {
    case notRequired
    case reserved(FullscreenVideoPreparationOwnership)
    case cold
}

@MainActor
func reserveFullscreenVideoPreparation(
    for creative: FullscreenCreativeContent,
    startsMuted: Bool = false,
    stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout,
    assetLease: VideoAssetLease? = nil
) -> FullscreenVideoPreparationReservation {
    reserveFullscreenVideoPreparation(for: creative) { url, posterURL in
        FullscreenVideoPreparationPool.shared.prepare(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout,
            assetLease: assetLease
        )
    }
}

@MainActor
func reserveFullscreenVideoPreparation(
    for creative: FullscreenCreativeContent,
    prepare: (URL, URL?) -> FullscreenVideoPreparationToken?
) -> FullscreenVideoPreparationReservation {
    guard case .video(let url, let posterURL) = creative else { return .notRequired }
    guard let token = prepare(url, posterURL) else { return .cold }
    return .reserved(FullscreenVideoPreparationOwnership(token: token))
}

final class VideoLayerView: UIView {
    static let readinessTimeout: TimeInterval = 10

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var readyObservation: NSKeyValueObservation?
    private weak var installedPlayer: AVPlayer?
    private var firstFrameReported = false
    private var installationGeneration: UInt64 = 0
    private var presentationActive = false
    private var readinessDeadline = VideoFirstFrameDeadlineState()
    private var readinessTimeoutWorkItem: DispatchWorkItem?
    private var onFirstFrame: (() -> Void)?
    private var onReadinessTimeout: (() -> Void)?

    func install(
        player: AVPlayer?,
        presentationActive: Bool,
        onFirstFrame: @escaping () -> Void,
        onReadinessTimeout: @escaping () -> Void
    ) {
        guard let playerLayer = layer as? AVPlayerLayer else { return }
        playerLayer.videoGravity = .resizeAspect
        self.presentationActive = presentationActive
        self.onFirstFrame = onFirstFrame
        self.onReadinessTimeout = onReadinessTimeout
        guard installedPlayer !== player else {
            reconcileReadinessDeadline()
            return
        }
        installationGeneration &+= 1
        let generation = installationGeneration
        readyObservation?.invalidate()
        readyObservation = nil
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        readinessDeadline = VideoFirstFrameDeadlineState()
        installedPlayer = player
        firstFrameReported = false
        playerLayer.player = player
        guard let player else {
            reconcileReadinessDeadline()
            return
        }
        let playerIdentity = ObjectIdentifier(player)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            let observedLayer = layer
            DispatchQueue.main.async { [weak self, weak observedLayer, weak player] in
                guard let self, let observedLayer, player != nil,
                      shouldAcceptVideoLayerReadyCallback(
                          callbackGeneration: generation,
                          installationGeneration: self.installationGeneration,
                          callbackPlayerIdentity: playerIdentity,
                          installedPlayerIdentity: self.installedPlayer.map(ObjectIdentifier.init),
                          callbackLayerIdentity: ObjectIdentifier(observedLayer),
                          installedLayerIdentity: ObjectIdentifier(self.layer),
                          layerPlayerIdentity: observedLayer.player.map(ObjectIdentifier.init),
                          isReadyForDisplay: observedLayer.isReadyForDisplay,
                          firstFrameReported: self.firstFrameReported
                      ) else { return }
                guard self.readinessDeadline.admit() else { return }
                self.firstFrameReported = true
                self.readyObservation?.invalidate()
                self.readyObservation = nil
                self.readinessTimeoutWorkItem?.cancel()
                self.readinessTimeoutWorkItem = nil
                self.onFirstFrame?()
            }
        }
        reconcileReadinessDeadline()
    }

    func uninstall() {
        installationGeneration &+= 1
        presentationActive = false
        readinessDeadline.fail()
        readyObservation?.invalidate()
        readyObservation = nil
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        installedPlayer = nil
        firstFrameReported = false
        onFirstFrame = nil
        onReadinessTimeout = nil
        (layer as? AVPlayerLayer)?.player = nil
    }

    func fireCurrentReadinessDeadline() {
        readinessDeadlineFired(generation: installationGeneration)
    }

    private func reconcileReadinessDeadline() {
        guard presentationActive, installedPlayer != nil, !firstFrameReported else {
            readinessDeadline.pause()
            readinessTimeoutWorkItem?.cancel()
            readinessTimeoutWorkItem = nil
            return
        }
        guard readinessDeadline.arm() else { return }
        let generation = installationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.readinessDeadlineFired(generation: generation)
        }
        readinessTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.readinessTimeout,
            execute: workItem
        )
    }

    private func readinessDeadlineFired(generation: UInt64) {
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        guard generation == installationGeneration, presentationActive,
              readinessDeadline.timeout() else { return }
        onReadinessTimeout?()
    }
}

private struct VideoLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    let presentationActive: Bool
    let onFirstFrame: () -> Void
    let onReadinessTimeout: () -> Void

    func makeUIView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.backgroundColor = .black
        view.install(
            player: player,
            presentationActive: presentationActive,
            onFirstFrame: onFirstFrame,
            onReadinessTimeout: onReadinessTimeout
        )
        return view
    }

    func updateUIView(_ view: VideoLayerView, context: Context) {
        view.install(
            player: player,
            presentationActive: presentationActive,
            onFirstFrame: onFirstFrame,
            onReadinessTimeout: onReadinessTimeout
        )
    }

    static func dismantleUIView(_ view: VideoLayerView, coordinator: ()) {
        view.uninstall()
    }
}

struct VideoPreFirstFrameEscapeButton: View {
    let action: () -> Void
    let accessibilityLabel: String

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct FullscreenVideoSurface: View {
    @ObservedObject var videoPlayer: FullscreenVideoPlayer
    let presentationActive: Bool
    let onTap: () -> Void
    let onFirstFrame: () -> Bool
    let controlsEnabled: Bool
    var chromeConfiguration: VideoChromeConfiguration? = nil
    var effectiveClosePosition: ClosePosition = .topRight
    var bottomProgressBarObstructsChrome = false
    var storePromptVisible = false
    var storePromptSharesMuteCorner = false
    var onMuteChanged: ((Bool) -> Void)? = nil
    var telemetryPauseReason: () -> String = { FullscreenVideoTerminationReason.playback }
    var onTelemetryEvent: ((VideoSurfaceTelemetryEvent) -> Void)? = nil
    var segments: [VideoSegment] = []
    @State private var firstFrameHandoff = VideoSurfaceFirstFrameHandoffState()
    @State private var quartileState = VideoQuartileState()
    @State private var pauseTelemetryState = VideoPauseTelemetryState()

    private var showsFirstFrame: Bool {
        videoSurfaceShowsFirstFrame(
            localPlayerIdentity: firstFrameHandoff.readyLayerPlayerIdentity,
            currentPlayerIdentity: ObjectIdentifier(videoPlayer)
        )
    }

    private var muteControlPlacement: VideoMuteControlPlacement {
        videoMuteControlPlacement(
            hasVideoChrome: chromeConfiguration != nil,
            effectiveClosePosition: effectiveClosePosition
        )
    }

    private var additionalBottomLeadingPadding: CGFloat {
        guard let chromeConfiguration else { return 0 }
        return CGFloat(videoChromeAdditionalLeadingPadding(
            effectiveClosePosition: effectiveClosePosition,
            resolvedStyle: chromeConfiguration.style
        ))
    }

    private var additionalBottomPadding: CGFloat {
        CGFloat(videoChromeAdditionalBottomPadding(
            bottomProgressBarObstructsChrome: bottomProgressBarObstructsChrome
        ))
    }

    var body: some View {
        ZStack {
            if let posterURL = videoPlayer.posterURL {
                CachedAsyncImage(url: posterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Color.black
                    }
                }
            }

            VideoLayerRepresentable(
                player: videoPlayer.player,
                presentationActive: presentationActive,
                onFirstFrame: {
                    let playerIdentity = ObjectIdentifier(videoPlayer)
                    firstFrameHandoff.layerBecameReady(
                        playerIdentity: playerIdentity,
                        currentPlayerIdentity: playerIdentity
                    )
                    attemptParentHandoff()
                },
                onReadinessTimeout: { videoPlayer.surfaceReadinessTimedOut() }
            )
            .opacity(showsFirstFrame ? 1 : 0)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if controlsEnabled { onTap() }
                }
                .allowsHitTesting(!videoPlayer.requiresUserResume)

            if videoPlayer.requiresUserResume {
                Button(action: { videoPlayer.resumeAfterInterruption() }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume ad video")
            }

            VStack {
                HStack {
                    if controlsEnabled, muteControlPlacement == .topLeading {
                        muteButton
                            .padding(.horizontal, 12)
                            .padding(.top, videoMuteTopPadding(
                                hasVideoChrome: chromeConfiguration != nil,
                                storePromptVisible: storePromptVisible,
                                storePromptSharesMuteCorner: storePromptSharesMuteCorner
                            ))
                    }
                    Spacer()
                    if controlsEnabled, muteControlPlacement == .topTrailing {
                        muteButton
                            .padding(.horizontal, 12)
                            .padding(.top, videoMuteTopPadding(
                                hasVideoChrome: chromeConfiguration != nil,
                                storePromptVisible: storePromptVisible,
                                storePromptSharesMuteCorner: storePromptSharesMuteCorner
                            ))
                    }
                }
                Spacer()
                if controlsEnabled, let chromeConfiguration {
                    VideoCreativeChrome(configuration: chromeConfiguration, action: onTap)
                        .padding(.leading, additionalBottomLeadingPadding)
                        .padding(.bottom, additionalBottomPadding)
                        .padding(12)
                } else if controlsEnabled {
                    HStack {
                        Spacer()
                        muteButton.padding(12)
                    }
                }
            }
        }
        .background(Color.black)
        .onAppear {
            videoPlayer.configureSegmentTelemetry(segments)
            firstFrameHandoff.setPresentationActive(presentationActive)
            firstFrameHandoff.surfaceDidAppear()
            attemptParentHandoff()
            videoPlayer.play()
        }
        .onDisappear {
            firstFrameHandoff.surfaceDidDisappear()
        }
        .onChange(of: presentationActive) { active in
            firstFrameHandoff.setPresentationActive(active)
            attemptParentHandoff()
        }
        .onReceive(videoPlayer.$mediaPositionSeconds) { position in
            guard onTelemetryEvent != nil else { return }
            guard segments.isEmpty else { return }
            for quartile in quartileState.crossed(position: position, duration: videoPlayer.duration) {
                onTelemetryEvent?(.quartile(quartile))
            }
        }
        .onReceive(videoPlayer.segmentTelemetryEvents) { event in
            onTelemetryEvent?(.segment(event))
        }
        .onReceive(videoPlayer.$status) { status in
            guard onTelemetryEvent != nil, videoPlayer.hasAdmittedFirstVisualFrame else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch status {
            case .paused:
                if let duration = videoPlayer.duration,
                   videoPlayer.currentMediaPositionSeconds >= max(0, duration - 0.15) { return }
                if let reason = pauseTelemetryState.pause(
                    now: now,
                    reasonProvider: telemetryPauseReason
                ) {
                    onTelemetryEvent?(.pause(reason: reason))
                }
            case .playing:
                if let resumed = pauseTelemetryState.resume(now: now) {
                    onTelemetryEvent?(.resume(reason: resumed.reason, pausedMs: resumed.pausedMs))
                }
            case .preparing, .ready, .ended, .failed:
                break
            }
        }
    }

    private var muteButton: some View {
        Button(action: {
            videoPlayer.toggleMuted()
            onMuteChanged?(videoPlayer.isMuted)
        }) {
            Image(systemName: videoPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(videoPlayer.isMuted ? "Unmute ad" : "Mute ad")
    }

    private func attemptParentHandoff() {
        let playerIdentity = ObjectIdentifier(videoPlayer)
        guard firstFrameHandoff.shouldAttemptParentHandoff(
            currentPlayerIdentity: playerIdentity
        ) else { return }
        videoPlayer.sampleMediaPosition()
        guard firstFrameHandoff.parentResponded(accepted: onFirstFrame()) else { return }
        guard videoPlayer.hasAdmittedFirstVisualFrame || videoPlayer.admitFirstVisualFrame() else {
            videoPlayer.surfaceReadinessTimedOut()
            return
        }
    }
}

private struct VideoCreativeChrome: View {
    let configuration: VideoChromeConfiguration
    let action: () -> Void

    var body: some View {
        switch configuration.style {
        case .bottomBar:
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 8)
                cta
            }
            .padding(10)
            .frame(maxWidth: 560)
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .floatingPill:
            HStack(spacing: 8) {
                identity
                cta
            }
            .padding(8)
            .frame(maxWidth: 360)
            .background(Color.black.opacity(0.88))
            .clipShape(Capsule())
        case .bottomCard:
            HStack(spacing: 12) {
                identity
                Spacer(minLength: 8)
                cta
            }
            .padding(14)
            .frame(maxWidth: 440)
            .background(Color.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        case .cornerCTA:
            HStack {
                Spacer()
                cta
            }
        case .feedCard:
            VStack(alignment: .leading, spacing: 10) {
                identity
                cta.frame(maxWidth: .infinity)
            }
            .padding(14)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var identity: some View {
        HStack(spacing: 9) {
            if let url = configuration.appIconURL {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            if let title = configuration.title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let subtitle = configuration.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var cta: some View {
        Button(action: action) {
            Text(configuration.cta)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 16)
                .frame(maxWidth: 180)
                .frame(minHeight: 40)
                .background(Color(red: 0.05, green: 0.36, blue: 0.95))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.cta)
    }
}
#else
@MainActor
final class FullscreenVideoPlayer {}
#endif
