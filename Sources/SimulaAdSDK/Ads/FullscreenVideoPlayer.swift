import Foundation

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
        duration.map { min(configuredDelay, $0) }
    }

    var isUnlocked: Bool {
        guard let gateDuration else { return ended }
        return ended || played >= gateDuration
    }

    var progress: Double {
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

    mutating func parentAccepted() {
        parentNotifiedForAppearance = true
    }
}

func shouldShowVideoStorePrompt(enabled: Bool, reachedMidpoint: Bool, dismissUnlocked: Bool) -> Bool {
    enabled && reachedMidpoint && !dismissUnlocked
}

func canUseVideoControls(firstFrameAdmitted: Bool, displayAdmitted: Bool) -> Bool {
    firstFrameAdmitted && displayAdmitted
}

enum FullscreenVideoTelemetryStage {
    static let start = "video_start"
    static let complete = "video_complete"
    static let fail = "video_fail"
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

#if os(iOS)
import AVFoundation
import Combine
import SwiftUI
import UIKit

enum VideoInterruptionEndAction: Equatable {
    case resume
    case stayPaused
    case reconcile
}

func videoInterruptionEndAction(
    pausedByInterruption: Bool,
    userInfo: [AnyHashable: Any]?
) -> VideoInterruptionEndAction {
    guard pausedByInterruption else { return .reconcile }
    return videoInterruptionShouldResume(userInfo) ? .resume : .stayPaused
}

@MainActor
final class FullscreenVideoPlayer: ObservableObject {
    static let preparationTimeout: TimeInterval = 10
    static let firstFrameTimeout: TimeInterval = 10
    static let pendingEndFrameGrace: TimeInterval = 0.5

    @Published private(set) var status: FullscreenVideoStatus = .preparing
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var playedSeconds: TimeInterval = 0
    @Published private(set) var isMuted = true
    @Published private(set) var requiresUserResume = false

    let player: AVPlayer
    let posterURL: URL?

    private let item: AVPlayerItem
    private var itemStatusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var periodicTimeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var preparationTimeoutWorkItem: DispatchWorkItem?
    private var playbackTimeoutWorkItem: DispatchWorkItem?
    private var firstFrameTimeoutWorkItem: DispatchWorkItem?
    private var pendingEndGraceWorkItem: DispatchWorkItem?
    private var visiblePlaybackClock = VideoVisiblePlaybackClock()
    private var firstFrameDeadline = VideoFirstFrameDeadlineState()
    private var wantsPlayback = false
    private var presentationBlocked = false
    private var appActive = UIApplication.shared.applicationState == .active
    private var audioInterrupted = false
    private var interruptionPausedPlayback = false
    private var stopped = false

    var isStopped: Bool { stopped }
    var hasAdmittedFirstVisualFrame: Bool { firstFrameDeadline.admitted }

    init(url: URL, posterURL: URL?) {
        self.posterURL = posterURL
        self.item = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        installObservers()
        if appActive { schedulePreparationTimeout() }
    }

