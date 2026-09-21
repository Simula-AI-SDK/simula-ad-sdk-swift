import Foundation

let videoPlanV2EligibleStallTimeout: TimeInterval = 8

struct VideoPlaybackGate: Equatable, Sendable {
    let configuredDelay: TimeInterval
    private(set) var duration: TimeInterval?
    private(set) var played: TimeInterval = 0
    private(set) var ended = false

    init(configuredDelay: TimeInterval) {
        self.configuredDelay = min(TimeInterval(maxCloseDelaySeconds), max(0, configuredDelay))
    }

    mutating func update(duration: TimeInterval?, played: TimeInterval, ended: Bool = false) {
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        }
        if played.isFinite {
            self.played = max(self.played, max(0, played))
        }
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
        return played >= duration / 2
    }

    var earnedCompletionReason: RewardCompletionReason? {
        guard isUnlocked else { return nil }
        if played >= configuredDelay { return .durationElapsed }
        return .videoCompleted
    }
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

func canUseVideoControls(firstFrameAdmitted: Bool, displayAdmitted: Bool) -> Bool {
    firstFrameAdmitted && displayAdmitted
}

func shouldAutomaticallyAdvanceCompletedVideo(
    usesVideoPlanV2: Bool,
    status: FullscreenVideoStatus
) -> Bool {
    usesVideoPlanV2 && status == .ended
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
    guard presentationMounted,
          shouldShowVideoPreFirstFrameEscape(
              firstFrameAdmitted: firstFrameAdmitted,
              terminal: terminal
          ) else { return .none }
    switch surface {
    case .interstitial: return .failInterstitialDisplay
    case .rewarded: return .finishRewardedUnearned
    case .fallback: return .requestFallbackFailureAdvance
    }
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

struct VideoQuartileState: Equatable, Sendable {
    private var emitted: Set<Int> = []

    mutating func crossed(position: TimeInterval, duration: TimeInterval?) -> [Int] {
        guard position.isFinite, position >= 0, let duration,
              duration.isFinite, duration > 0 else { return [] }
        return [25, 50, 75].filter { quartile in
            guard !emitted.contains(quartile), position / duration >= Double(quartile) / 100 else {
                return false
            }
            emitted.insert(quartile)
            return true
        }
    }
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
        let result = (reason ?? "playback", (now - startedAt) * 1_000)
        self.startedAt = nil
        reason = nil
        return result
    }
}