    deinit {
        preparationTimeoutWorkItem?.cancel()
        playbackTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem?.cancel()
        pendingEndGraceWorkItem?.cancel()
        itemStatusObservation?.invalidate()
        durationObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func play() {
        guard !stopped else { return }
        wantsPlayback = true
        reconcilePlayback()
    }

    func resumeAfterInterruption() {
        guard !stopped, requiresUserResume else { return }
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
        isMuted.toggle()
        // Do not alter or activate the host's AVAudioSession. AVPlayer participates in the
        // publisher's existing policy, which is safer than replacing its category/options.
        player.isMuted = isMuted
    }

    func admitFirstVisualFrame() -> Bool {
        guard firstFrameDeadline.admit() else { return false }
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        pendingEndGraceWorkItem?.cancel()
        pendingEndGraceWorkItem = nil
        visiblePlaybackClock.admitFirstFrame(mediaTime: player.currentTime().seconds)
        playedSeconds = 0
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
    }

    private func installObservers() {
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

        let center = NotificationCenter.default
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
        notificationObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.setAppActive(false) } })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.setAppActive(true) } })
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
        guard preparationTimeoutWorkItem == nil, status == .preparing, appActive else { return }
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
        guard item.status == .readyToPlay, duration != nil, status == .preparing else { return }
        preparationTimeoutWorkItem?.cancel()
        preparationTimeoutWorkItem = nil
        status = .ready
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
        }
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
        let finalPosition = player.currentTime().seconds
        playedSeconds = visiblePlaybackClock.update(mediaTime: finalPosition)
        wantsPlayback = false
        playbackTimeoutWorkItem?.cancel()
        playbackTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        pendingEndGraceWorkItem?.cancel()
        pendingEndGraceWorkItem = nil
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
        wantsPlayback = false
        player.pause()
        status = .failed(reason)
    }

    private func setAppActive(_ active: Bool) {
        appActive = active
        if active {
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
        switch type {
        case .began:
            interruptionPausedPlayback = wantsPlayback && appActive && !presentationBlocked
            audioInterrupted = true
            reconcilePlayback()
        case .ended:
            audioInterrupted = false
            let action = videoInterruptionEndAction(
                pausedByInterruption: interruptionPausedPlayback,
                userInfo: notification.userInfo
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

    private func reconcilePlayback() {
        guard !stopped, !isFailed, status != .ended else { return }
        if firstFrameDeadline.pendingEnd {
            if appActive && !presentationBlocked && !audioInterrupted {
                schedulePendingEndGraceIfNeeded()
            } else {
                pendingEndGraceWorkItem?.cancel()
                pendingEndGraceWorkItem = nil
            }
            player.pause()
            return
        }
        let canPlay = wantsPlayback && !requiresUserResume && appActive
            && !presentationBlocked && !audioInterrupted
            && item.status == .readyToPlay && duration != nil
        if canPlay {
            scheduleFirstFrameTimeoutIfNeeded()
            player.play()
        } else {
            playbackTimeoutWorkItem?.cancel()
            playbackTimeoutWorkItem = nil
            pauseFirstFrameTimeout()
            player.pause()
        }
    }

    private func schedulePlaybackTimeoutIfNeeded() {
        guard playbackTimeoutWorkItem == nil, wantsPlayback, appActive,
              !presentationBlocked, !audioInterrupted else { return }
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
        guard firstFrameDeadline.arm() else { return }
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

    func prepare(url: URL, posterURL: URL?) -> FullscreenVideoPreparationToken? {
        guard makeRoomForPlayer() else { return nil }
        let token = FullscreenVideoPreparationToken()
        let player = FullscreenVideoPlayer(url: url, posterURL: posterURL)
        entries[token] = Entry(
            url: url,
            posterURL: posterURL,
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
        posterURL: URL?
    ) -> FullscreenVideoPlayer? {
        if entries[token]?.active == true { return nil }
        if var entry = entries[token], entry.url == url, entry.posterURL == posterURL,
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
        let player = FullscreenVideoPlayer(url: url, posterURL: posterURL)
        entries[token] = Entry(
            url: url,
            posterURL: posterURL,
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

    func claim(url: URL, posterURL: URL?) -> FullscreenVideoPlayer? {
        guard state == .ad else { return nil }
        guard let player = FullscreenVideoPreparationPool.shared.claim(
            token,
            url: url,
            posterURL: posterURL
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
    case unavailable
}

@MainActor
func reserveFullscreenVideoPreparation(
    for creative: FullscreenCreativeContent
) -> FullscreenVideoPreparationReservation {
    reserveFullscreenVideoPreparation(for: creative) { url, posterURL in
        FullscreenVideoPreparationPool.shared.prepare(url: url, posterURL: posterURL)
    }
}

@MainActor
func reserveFullscreenVideoPreparation(
    for creative: FullscreenCreativeContent,
    prepare: (URL, URL?) -> FullscreenVideoPreparationToken?
) -> FullscreenVideoPreparationReservation {
    guard case .video(let url, let posterURL) = creative else { return .notRequired }
    guard let token = prepare(url, posterURL) else { return .unavailable }
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

struct FullscreenVideoSurface: View {
    @ObservedObject var videoPlayer: FullscreenVideoPlayer
    let presentationActive: Bool
    let onTap: () -> Void
    let onFirstFrame: () -> Bool
    let controlsEnabled: Bool
    @State private var firstFrameHandoff = VideoSurfaceFirstFrameHandoffState()

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
                Spacer()
                HStack {
                    Spacer()
                    if controlsEnabled {
                        Button(action: { videoPlayer.toggleMuted() }) {
                        Image(systemName: videoPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(videoPlayer.isMuted ? "Unmute ad" : "Mute ad")
                        .padding(12)
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
    }

    private func attemptParentHandoff() {
        let playerIdentity = ObjectIdentifier(videoPlayer)
        guard firstFrameHandoff.shouldAttemptParentHandoff(
            currentPlayerIdentity: playerIdentity
        ) else { return }
        guard videoPlayer.hasAdmittedFirstVisualFrame || videoPlayer.admitFirstVisualFrame() else { return }
        guard onFirstFrame() else { return }
        firstFrameHandoff.parentAccepted()
    }
}
#else
@MainActor
final class FullscreenVideoPlayer {}
#endif