enum VideoSurfaceTelemetryEvent: Equatable, Sendable {
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
    on: String? = nil
) {
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
    let mutedSeconds = mutedWatchMs.map { Double($0) / 1_000 }
    let unmutedSeconds = unmutedWatchMs.map { Double($0) / 1_000 }
    let watchedSeconds = (mutedWatchMs != nil || unmutedWatchMs != nil)
        ? Double((mutedWatchMs ?? 0) + (unmutedWatchMs ?? 0)) / 1_000
        : nil
    Telemetry.shared.recordVideoLifecycle(
        stage: stage,
        adFormat: adFormat,
        adUnitId: adUnitId,
        adId: adId,
        serveId: serveId,
        errorCode: errorCode,
        clipIndex: creative?.clipIndex,
        muted: muted,
        impressionId: serveId ?? adId,
        style: style,
        skoverlayEnabled: overlay != nil,
        skoverlayDelaySeconds: overlay?.delaySeconds,
        videoPositionS: videoPositionS,
        pool: creative?.videoPool,
        durationS: durationS,
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

func videoChromeConfiguration(
    creative: Creative?,
    behavior: AdBehavior?,
    isVideoPlanV2: Bool
) -> VideoChromeConfiguration? {
    guard isVideoPlanV2, let creative, creative.usesVideoPlanV2 else { return nil }
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

#if os(iOS)
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Reference-counted because the next clip can become active before the prior player is released.
/// The host's exact category/mode/options are restored when the last V2 player leaves playback.
@MainActor
private final class VideoAudioSessionCoordinator {
    static let shared = VideoAudioSessionCoordinator()
    private var claims = 0

    func claim() -> Bool {
        if claims > 0 {
            claims += 1
            return true
        }
        let activated = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
        if activated {
            claims = 1
            return true
        }
        return false
    }

    func release() {
        guard claims > 0 else { return }
        claims -= 1
        // Activation can be shared with the host and AVPlayer exposes no ownership query. Never
        // deactivate or restore a stale category snapshot from SDK teardown.
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
            MainActor.assumeIsolated { self?.mediaSelectionDidChange() }
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
    @Published private(set) var playedSeconds: TimeInterval = 0
    @Published private(set) var isMuted = true
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
    private var ownsAudioSessionClaim = false
    private var progressWatchdog: VideoProgressWatchdog
    private var firstFrameUptime: TimeInterval?

    var isStopped: Bool { stopped }
    var hasAdmittedFirstVisualFrame: Bool { firstFrameDeadline.admitted }
    var hasActiveAudioInterruption: Bool { audioInterrupted }
    var hasPendingInterruptionFallback: Bool {
        interruptionFallbackWorkItem?.isCancelled == false
    }
    var mutedWatchMilliseconds: Int { audioWatchAccounting.mutedMilliseconds }
    var unmutedWatchMilliseconds: Int { audioWatchAccounting.unmutedMilliseconds }
    var secondsSinceVideoStart: Double? {
        firstFrameUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
    }

    func fireInterruptionFallbackForTests() {
        guard let workItem = interruptionFallbackWorkItem, !workItem.isCancelled else { return }
        workItem.perform()
    }

    convenience init(url: URL, posterURL: URL?) {
        self.init(
            url: url,
            posterURL: posterURL,
            startsMuted: true,
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
            startsMuted: true,
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
        let item = AVPlayerItem(url: url)
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
        if ownsAudioSessionClaim {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VideoAudioSessionCoordinator.shared.release() }
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
        audioWatchAccounting.update(playedSeconds: playedSeconds, isMuted: isMuted)
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
        visiblePlaybackClock.admitFirstFrame(mediaTime: player.currentTime().seconds)
        firstFrameUptime = ProcessInfo.processInfo.systemUptime
        playedSeconds = 0
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
        if ownsAudioSessionClaim {
            releaseAudioSessionClaim()
        }
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
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                DispatchQueue.main.async { self?.handlePeriodicTime(time) }
            }
            notificationObservers.append(center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in DispatchQueue.main.async { self?.handleEnded() } })
            notificationObservers.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in DispatchQueue.main.async { self?.fail(.playbackFailed) } })
        }
        notificationObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.receiveApplicationActiveState(false) } })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.receiveApplicationActiveState(true) } })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            DispatchQueue.main.async { self?.handleAudioInterruption(notification) }
        })
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

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func handlePeriodicTime(_ time: CMTime) {
        guard !stopped, firstFrameDeadline.admitted else { return }
        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0 {
            playedSeconds = visiblePlaybackClock.update(mediaTime: seconds)
            audioWatchAccounting.update(playedSeconds: playedSeconds, isMuted: isMuted)
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
        let finalSnapshot = finalizeVideoPlayback(
            clock: &visiblePlaybackClock,
            accounting: &audioWatchAccounting,
            finalMediaTime: player.currentTime().seconds,
            isMuted: isMuted
        )
        playedSeconds = finalSnapshot.playedSeconds
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
        status = .ended
    }

    private func fail(_ reason: FullscreenVideoFailure) {
        guard !stopped, !isFailed, status != .ended else { return }
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

    private func handleAudioInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        receiveAudioInterruption(type: type, userInfo: notification.userInfo)
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
            interruptionFallbackWorkItem?.cancel()
            interruptionFallbackWorkItem = nil
            audioInterrupted = false
            let action = videoInterruptionEndAction(
                pausedByInterruption: interruptionPausedPlayback,
                userInfo: userInfo
            )
            interruptionPausedPlayback = false
            applyInterruptionEndAction(action)
        @unknown default:
            break
        }
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
            if !isMuted, usesManagedAudioSession, !ownsAudioSessionClaim {
                ownsAudioSessionClaim = VideoAudioSessionCoordinator.shared.claim()
            }
            scheduleFirstFrameTimeoutIfNeeded()
            if isMuted { audioTrackIsolation.prepareMutedPlayback() }
            player.play()
            scheduleProgressWatchdogTick()
        } else {
            releaseAudioSessionClaim()
            pauseProgressWatchdog()
            playbackTimeoutWorkItem?.cancel()
            playbackTimeoutWorkItem = nil
            pauseFirstFrameTimeout()
            player.pause()
        }
    }

    private func releaseAudioSessionClaim() {
        guard ownsAudioSessionClaim else { return }
        ownsAudioSessionClaim = false
        VideoAudioSessionCoordinator.shared.release()
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
        var active: Bool
        var lastTouched: TimeInterval
        var expiry: DispatchWorkItem?
    }

    private var entries: [FullscreenVideoPreparationToken: Entry] = [:]
    private let capacity: Int
    private let retention: TimeInterval
    private let retentionPolicy: VideoPreparationRetentionPolicy

    convenience init() {
        self.init(capacity: Self.maxPreparedPlayers, retention: Self.preparedRetention)
    }

    convenience init(capacity: Int) {
        self.init(capacity: capacity, retention: Self.preparedRetention)
    }

    init(capacity: Int, retention: TimeInterval) {
        self.capacity = max(0, capacity)
        self.retention = max(0, retention)
        self.retentionPolicy = VideoPreparationRetentionPolicy(
            capacity: max(0, capacity),
            retention: max(0, retention)
        )
    }

    func prepare(
        url: URL,
        posterURL: URL?,
        startsMuted: Bool = true,
        stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout
    ) -> FullscreenVideoPreparationToken? {
        guard makeRoomForPlayer() else { return nil }
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
            active: false,
            lastTouched: ProcessInfo.processInfo.systemUptime,
            expiry: nil
        )
        scheduleExpiry(for: token)
        return token
    }

    func claim(
        _ token: FullscreenVideoPreparationToken,
        url: URL,
        posterURL: URL?,
        startsMuted: Bool = true,
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
            entry.lastTouched = ProcessInfo.processInfo.systemUptime
            entries[token] = entry
            return entry.player
        }
        release(token)
        guard makeRoomForPlayer() else { return nil }
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
            active: true,
            lastTouched: ProcessInfo.processInfo.systemUptime,
            expiry: nil
        )
        return player
    }

    func returnToPrepared(_ token: FullscreenVideoPreparationToken) {
        guard var entry = entries[token] else { return }
        entry.active = false
        entry.lastTouched = ProcessInfo.processInfo.systemUptime
        entries[token] = entry
        scheduleExpiry(for: token)
    }

    func release(_ token: FullscreenVideoPreparationToken?) {
        guard let token, let entry = entries.removeValue(forKey: token) else { return }
        entry.expiry?.cancel()
        entry.player.stop()
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
        let now = ProcessInfo.processInfo.systemUptime
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
              ProcessInfo.processInfo.systemUptime - entry.lastTouched >= retention else { return }
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
        startsMuted: Bool = true,
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
    startsMuted: Bool = true,
    stallTimeout: TimeInterval = FullscreenVideoPlayer.preparationTimeout
) -> FullscreenVideoPreparationReservation {
    reserveFullscreenVideoPreparation(for: creative) { url, posterURL in
        FullscreenVideoPreparationPool.shared.prepare(
            url: url,
            posterURL: posterURL,
            startsMuted: startsMuted,
            stallTimeout: stallTimeout
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
    var onMuteChanged: ((Bool) -> Void)? = nil
    var telemetryPauseReason: () -> String = { "playback" }
    var onTelemetryEvent: ((VideoSurfaceTelemetryEvent) -> Void)? = nil
    @State private var firstFrameHandoff = VideoSurfaceFirstFrameHandoffState()
    @State private var quartileState = VideoQuartileState()
    @State private var pauseTelemetryState = VideoPauseTelemetryState()

    private var showsFirstFrame: Bool {
        videoSurfaceShowsFirstFrame(
            localPlayerIdentity: firstFrameHandoff.readyLayerPlayerIdentity,
            currentPlayerIdentity: ObjectIdentifier(videoPlayer)
        )
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
                    if controlsEnabled, chromeConfiguration != nil {
                        muteButton
                            .padding(12)
                    }
                    Spacer()
                }
                Spacer()
                if controlsEnabled, let chromeConfiguration {
                    VideoCreativeChrome(configuration: chromeConfiguration, action: onTap)
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
        .onReceive(videoPlayer.$playedSeconds) { position in
            guard onTelemetryEvent != nil else { return }
            for quartile in quartileState.crossed(position: position, duration: videoPlayer.duration) {
                onTelemetryEvent?(.quartile(quartile))
            }
        }
        .onReceive(videoPlayer.$status) { status in
            guard onTelemetryEvent != nil, videoPlayer.hasAdmittedFirstVisualFrame else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch status {
            case .paused:
                if let duration = videoPlayer.duration,
                   videoPlayer.playedSeconds >= max(0, duration - 0.15) { return }
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
