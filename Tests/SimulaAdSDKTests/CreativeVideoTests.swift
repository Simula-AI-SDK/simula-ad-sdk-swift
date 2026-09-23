import XCTest
@testable import SimulaAdSDK

final class CreativeVideoTests: XCTestCase {
    private func decodeInterstitial(_ json: String) throws -> AdLoadResponse {
        try decodeFullscreenPayload(AdLoadResponse.self, from: Data(json.utf8))
    }

    private func decodeRewarded(_ json: String) throws -> RewardedInitResponse {
        try decodeFullscreenPayload(RewardedInitResponse.self, from: Data(json.utf8))
    }

    private func decodeFallbacks(_ json: String) throws -> [FallbackAd] {
        try decodeFullscreenPayload(FallbackAdsAPIResponse.self, from: Data(json.utf8)).resolvedAds
    }

    func testUnknownCreativeTypeDefaultsToPlayableHTML() throws {
        let response = try decodeInterstitial(#"{"ad_inserted":true,"rendered_html":"<html/>","creative":{"type":"future"}}"#)
        XCTAssertEqual(response.creative?.mediaType, .playable)
        XCTAssertEqual(response.creativeContent, .playable(html: "<html/>"))
    }

    func testPrimaryVideoDecodesURLAndPosterWithoutHTML() throws {
        let response = try decodeInterstitial(#"{"ad_inserted":true,"creative":{"type":"video","url":"https://cdn.example/ad.mp4","poster_url":"https://cdn.example/poster.jpg"}}"#)
        guard case .video(let url, let posterURL)? = response.creativeContent else {
            return XCTFail("Expected video creative")
        }
        XCTAssertEqual(url.absoluteString, "https://cdn.example/ad.mp4")
        XCTAssertEqual(posterURL?.absoluteString, "https://cdn.example/poster.jpg")
    }

    func testInvalidVideoURLIsNotRenderable() throws {
        let response = try decodeInterstitial(#"{"ad_inserted":true,"rendered_html":"ignored","creative":{"type":"video","url":"file:///tmp/ad.mp4"}}"#)
        XCTAssertNil(response.creativeContent)
    }

    func testRewardedUsesHTMLWithoutIframeAndRejectsIframeOnly() throws {
        XCTAssertEqual(
            try decodeRewarded(#"{"rendered_html":"<html/>"}"#).creativeContent,
            .playable(html: "<html/>")
        )
        XCTAssertNil(try decodeRewarded(#"{"iframe_url":"https://example.com/legacy"}"#).creativeContent)
    }

    func testRewardedVideoCreativeDecodes() throws {
        let response = try decodeRewarded(#"{"creative":{"type":"video","url":"https://cdn.example/reward.mp4","poster_url":"https://cdn.example/reward.jpg"}}"#)
        guard case .video(let url, let posterURL)? = response.creativeContent else {
            return XCTFail("Expected rewarded video")
        }
        XCTAssertEqual(url.lastPathComponent, "reward.mp4")
        XCTAssertEqual(posterURL?.lastPathComponent, "reward.jpg")
    }

    func testFullscreenRequestUsesTopLevelVideoContractOnly() throws {
        let capabilities = DeviceCapabilities(
            osVersion: "18.0.0",
            storekitAvailable: true,
            skanVersion: "4.0",
            adAttributionKitAvailable: true,
            nativeClickBeaconV1: true,
            videoV1: true
        )
        let rewarded = RewardedInitRequest(adUnitId: "u", capabilities: capabilities)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rewarded)) as? [String: Any]
        )
        XCTAssertNil((object["capabilities"] as? [String: Any])?["video_v1"])
        XCTAssertNil(capabilities.dictionary["video_v1"])
        XCTAssertEqual((object["contracts"] as? [String: Any])?["video"] as? Int, 2)
    }

    func testLegacyCapabilityInitializersDoNotSerializeVideoMarkers() throws {
        let capabilities = DeviceCapabilities(
            osVersion: "18.0.0",
            storekitAvailable: true,
            skanVersion: "4.0",
            adAttributionKitAvailable: true,
            nativeClickBeaconV1: true,
            videoV1: true,
            videoPlanV2: true
        )
        let data = try JSONEncoder().encode(capabilities)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["video_v1"])
        XCTAssertNil(object["video_plan_v2"])
        XCTAssertNil(capabilities.dictionary["video_plan_v2"])
    }

    func testVideoPlanV2CreativeAndStyleDecode() throws {
        let response = try decodeInterstitial(#"""
        {
          "ad_inserted":true,"video_contract":2,
          "creative":{
            "type":"video","url":"https://cdn.example/ad.mp4","cta":"Play Now",
            "app_icon_url":"https://cdn.example/icon.png","app_name":"Example Game",
            "subtitle":"Build your city","segments":[
              {"clip_index":0,"video_pool":"ugc","start_seconds":0,"end_seconds":5}
            ]
          },
          "ad_behavior":{"video":{"style":"bottom_card"}}
        }
        """#)
        let creative = try XCTUnwrap(response.creative)

        XCTAssertFalse(creative.isVideoPlanV2Clip)
        XCTAssertTrue(response.primaryUsesVideoPlanV2)
        XCTAssertEqual(creative.cta, "Play Now")
        XCTAssertEqual(creative.appIconUrl, "https://cdn.example/icon.png")
        XCTAssertEqual(creative.appName, "Example Game")
        XCTAssertEqual(creative.subtitle, "Build your city")
        XCTAssertNil(creative.videoPool)
        XCTAssertNil(creative.clipIndex)
        XCTAssertEqual(creative.segments.map(\.videoPool), ["ugc"])
        XCTAssertEqual(response.adBehavior?.video.style, .bottomCard)
        XCTAssertEqual(
            videoChromeConfiguration(
                creative: creative,
                behavior: response.adBehavior,
                isVideoPlanV2: true
            ),
            VideoChromeConfiguration(
                style: .bottomCard,
                cta: "Play Now",
                appIconURL: URL(string: "https://cdn.example/icon.png"),
                title: "Example Game",
                subtitle: "Build your city"
            )
        )
    }

    func testAllVideoChromeStylesAndUnknownFallback() throws {
        XCTAssertEqual(
            VideoChromeStyle.allCases.map(\.rawValue),
            ["bottom_bar", "floating_pill", "bottom_card", "corner_cta", "feed_card"]
        )
        for style in VideoChromeStyle.allCases {
            let payload = #"""
            {
              "ad_inserted":true,"video_contract":2,
              "creative":{
                "type":"video","url":"https://cdn.example/ad.mp4","cta":"Install Now",
                "app_icon_url":"https://cdn.example/icon.png","app_name":"Example Game",
                "segments":[
                  {"clip_index":0,"video_pool":"ugc","start_seconds":0,"end_seconds":5}
                ]
              },
              "ad_behavior":{"video":{"style":"\#(style.rawValue)"}}
            }
            """#
            let interstitial = try decodeInterstitial(payload)
            let rewarded = try decodeRewarded(payload)

            for (creative, behavior, isVideoPlanV2, format) in [
                (interstitial.creative, interstitial.adBehavior, interstitial.primaryUsesVideoPlanV2, "interstitial"),
                (rewarded.creative, rewarded.adBehavior, rewarded.primaryUsesVideoPlanV2, "rewarded"),
            ] {
                XCTAssertNil(creative?.videoPool, format)
                XCTAssertNil(creative?.clipIndex, format)
                XCTAssertEqual(creative?.segments.count, 1, format)
                XCTAssertEqual(
                    videoChromeConfiguration(
                        creative: creative,
                        behavior: behavior,
                        isVideoPlanV2: isVideoPlanV2
                    )?.style,
                    style,
                    "\(format): \(style.rawValue)"
                )
            }
        }
        XCTAssertEqual(
            try JSONDecoder().decode(VideoBehavior.self, from: Data(#"{"style":"future"}"#.utf8)).style,
            .cornerCTA
        )
        XCTAssertEqual(try JSONDecoder().decode(VideoBehavior.self, from: Data("{}".utf8)).style, .cornerCTA)
    }

    func testTitleOnlyChromeDoesNotManufactureSubtitle() throws {
        let response = try decodeInterstitial(#"""
        {
          "ad_inserted":true,"video_contract":2,
          "creative":{
            "type":"video","url":"https://cdn.example/ad.mp4","app_name":"Title",
            "segments":[
              {"clip_index":0,"video_pool":"ugc","start_seconds":0,"end_seconds":5}
            ]
          }
        }
        """#)
        let config = videoChromeConfiguration(
            creative: response.creative,
            behavior: response.adBehavior,
            isVideoPlanV2: response.primaryUsesVideoPlanV2
        )

        XCTAssertEqual(config?.title, "Title")
        XCTAssertNil(config?.subtitle)
        XCTAssertEqual(config?.style, .cornerCTA)
        XCTAssertEqual(config?.cta, "Install")
    }

    func testVideoV1PayloadDoesNotEnterV2Runtime() throws {
        let response = try decodeInterstitial(#"""
        {
          "ad_inserted":true,
          "creative":{"type":"video","url":"https://cdn.example/ad.mp4","video_pool":"ugc"},
          "ad_behavior":{"video":{"style":"feed_card"}}
        }
        """#)

        XCTAssertFalse(response.creative?.isVideoPlanV2Clip == true)
        XCTAssertFalse(response.primaryUsesVideoPlanV2)
        XCTAssertNil(videoChromeConfiguration(
            creative: response.creative,
            behavior: response.adBehavior,
            isVideoPlanV2: false
        ))
        XCTAssertFalse(shouldAutomaticallyAdvanceCompletedVideo(usesVideoPlanV2: false, status: .ended))
    }

    func testClipMetadataNeverActivatesV2WithoutCanonicalResponseMarker() throws {
        let interstitial = try decodeInterstitial(#"{"ad_inserted":true,"creative":{"type":"video","url":"https://cdn.example/a.mp4","clip_index":0,"video_plan_version":"video_plan_v2"}}"#)
        let rewarded = try decodeRewarded(#"{"creative":{"type":"video","url":"https://cdn.example/b.mp4","clip_index":1}}"#)
        let fallbacks = try decodeFallbacks(#"{"ads":[{"video_plan_version":"video_plan_v2","type":"video","url":"https://cdn.example/c.mp4","clip_index":2}]}"#)

        XCTAssertTrue(interstitial.creative?.isVideoPlanV2Clip == true)
        XCTAssertFalse(interstitial.primaryUsesVideoPlanV2)
        XCTAssertTrue(rewarded.creative?.isVideoPlanV2Clip == true)
        XCTAssertFalse(rewarded.primaryUsesVideoPlanV2)
        XCTAssertEqual(fallbacks.map(\.usesVideoPlanV2Contract), [false])
        XCTAssertEqual(fallbacks.map(\.usesVideoPlanV2), [false])
        XCTAssertEqual(upcomingFallbackVideoIndices(fallbacks), [0], "Markerless clips retain V1 preparation")
    }

    func testNumericContractActivatesWithoutLegacyClipMetadata() throws {
        let missing = try decodeInterstitial(#"{"ad_inserted":true,"video_contract":2,"creative":{"type":"video","url":"https://cdn.example/a.mp4"}}"#)
        let malformed = try decodeRewarded(#"{"video_contract":2,"creative":{"type":"video","url":"https://cdn.example/b.mp4","clip_index":"1"}}"#)
        let playable = try decodeFallbacks(#"{"video_contract":2,"ads":[{"type":"playable","rendered_html":"HTML","clip_index":0}]}"#)

        XCTAssertTrue(missing.usesVideoPlanV2Contract)
        XCTAssertTrue(missing.primaryUsesVideoPlanV2)
        XCTAssertTrue(malformed.usesVideoPlanV2Contract)
        XCTAssertTrue(malformed.primaryUsesVideoPlanV2)
        XCTAssertEqual(playable.map(\.usesVideoPlanV2Contract), [true])
        XCTAssertEqual(playable.map(\.usesVideoPlanV2), [false])
        XCTAssertEqual(upcomingFallbackVideoIndices(playable), [])
        XCTAssertNil(videoChromeConfiguration(
            creative: playable.first?.creative,
            behavior: playable.first?.adBehavior,
            isVideoPlanV2: playable.first?.usesVideoPlanV2Contract == true
        ))
    }

    func testContractTwoAcceptsES1VideoWithoutLegacyClipMetadata() throws {
        let ads = try decodeFallbacks(#"""
        {"video_contract":2,"ads":[{
          "ad_id":"es1",
          "creative":{"type":"video","url":"https://cdn.example/es1.mp4","cta":"Get","app_icon_url":"https://cdn.example/icon.png","app_name":"Game","segments":[{"clip_index":0,"video_pool":"trailer","start_seconds":0,"end_seconds":10}]},
          "ad_behavior":{"video":{"style":"floating_pill"}}
        }]}
        """#)
        XCTAssertEqual(ads.count, 1)
        XCTAssertEqual(ads.first?.sourceIndex, 0)
        XCTAssertEqual(ads.first?.usesVideoPlanV2, true)
        XCTAssertEqual(ads.first?.creative?.segments.count, 1)
        XCTAssertEqual(upcomingFallbackVideoIndices(ads), [0])
        XCTAssertFalse(shouldAutomaticallyAdvanceCompletedVideo(usesVideoPlanV2: true, status: .ended))
    }

    func testAllPlayableGoldenFlowRemainsPrimaryThenES1ThenES2() throws {
        let primary = try decodeInterstitial(#"""
        {
          "ad_inserted":true,"rendered_html":"PRIMARY","video_contract":2,
          "creative":{"type":"playable","clip_index":0}
        }
        """#)
        let fallbacks = try decodeFallbacks(#"""
        {"video_contract":2,"ads":[
          {"rendered_html":"ES1","creative":{"type":"playable","clip_index":1}},
          {"rendered_html":"ES2","creative":{"type":"playable","clip_index":2}}
        ]}
        """#)

        XCTAssertEqual(primary.creativeContent, .playable(html: "PRIMARY"))
        XCTAssertTrue(primary.usesVideoPlanV2Contract)
        XCTAssertFalse(primary.creative?.isVideoPlanV2Clip == true)
        XCTAssertFalse(primary.primaryUsesVideoPlanV2)
        XCTAssertEqual(fallbacks.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(fallbacks.map(\.renderedHtml), ["ES1", "ES2"])
        XCTAssertEqual(fallbacks.map { $0.creative?.clipIndex }, [1, 2])
        XCTAssertEqual(fallbacks.map(\.mediaType), [.playable, .playable])
    }

    func testAllPlayableContractRetainsHTMLAndDropsFallbackVideo() throws {
        let primary = try decodeInterstitial(#"{"ad_inserted":true,"rendered_html":"PRIMARY","video_contract":2,"creative":{"type":"playable"}}"#)
        let rewarded = try decodeRewarded(#"{"rendered_html":"PRIMARY","video_contract":2,"creative":{"type":"playable"}}"#)
        let fallbacks = try decodeFallbacks(#"{"video_contract":2,"ads":[{"type":"playable","rendered_html":"ES1"},{"type":"video","url":"https://cdn.example/es2.mp4","clip_index":2}]}"#)

        XCTAssertTrue(primary.usesVideoPlanV2Contract)
        XCTAssertFalse(primary.primaryUsesVideoPlanV2)
        XCTAssertTrue(rewarded.usesVideoPlanV2Contract)
        XCTAssertFalse(rewarded.primaryUsesVideoPlanV2)
        XCTAssertEqual(fallbacks.map(\.usesVideoPlanV2Contract), [true])
        XCTAssertEqual(fallbacks.map(\.mediaType), [.playable])
        XCTAssertEqual(upcomingFallbackVideoIndices(fallbacks), [])
    }

    func testVideoPlanSKOverlayDefaultsClampAndStayV2Only() {
        XCTAssertNil(effectiveVideoPlanSKOverlayConfig(isVideoPlanV2: false, config: nil))
        let defaults = effectiveVideoPlanSKOverlayConfig(isVideoPlanV2: true, config: nil)
        XCTAssertEqual(defaults?.enabled, true)
        XCTAssertEqual(defaults?.timing, .delayed)
        XCTAssertEqual(defaults?.delaySeconds, 3)

        let clamped = effectiveVideoPlanSKOverlayConfig(
            isVideoPlanV2: true,
            config: SKOverlayConfig(enabled: true, delaySeconds: 300)
        )
        XCTAssertEqual(clamped?.delaySeconds, 60)
        XCTAssertNil(effectiveVideoPlanSKOverlayConfig(
            isVideoPlanV2: true,
            config: SKOverlayConfig(enabled: false)
        ))
    }

    func testCanonicalVideoTerminationReasonVocabulary() {
        XCTAssertEqual(
            FullscreenVideoTerminationReason.canonicalVocabulary,
            Set([
                "completed", "failed", "user", "no_next_step", "next_step_failed",
                "next_step_timeout", "backgrounded", "store_presented",
                "audio_interruption", "playback",
            ])
        )
    }

    func testFinalCompletedVideoClosesWithoutStartingHandoff() {
        XCTAssertEqual(
            videoPlanTerminalAction(
                reason: FullscreenVideoTerminationReason.completed,
                expectsNextStep: false,
                playbackStarted: true
            ),
            .close(reason: "completed")
        )
        XCTAssertEqual(
            videoPlanTerminalAction(
                reason: FullscreenVideoTerminationReason.completed,
                expectsNextStep: true,
                playbackStarted: true
            ),
            .handoff(reason: "completed")
        )
    }

    func testExpectedStepFailureIsDistinctFromStartedFinalClipFailure() {
        XCTAssertEqual(
            videoPlanTerminalAction(
                reason: FullscreenVideoTerminationReason.failed,
                expectsNextStep: true,
                playbackStarted: false
            ),
            .preservePendingHandoff
        )
        XCTAssertEqual(
            videoPlanTerminalAction(
                reason: FullscreenVideoTerminationReason.failed,
                expectsNextStep: false,
                playbackStarted: false
            ),
            .failExpectedNextStep
        )
        XCTAssertEqual(
            videoPlanTerminalAction(
                reason: FullscreenVideoTerminationReason.failed,
                expectsNextStep: false,
                playbackStarted: true
            ),
            .close(reason: "failed")
        )
    }

    func testVideoMuteControlAvoidsTopLeftCloseAndBottomChrome() {
        XCTAssertEqual(
            videoMuteControlPlacement(
                hasVideoChrome: true,
                effectiveClosePosition: .topLeft
            ),
            .topTrailing
        )
        XCTAssertEqual(
            videoMuteControlPlacement(
                hasVideoChrome: true,
                effectiveClosePosition: .topRight
            ),
            .topLeading
        )
        XCTAssertEqual(
            videoMuteControlPlacement(
                hasVideoChrome: true,
                effectiveClosePosition: .bottomLeft
            ),
            .topLeading
        )
        XCTAssertEqual(
            videoMuteControlPlacement(
                hasVideoChrome: false,
                effectiveClosePosition: .topLeft
            ),
            .bottomTrailing
        )
        XCTAssertEqual(
            videoMuteTopPadding(
                hasVideoChrome: true,
                storePromptVisible: true,
                storePromptSharesMuteCorner: true
            ),
            64
        )
        XCTAssertEqual(
            videoMuteTopPadding(
                hasVideoChrome: true,
                storePromptVisible: true,
                storePromptSharesMuteCorner: false
            ),
            12
        )
    }

    func testFallbackVideoTelemetryUsesBaseAdFormat() {
        XCTAssertEqual(fallbackVideoTelemetryAdFormat("interstitial"), "interstitial")
        XCTAssertEqual(fallbackVideoTelemetryAdFormat("rewarded"), "rewarded")
    }

    func testOnlyTerminalOverlayEventsCarryPresentationWatchTotals() {
        XCTAssertFalse(videoPlanOverlayUsesPresentationWatchTotals(
            stage: FullscreenVideoTelemetryStage.skoverlayShown
        ))
        XCTAssertTrue(videoPlanOverlayUsesPresentationWatchTotals(
            stage: FullscreenVideoTelemetryStage.skoverlayDismissed
        ))
        XCTAssertTrue(videoPlanOverlayUsesPresentationWatchTotals(
            stage: FullscreenVideoTelemetryStage.skoverlayFailed
        ))
    }

    func testVideoPlanSKOverlayClockCountsOnlyEligiblePresentationTime() {
        var clock = VideoPlanSKOverlayClock(delay: 3)
        XCTAssertEqual(clock.start(now: 10, blocked: false), .schedule(3))
        XCTAssertEqual(clock.setBlocked(true, now: 11), .none)
        XCTAssertEqual(clock.deadlineFired(now: 20), .none)
        XCTAssertEqual(clock.setBlocked(false, now: 20), .schedule(2))
        XCTAssertEqual(clock.deadlineFired(now: 22), .ready)
        XCTAssertTrue(clock.ready)
        XCTAssertEqual(clock.deadlineFired(now: 23), .none)
        XCTAssertEqual(clock.setBlocked(true, now: 30), .none)

        var cancelled = VideoPlanSKOverlayClock(delay: 3)
        XCTAssertEqual(cancelled.start(now: 0, blocked: false), .schedule(3))
        cancelled.cancel(now: 1)
        XCTAssertEqual(cancelled.deadlineFired(now: 10), .none)
        XCTAssertFalse(cancelled.ready)
    }

    func testVideoPlanStallDeadlineIsEightEligibleSecondsOnly() {
        XCTAssertEqual(videoPlanV2EligibleStallTimeout, 8)
        XCTAssertTrue(shouldArmVideoStallDeadline(
            wantsPlayback: true,
            appActive: true,
            presentationBlocked: false,
            audioInterrupted: false
        ))
        XCTAssertFalse(shouldArmVideoStallDeadline(
            wantsPlayback: true,
            appActive: false,
            presentationBlocked: false,
            audioInterrupted: false
        ))
        XCTAssertFalse(shouldArmVideoStallDeadline(
            wantsPlayback: true,
            appActive: true,
            presentationBlocked: true,
            audioInterrupted: false
        ))
        XCTAssertFalse(shouldArmVideoStallDeadline(
            wantsPlayback: true,
            appActive: true,
            presentationBlocked: false,
            audioInterrupted: true
        ))
    }

    func testPostFrameWatchdogPausesAndResetsForMediaOrDownloadProgress() {
        var watchdog = VideoProgressWatchdog(budget: 8)
        XCTAssertFalse(watchdog.observe(now: 0, eligible: true, mediaTime: 1, bufferedEnd: 2))
        XCTAssertFalse(watchdog.observe(now: 4, eligible: true, mediaTime: 1, bufferedEnd: 2))
        XCTAssertEqual(watchdog.remaining, 4, accuracy: 0.001)

        XCTAssertFalse(watchdog.observe(now: 10, eligible: false, mediaTime: 1, bufferedEnd: 2))
        XCTAssertEqual(watchdog.remaining, 4, accuracy: 0.001)
        XCTAssertFalse(watchdog.observe(now: 20, eligible: true, mediaTime: 1, bufferedEnd: 2))
        XCTAssertFalse(watchdog.observe(now: 22, eligible: true, mediaTime: 1, bufferedEnd: 3))
        XCTAssertEqual(watchdog.remaining, 8, accuracy: 0.001)
        XCTAssertFalse(watchdog.observe(now: 26, eligible: true, mediaTime: 2, bufferedEnd: 3))
        XCTAssertEqual(watchdog.remaining, 8, accuracy: 0.001)
        XCTAssertFalse(watchdog.observe(now: 30, eligible: true, mediaTime: 2, bufferedEnd: 3))
        XCTAssertTrue(watchdog.observe(now: 34, eligible: true, mediaTime: 2, bufferedEnd: 3))
    }

    func testAudioTrackIsolationStartsUnmutedForV2() {
        var policy = VideoAudioTrackPolicy<String>(isMuted: false)
        let tracks = [VideoAudioTrackSnapshot(id: "audio", isAudio: true, isEnabled: true)]

        XCTAssertFalse(policy.isMuted)
        XCTAssertTrue(policy.prepareMutedPlayback(tracks: tracks).isEmpty)
        XCTAssertEqual(policy.remute(tracks: tracks), [
            VideoAudioTrackCommand(id: "audio", isEnabled: false),
        ])
    }

    func testBlockerOwnerGenerationRejectsStaleDisappear() {
        let primary = VideoPlanBlockerOwner()
        let fallback = VideoPlanBlockerOwner()
        var state = VideoPlanBlockerState()

        XCTAssertFalse(state.activate(owner: primary, generation: 1, blocked: false))
        XCTAssertFalse(state.activate(owner: fallback, generation: 1, blocked: false))
        XCTAssertNil(state.deactivate(owner: primary, generation: 1))
        XCTAssertNil(state.update(owner: primary, generation: 1, blocked: true))
        XCTAssertEqual(state.update(owner: fallback, generation: 1, blocked: true), true)
        XCTAssertEqual(state.deactivate(owner: fallback, generation: 1), true)
    }

    func testVideoPlanUserCloseWinsQueuedCompletionAndFailure() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))

        XCTAssertTrue(arbiter.claimTerminal(playerID: "clip-a", event: .userClose))
        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-a", event: .completion))
        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-a", event: .failure))
        XCTAssertFalse(arbiter.start(playerID: "clip-a"), "late first frame loses after close")
    }

    func testPreFirstFrameEscapeArbitratesCanonicalCloseExactlyOnce() throws {
        let decision = try XCTUnwrap(videoPreFirstFrameEscapeDecision(
            surface: .interstitial,
            presentationMounted: true,
            firstFrameAdmitted: false,
            terminal: false
        ))
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        var emitted: [(stage: String, reason: String)] = []

        for _ in 0..<2 where arbiter.claimTerminal(
            playerID: "clip-a",
            event: decision.terminalEvent
        ) {
            emitted.append((decision.telemetryStage, decision.telemetryReason))
        }

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.stage, FullscreenVideoTelemetryStage.close)
        XCTAssertEqual(emitted.first?.reason, FullscreenVideoTerminationReason.user)
        XCTAssertFalse(arbiter.claimTerminal(playerID: "stale-player", event: decision.terminalEvent))
        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-a", event: .failure))
    }

    func testVideoPlanNaturalTerminalWinsLaterUserClose() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))

        XCTAssertTrue(arbiter.claimTerminal(playerID: "clip-a", event: .completion))
        XCTAssertTrue(arbiter.start(playerID: "clip-a"), "retained end still admits its first frame")
        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-a", event: .userClose))
    }

    func testVideoPlanWinningFailureStillOwnsAutoAdvance() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        var advances = 0

        if arbiter.claimTerminal(playerID: "clip-a", event: .failure) { advances += 1 }
        if arbiter.claimTerminal(playerID: "clip-a", event: .userClose) { advances += 1 }

        XCTAssertEqual(advances, 1)
        XCTAssertFalse(arbiter.start(playerID: "clip-a"))
    }

    func testVideoPlanReplacementRejectsStalePriorPlayer() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        XCTAssertTrue(arbiter.start(playerID: "clip-a"))
        XCTAssertTrue(arbiter.register(playerID: "clip-b"))

        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-a", event: .failure))
        XCTAssertFalse(arbiter.start(playerID: "clip-a"))
    }

    func testVideoPlanNextClipHasIndependentTerminalClaim() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        XCTAssertTrue(arbiter.claimTerminal(playerID: "clip-a", event: .completion))

        XCTAssertTrue(arbiter.register(playerID: "clip-b"))
        XCTAssertTrue(arbiter.claimTerminal(playerID: "clip-b", event: .failure))
        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-b", event: .userClose))
    }

    func testVideoPlanReplacementPreservesPendingPredecessorHandoff() throws {
        var arbiter = VideoPlanTerminalArbiter<String>()
        var handoff = VideoPlanHandoffState<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        XCTAssertTrue(arbiter.start(playerID: "clip-a"))
        XCTAssertTrue(arbiter.claimTerminal(playerID: "clip-a", event: .completion))
        handoff.videoTerminated(origin: "clip-a", secondsSinceVideoStart: 3, now: 10)

        XCTAssertTrue(arbiter.register(playerID: "clip-b"))
        XCTAssertEqual(handoff.pendingOrigin, "clip-a")
        XCTAssertTrue(arbiter.start(playerID: "clip-b"))
        let completion = try XCTUnwrap(handoff.videoStarted(now: 10.25))

        XCTAssertEqual(completion.origin, "clip-a")
        XCTAssertEqual(completion.timing.msToNextStepReady, 250, accuracy: 0.001)
    }

    func testVideoPlanSamePlayerReattachmentDoesNotResetGeneration() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        XCTAssertTrue(arbiter.start(playerID: "clip-a"))

        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        XCTAssertFalse(arbiter.start(playerID: "clip-a"))
        XCTAssertTrue(arbiter.claimTerminal(playerID: "clip-a", event: .completion))
    }

    func testVideoPlanCancellationRejectsLaterCallbacks() {
        var arbiter = VideoPlanTerminalArbiter<String>()
        XCTAssertTrue(arbiter.register(playerID: "clip-a"))
        arbiter.cancel()

        XCTAssertFalse(arbiter.start(playerID: "clip-a"))
        XCTAssertFalse(arbiter.claimTerminal(playerID: "clip-a", event: .failure))
        XCTAssertFalse(arbiter.register(playerID: "clip-b"))
    }

    func testVideoPlanFirstFrameBeforeSceneIsProcessedOnce() {
        var admission = VideoPlanPresentationAdmissionState<String>()
        var scenes = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(admission.register(playerID: "clip-a"))

        XCTAssertTrue(admission.admitFirstFrame(playerID: "clip-a"))
        XCTAssertEqual(admission.admittedFirstFrameCount, 1)
        XCTAssertNil(scenes.sceneID)
        XCTAssertTrue(scenes.update("scene-a"))
        XCTAssertEqual(scenes.sceneID, "scene-a")
        XCTAssertFalse(admission.admitFirstFrame(playerID: "clip-a"))
        XCTAssertEqual(admission.admittedFirstFrameCount, 1)
    }

    func testVideoPlanOldSceneClearCannotReplaceNewOwnerScene() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(state.activate(owner: "old", generation: 1))
        XCTAssertTrue(state.update("scene-old", owner: "old", generation: 1))
        XCTAssertTrue(state.activate(owner: "new", generation: 1))

        XCTAssertEqual(state.sceneID, "scene-old")

        XCTAssertFalse(state.update(nil, owner: "old", generation: 1))
        XCTAssertEqual(state.sceneID, "scene-old")
    }

    func testVideoPlanStaleOldNonNilSceneCannotReplaceNewOwnerScene() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(state.activate(owner: "old", generation: 1))
        XCTAssertTrue(state.update("scene-old", owner: "old", generation: 1))
        XCTAssertTrue(state.activate(owner: "new", generation: 2))

        XCTAssertFalse(state.update("scene-stale", owner: "old", generation: 1))
        XCTAssertEqual(state.sceneID, "scene-old")
        XCTAssertTrue(state.update("scene-new", owner: "new", generation: 2))
        XCTAssertEqual(state.sceneID, "scene-new")
    }

    func testVideoPlanStaleOwnerCannotDeactivateReplacementScene() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(state.activate(owner: "old", generation: 1))
        XCTAssertTrue(state.update("scene-old", owner: "old", generation: 1))
        XCTAssertTrue(state.activate(owner: "new", generation: 2))
        XCTAssertTrue(state.update("scene-new", owner: "new", generation: 2))

        XCTAssertFalse(state.deactivate(owner: "old", generation: 1))
        XCTAssertEqual(state.sceneID, "scene-new")
        XCTAssertEqual(state.owner, "new")
        XCTAssertTrue(state.deactivate(owner: "new", generation: 2))
        XCTAssertNil(state.sceneID)
        XCTAssertNil(state.owner)
    }

    func testVideoPlanPersistentHostSceneSeedsReplacementAfterOldOwnerDisappears() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        var claim = SKOverlayPresentationClaim()
        var presentations = 0
        let hostScene = "host-scene"

        func presentReadyOverlay() {
            guard state.sceneID == hostScene, let reservation = claim.reserve() else { return }
            presentations += 1
            XCTAssertTrue(claim.succeed(reservation))
        }

        XCTAssertTrue(state.activate(owner: "old", generation: 1, sceneID: hostScene))
        XCTAssertTrue(state.deactivate(owner: "old", generation: 1))
        XCTAssertNil(state.sceneID)
        presentReadyOverlay()
        XCTAssertEqual(presentations, 0)

        XCTAssertTrue(state.activate(owner: "replacement", generation: 2, sceneID: hostScene))
        presentReadyOverlay()
        XCTAssertEqual(presentations, 1)

        XCTAssertFalse(state.update(nil, owner: "old", generation: 1))
        XCTAssertFalse(state.update("stale-scene", owner: "old", generation: 1))
        XCTAssertFalse(state.deactivate(owner: "old", generation: 1))
        XCTAssertEqual(state.sceneID, hostScene)
        presentReadyOverlay()
        XCTAssertEqual(presentations, 1)
    }

    func testSceneReaderReplacementRejectsOldNilAndNonNilCallbacks() {
        var state = AdOverlayWindowSceneState<String, String>()
        state.activate(readerID: "old-reader")
        XCTAssertTrue(state.update("old-scene", readerID: "old-reader"))

        state.activate(readerID: "new-reader")
        XCTAssertTrue(state.update("new-scene", readerID: "new-reader"))
        XCTAssertFalse(state.update(nil, readerID: "old-reader"))
        XCTAssertFalse(state.update("stale-scene", readerID: "old-reader"))
        XCTAssertEqual(state.sceneID, "new-scene")

        XCTAssertTrue(state.update(nil, readerID: "new-reader"))
        XCTAssertNil(state.sceneID)
    }

    func testVideoPlanCurrentOwnerCanClearAndDeactivateScene() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(state.activate(owner: "current", generation: 3))
        XCTAssertTrue(state.update("scene-a", owner: "current", generation: 3))
        XCTAssertTrue(state.update(nil, owner: "current", generation: 3))
        XCTAssertNil(state.sceneID)

        XCTAssertTrue(state.update("scene-a", owner: "current", generation: 3))
        XCTAssertTrue(state.deactivate(owner: "current", generation: 3))
        XCTAssertNil(state.sceneID)
        XCTAssertNil(state.owner)
    }

    func testVideoPlanSameSceneCallbackIsAcceptedForPresentationRetry() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(state.activate(owner: "current", generation: 1))
        XCTAssertTrue(state.update("scene-a", owner: "current", generation: 1))

        XCTAssertTrue(state.update("scene-a", owner: "current", generation: 1))
        XCTAssertEqual(state.sceneID, "scene-a")
    }

    @MainActor
    func testVideoPlanSameSceneUpdateRetriesPresentation() {
        let center = NotificationCenter()
        let scene = NSObject()
        var retries = 0
        let retry = VideoPlanScenePresentationRetry<NSObject>(
            notificationCenter: center,
            activationNotification: Notification.Name("scene-did-activate")
        ) { retries += 1 }

        retry.updateScene(scene)
        retry.updateScene(scene)

        XCTAssertEqual(retries, 2)
    }

    @MainActor
    func testVideoPlanMatchingSceneActivationRetriesPresentation() {
        let center = NotificationCenter()
        let notification = Notification.Name("scene-did-activate")
        let scene = NSObject()
        var retries = 0
        let retry = VideoPlanScenePresentationRetry<NSObject>(
            notificationCenter: center,
            activationNotification: notification
        ) { retries += 1 }
        retry.updateScene(scene)

        center.post(name: notification, object: scene)

        XCTAssertEqual(retries, 2)
    }

    @MainActor
    func testVideoPlanNonmatchingAndCancelledSceneActivationAreIgnored() {
        let center = NotificationCenter()
        let notification = Notification.Name("scene-did-activate")
        let scene = NSObject()
        var retries = 0
        let retry = VideoPlanScenePresentationRetry<NSObject>(
            notificationCenter: center,
            activationNotification: notification
        ) { retries += 1 }
        retry.updateScene(scene)

        center.post(name: notification, object: NSObject())
        XCTAssertEqual(retries, 1)

        retry.cancel()
        center.post(name: notification, object: scene)
        retry.updateScene(scene)
        XCTAssertEqual(retries, 1)
    }

    func testVideoPlanReadyOverlayCannotDuplicateSuccessfulPresentation() throws {
        var claim = SKOverlayPresentationClaim()
        var presentations = 0
        let reservation = try XCTUnwrap(claim.reserve())
        presentations += 1
        XCTAssertTrue(claim.succeed(reservation))

        if claim.reserve() != nil { presentations += 1 }

        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(claim.consumed)
    }

    func testVideoPlanSceneCancellationRejectsDirectAndOwnedUpdates() {
        var state = VideoPlanOriginatingSceneState<String, String>()
        XCTAssertTrue(state.activate(owner: "current", generation: 1))
        state.cancel()

        XCTAssertFalse(state.update("scene-a", owner: "current", generation: 1))
        XCTAssertFalse(state.update("scene-a"))
        XCTAssertFalse(state.activate(owner: "replacement", generation: 2))
        XCTAssertNil(state.sceneID)
    }

    func testVideoPlanPendingPredecessorCompletesAtActualSceneIndependentFirstFrame() throws {
        var admission = VideoPlanPresentationAdmissionState<String>()
        var handoff = VideoPlanHandoffState<String>()
        handoff.videoTerminated(origin: "clip-a", secondsSinceVideoStart: 3, now: 10)
        XCTAssertTrue(admission.register(playerID: "clip-b"))

        XCTAssertTrue(admission.admitFirstFrame(playerID: "clip-b"))
        let completion = try XCTUnwrap(handoff.videoStarted(now: 10.25))
        XCTAssertEqual(completion.origin, "clip-a")
        XCTAssertEqual(completion.timing.msToNextStepReady, 250, accuracy: 0.001)
        XCTAssertFalse(admission.admitFirstFrame(playerID: "clip-b"))
        XCTAssertNil(handoff.videoStarted(now: 10.5))
    }

    func testVideoPlanFirstFrameCapturesHandoffBeforePreparationAdvancesClock() throws {
        var admission = VideoPlanPresentationAdmissionState<String>()
        var handoff = VideoPlanHandoffState<String>()
        var now: TimeInterval = 10.25
        handoff.videoTerminated(origin: "clip-a", secondsSinceVideoStart: 3, now: 10)
        XCTAssertTrue(admission.register(playerID: "clip-b"))

        let firstFrame = try XCTUnwrap(admitVideoPlanFirstFrame(
            playerID: "clip-b",
            admittedAt: now,
            admission: &admission,
            handoff: &handoff
        ))
        var events: [String] = []
        runVideoFirstFrameStartSequence(
            shouldRecordStart: true,
            recordStart: { events.append("video_start") },
            startOverlay: { events.append("skoverlay_shown") },
            notifyStarted: {
                events.append("on_video_started")
                now = 20
            }
        )

        let completion = try XCTUnwrap(firstFrame.completedHandoff)
        XCTAssertEqual(events, ["video_start", "skoverlay_shown", "on_video_started"])
        XCTAssertEqual(completion.origin, "clip-a")
        XCTAssertEqual(completion.timing.msToNextStepReady, 250, accuracy: 0.001)
        XCTAssertEqual(completion.timing.secondsSinceVideoStart, 3.25, accuracy: 0.001)
        XCTAssertEqual(now, 20)
        XCTAssertNil(admitVideoPlanFirstFrame(
            playerID: "clip-b",
            admittedAt: now,
            admission: &admission,
            handoff: &handoff
        ))
    }

    func testVideoFirstFrameStartSequenceOrdersZeroDelayOverlayAfterStartExactlyOnce() {
        var videoStartRecorded = false
        var overlayShown = false
        var events: [String] = []
        let processFirstFrame = {
            runVideoFirstFrameStartSequence(
                shouldRecordStart: !videoStartRecorded,
                recordStart: {
                    videoStartRecorded = true
                    events.append("video_start")
                },
                startOverlay: {
                    guard !overlayShown else { return }
                    overlayShown = true
                    events.append("skoverlay_shown")
                },
                notifyStarted: { events.append("on_video_started") }
            )
        }

        processFirstFrame()
        processFirstFrame()

        XCTAssertEqual(events, ["video_start", "skoverlay_shown", "on_video_started"])
    }

    func testVideoPlanTerminalCancellationRejectsLateSceneAndReplacementPlayer() {
        var state = VideoPlanPresentationAdmissionState<String>()
        XCTAssertTrue(state.register(playerID: "clip-a"))
        XCTAssertTrue(state.claimTerminal(playerID: "clip-a", event: .userClose))
        state.cancel()

        XCTAssertFalse(state.admitFirstFrame(playerID: "clip-a"))
        XCTAssertFalse(state.register(playerID: "clip-b"))
    }

    func testSKOverlayShownPhaseTracksVideoAndNextStepSeparately() {
        var duringVideo = VideoPlanOverlayPlacementState()
        duringVideo.videoBecameActive()
        duringVideo.becameReady()
        XCTAssertEqual(duringVideo.readyOn, .video)
        XCTAssertEqual(duringVideo.shown(), .video)
        XCTAssertEqual(duringVideo.shownOn, .video)

        var delayedAcrossHandoff = VideoPlanOverlayPlacementState()
        delayedAcrossHandoff.videoBecameActive()
        delayedAcrossHandoff.becameReady()
        delayedAcrossHandoff.handoffBegan()
        XCTAssertEqual(delayedAcrossHandoff.readyOn, .video)
        XCTAssertEqual(delayedAcrossHandoff.shown(), .nextStep)
        XCTAssertEqual(delayedAcrossHandoff.shownOn, .nextStep)

        var nextVideo = VideoPlanOverlayPlacementState()
        nextVideo.videoBecameActive()
        nextVideo.handoffBegan()
        nextVideo.videoBecameActive()
        nextVideo.becameReady()
        XCTAssertEqual(nextVideo.shown(), .video)
    }

    func testSKOverlayShownTelemetrySerializesCanonicalOnValues() throws {
        for phase in [VideoPlanOverlayPhase.video, .nextStep] {
            var event = TelemetryEvent(
                type: TelemetryType.lifecycle,
                name: FullscreenVideoTelemetryStage.skoverlayShown,
                eventId: phase.rawValue,
                timestamp: 1
            )
            event.on = phase.rawValue
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
            )
            XCTAssertEqual(object["name"] as? String, "skoverlay_shown")
            XCTAssertEqual(object["on"] as? String, phase.rawValue)
        }
    }

    func testHandoffTimingMeasuresTerminalToNextReadyAndWholeVideoAge() {
        var timing = VideoHandoffTimingState()
        timing.videoStarted(now: 10)
        timing.videoTerminated(now: 18)
        let sample = try? XCTUnwrap(timing.nextStepReady(now: 18.25))

        XCTAssertEqual(sample?.msToNextStepReady ?? -1, 250, accuracy: 0.001)
        XCTAssertEqual(sample?.secondsSinceVideoStart ?? -1, 8.25, accuracy: 0.001)
        XCTAssertNil(timing.nextStepReady(now: 19))
    }

    func testPreReadyVideoFailurePreservesOriginUntilLaterVideoStarts() throws {
        var state = VideoPlanHandoffState<String>()
        state.videoTerminated(origin: "A", secondsSinceVideoStart: 4, now: 10)

        let intermediateFailure = videoPlanTerminalAction(
            reason: FullscreenVideoTerminationReason.failed,
            expectsNextStep: true,
            playbackStarted: false
        )
        XCTAssertEqual(intermediateFailure, .preservePendingHandoff)
        state.videoTerminated(origin: "B", secondsSinceVideoStart: nil, now: 10.2)
        XCTAssertEqual(state.pendingOrigin, "A")

        let completion = try XCTUnwrap(state.videoStarted(now: 10.5))
        XCTAssertEqual(completion.origin, "A")
        XCTAssertEqual(completion.timing.msToNextStepReady, 500, accuracy: 0.001)
        XCTAssertEqual(completion.timing.secondsSinceVideoStart, 4.5, accuracy: 0.001)
        XCTAssertNil(state.pendingOrigin)
    }

    func testPreReadyVideoFailurePreservesOriginUntilPlayableReady() throws {
        var state = VideoPlanHandoffState<String>()
        state.videoTerminated(origin: "A", secondsSinceVideoStart: 2, now: 8)
        state.videoTerminated(origin: "B", secondsSinceVideoStart: nil, now: 8.1)

        let completion = try XCTUnwrap(state.nextStepReady(now: 8.3))
        XCTAssertEqual(completion.origin, "A")
        XCTAssertEqual(completion.timing.msToNextStepReady, 300, accuracy: 0.001)
        XCTAssertEqual(completion.timing.secondsSinceVideoStart, 2.3, accuracy: 0.001)
    }

    func testNormalVideoToVideoHandoffCompletesBeforeTrackingNextOrigin() throws {
        var state = VideoPlanHandoffState<String>()
        state.videoTerminated(origin: "A", secondsSinceVideoStart: 3, now: 7)

        let first = try XCTUnwrap(state.videoStarted(now: 7.25))
        XCTAssertEqual(first.origin, "A")
        XCTAssertEqual(first.timing.msToNextStepReady, 250, accuracy: 0.001)

        state.videoTerminated(origin: "B", secondsSinceVideoStart: 1.5, now: 8.75)
        XCTAssertEqual(state.pendingOrigin, "B")
    }

    func testExhaustedVideoChainClosesPreservedOrigin() {
        var state = VideoPlanHandoffState<String>()
        state.videoTerminated(origin: "A", secondsSinceVideoStart: 5, now: 12)
        state.videoTerminated(origin: "B", secondsSinceVideoStart: nil, now: 12.1)

        XCTAssertEqual(state.closePending(), "A")
        XCTAssertNil(state.closePending())
    }

    func testQuartileAndPauseTelemetryStateMachinesAreOneShot() {
        var quartiles = VideoQuartileState()
        XCTAssertEqual(quartiles.crossed(position: 2.4, duration: 10), [])
        XCTAssertEqual(quartiles.crossed(position: 7.6, duration: 10), [50])
        XCTAssertEqual(quartiles.crossed(position: 10, duration: 10), [])

        var pause = VideoPauseTelemetryState()
        XCTAssertEqual(pause.pause(now: 5) { "backgrounded" }, "backgrounded")
        XCTAssertNil(pause.pause(now: 6) { "store_presented" })
        let resumed = pause.resume(now: 7.25)
        XCTAssertEqual(resumed?.reason, "backgrounded")
        XCTAssertEqual(resumed?.pausedMs ?? -1, 2_250, accuracy: 0.001)
        XCTAssertNil(pause.resume(now: 8))
    }

    func testPauseTelemetryResolvesProviderAtPauseAndRetainsReasonForResume() {
        var liveReason = "playback"
        var providerCalls = 0
        let reasonProvider = {
            providerCalls += 1
            return liveReason
        }
        var pause = VideoPauseTelemetryState()

        liveReason = "audio_interruption"
        XCTAssertEqual(
            pause.pause(now: 5, reasonProvider: reasonProvider),
            "audio_interruption"
        )
        XCTAssertNil(pause.pause(now: 5.5, reasonProvider: reasonProvider))
        XCTAssertEqual(providerCalls, 1)
        liveReason = "backgrounded"
        XCTAssertEqual(pause.resume(now: 6)?.reason, "audio_interruption")
    }

    func testCanonicalPoolAliasAndValidVideoClipRules() throws {
        let canonical = try decodeInterstitial(#"""
        {
          "ad_inserted":true,"video_contract":2,
          "creative":{"type":"video","url":"https://cdn.example/a.mp4","video_pool":"ugc","pool":"trailer","clip_index":1}
        }
        """#)
        let alias = try decodeRewarded(#"""
        {
          "video_contract":2,
          "creative":{"type":"video","url":"https://cdn.example/b.mp4","pool":"gameplay","clip_index":2}
        }
        """#)
        let invalid = try decodeInterstitial(#"""
        {
          "ad_inserted":true,"video_contract":2,
          "creative":{"type":"video","url":"https://cdn.example/c.mp4","video_pool":"ugc","clip_index":3}
        }
        """#)
        let playable = try decodeInterstitial(#"""
        {
          "ad_inserted":true,"rendered_html":"HTML","video_contract":2,
          "creative":{"type":"playable","clip_index":0}
        }
        """#)

        XCTAssertEqual(canonical.creative?.videoPool, "ugc")
        XCTAssertEqual(alias.creative?.videoPool, "gameplay")
        XCTAssertTrue(canonical.creative?.isVideoPlanV2Clip == true)
        XCTAssertTrue(canonical.primaryUsesVideoPlanV2)
        XCTAssertTrue(alias.primaryUsesVideoPlanV2)
        XCTAssertFalse(invalid.creative?.isVideoPlanV2Clip == true)
        XCTAssertTrue(invalid.primaryUsesVideoPlanV2)
        XCTAssertTrue(playable.usesVideoPlanV2Contract)
        XCTAssertFalse(playable.creative?.isVideoPlanV2Clip == true)
        XCTAssertFalse(playable.primaryUsesVideoPlanV2)
    }

    func testFallbackNestedAndFlatMetadataMergePerField() throws {
        let ad = try XCTUnwrap(try decodeFallbacks(#"""
        {"video_plan_version":"video_plan_v2","ads":[{
          "type":"video","url":"https://flat.example/video.mp4","poster_url":"https://flat.example/poster.jpg",
          "cta":"Flat CTA","app_icon_url":"https://flat.example/icon.png","app_name":"Flat Name",
          "subtitle":"Flat Subtitle","video_pool":"ugc","clip_index":1,
          "creative":{"type":"video","url":"","cta":"Nested CTA","app_name":"Nested Name","pool":"trailer"}
        }]}
        """#).first)

        XCTAssertEqual(ad.url, "https://flat.example/video.mp4")
        XCTAssertEqual(ad.posterUrl, "https://flat.example/poster.jpg")
        XCTAssertEqual(ad.creative?.cta, "Nested CTA")
        XCTAssertEqual(ad.creative?.appIconUrl, "https://flat.example/icon.png")
        XCTAssertEqual(ad.creative?.appName, "Nested Name")
        XCTAssertEqual(ad.creative?.subtitle, "Flat Subtitle")
        XCTAssertEqual(ad.creative?.videoPool, "trailer")
        XCTAssertEqual(ad.creative?.clipIndex, 1)
        XCTAssertFalse(ad.usesVideoPlanV2Contract)
        XCTAssertFalse(ad.usesVideoPlanV2)
    }

    func testStyleRequirementsDegradeToCornerCTA() {
        XCTAssertEqual(resolvedVideoChromeStyle(
            requested: .bottomBar, hasAppIcon: false, hasAppName: true
        ), .cornerCTA)
        XCTAssertEqual(resolvedVideoChromeStyle(
            requested: .floatingPill, hasAppIcon: true, hasAppName: false
        ), .floatingPill)
        XCTAssertEqual(resolvedVideoChromeStyle(
            requested: .bottomCard, hasAppIcon: true, hasAppName: false
        ), .cornerCTA)
        XCTAssertEqual(resolvedVideoChromeStyle(
            requested: .feedCard, hasAppIcon: true, hasAppName: true
        ), .feedCard)
    }

    func testEffectiveVideoClosePositionRelocatesOnlyBottomLeftProgressBar() {
        let treatments: [CloseTreatment] = [
            .hidden, .countdownCircle, .progressBar, .rewardOrCloseLabel,
        ]
        let positions: [ClosePosition] = [.topRight, .topLeft, .bottomLeft]

        for treatment in treatments {
            for position in positions {
                let expected: ClosePosition = treatment == .progressBar && position == .bottomLeft
                    ? .topRight
                    : position
                XCTAssertEqual(
                    effectiveVideoClosePosition(treatment: treatment, position: position),
                    expected,
                    "treatment=\(treatment) position=\(position)"
                )
                XCTAssertEqual(
                    videoBottomProgressBarObstructsChrome(
                        treatment: treatment,
                        position: position
                    ),
                    treatment == .progressBar && position == .bottomLeft,
                    "bottom obstruction treatment=\(treatment) position=\(position)"
                )
            }
        }
    }

    func testIndependentTwoToneBarIsBottomObstructionForEveryBottomLeftCloseTreatment() {
        let treatments: [CloseTreatment] = [
            .hidden, .countdownCircle, .progressBar, .rewardOrCloseLabel,
        ]
        for treatment in treatments {
            XCTAssertTrue(videoBottomProgressBarObstructsChrome(
                treatment: treatment,
                position: .bottomLeft,
                progressBarStyle: .twoTone
            ))
            XCTAssertEqual(
                effectiveVideoClosePosition(
                    treatment: treatment,
                    position: .bottomLeft,
                    progressBarStyle: .twoTone
                ),
                .topRight
            )
            #if os(iOS)
            XCTAssertTrue(closeBarAtBottom(
                treatment,
                .bottomLeft,
                progressBarStyle: .twoTone
            ))
            #endif
        }

        for position in [ClosePosition.topLeft, .topRight] {
            XCTAssertFalse(videoBottomProgressBarObstructsChrome(
                treatment: .hidden,
                position: position,
                progressBarStyle: .twoTone
            ))
            XCTAssertEqual(
                effectiveVideoClosePosition(
                    treatment: .countdownCircle,
                    position: position,
                    progressBarStyle: .twoTone
                ),
                position
            )
        }
    }

    func testBottomLeadingChromeClearanceCoversCompleteStyleAndPositionMatrix() {
        let positions: [ClosePosition] = [.topRight, .topLeft, .bottomLeft]
        let affectedStyles: [VideoChromeStyle] = [
            .bottomBar, .bottomCard, .feedCard, .floatingPill,
        ]

        for position in positions {
            for style in VideoChromeStyle.allCases {
                let expected = position == .bottomLeft && affectedStyles.contains(style)
                XCTAssertEqual(
                    videoChromeNeedsBottomLeadingClearance(
                        effectiveClosePosition: position,
                        resolvedStyle: style
                    ),
                    expected,
                    "position=\(position) style=\(style)"
                )
                let additional = videoChromeAdditionalLeadingPadding(
                    effectiveClosePosition: position,
                    resolvedStyle: style
                )
                XCTAssertEqual(additional, expected ? 100 : 0)
                if expected { XCTAssertEqual(additional + 12, 112) }
            }
        }
    }

    func testPrimaryRelocationAndFallbackRawPositionHaveDistinctClearance() {
        let primaryPosition = effectiveVideoClosePosition(
            treatment: .progressBar,
            position: .bottomLeft
        )
        let fallbackPosition = ClosePosition.bottomLeft
        let affectedStyles: [VideoChromeStyle] = [
            .bottomBar, .bottomCard, .feedCard, .floatingPill,
        ]

        for style in VideoChromeStyle.allCases {
            XCTAssertFalse(videoChromeNeedsBottomLeadingClearance(
                effectiveClosePosition: primaryPosition,
                resolvedStyle: style
            ), "primary style=\(style)")
            XCTAssertEqual(
                videoChromeNeedsBottomLeadingClearance(
                    effectiveClosePosition: fallbackPosition,
                    resolvedStyle: style
                ),
                affectedStyles.contains(style),
                "fallback style=\(style)"
            )
        }
    }

    func testBottomProgressBarObstructionLiftsEveryChromeStyle() {
        for style in VideoChromeStyle.allCases {
            XCTAssertEqual(
                videoChromeAdditionalBottomPadding(bottomProgressBarObstructsChrome: false),
                0,
                "unobstructed style=\(style)"
            )
            let additional = videoChromeAdditionalBottomPadding(
                bottomProgressBarObstructsChrome: true
            )
            XCTAssertEqual(additional, 26, "obstructed style=\(style)")
            XCTAssertEqual(additional + 12, 38, "total exclusion style=\(style)")
        }
    }

    func testStorePromptMuteOverlapUsesConfiguredClosePosition() {
        let positions: [ClosePosition] = [.topRight, .topLeft, .bottomLeft]
        for position in positions {
            XCTAssertEqual(
                videoStorePromptSharesMuteCorner(configuredClosePosition: position),
                position != .bottomLeft,
                "position=\(position)"
            )
        }

        for hasChrome in [false, true] {
            for promptVisible in [false, true] {
                for sharesCorner in [false, true] {
                    XCTAssertEqual(
                        videoMuteTopPadding(
                            hasVideoChrome: hasChrome,
                            storePromptVisible: promptVisible,
                            storePromptSharesMuteCorner: sharesCorner
                        ),
                        hasChrome && promptVisible && sharesCorner ? 64 : 12
                    )
                }
            }
        }

        let relocated = effectiveVideoClosePosition(
            treatment: .progressBar,
            position: .bottomLeft
        )
        XCTAssertEqual(relocated, .topRight)
        XCTAssertFalse(videoStorePromptSharesMuteCorner(configuredClosePosition: .bottomLeft))
    }

    func testVideoAudioWatchAccountingAggregatesMutedAndUnmutedMediaTime() {
        var accounting = VideoAudioWatchAccounting()
        accounting.update(playedSeconds: 2, isMuted: false)
        accounting.update(playedSeconds: 3.25, isMuted: true)
        accounting.update(playedSeconds: 3, isMuted: false)

        XCTAssertEqual(accounting.unmutedMilliseconds, 2_000)
        XCTAssertEqual(accounting.mutedMilliseconds, 1_250)
    }

    func testProgressPublicationCoalescesUnchangedSamplesWithoutAffectingWatchAccounting() {
        XCTAssertFalse(shouldPublishVideoProgress(previous: 1.25, next: 1.25))
        XCTAssertFalse(shouldPublishVideoProgress(previous: 1.25, next: .nan))
        XCTAssertTrue(shouldPublishVideoProgress(previous: 1.25, next: 1.5))

        var accounting = VideoAudioWatchAccounting()
        accounting.update(playedSeconds: 1.25, isMuted: true)
        accounting.update(playedSeconds: 1.5, isMuted: false)
        XCTAssertEqual(accounting.mutedMilliseconds, 1_250)
        XCTAssertEqual(accounting.unmutedMilliseconds, 250)
    }

    func testPresentationWatchAccountingAggregatesTwoClipsThroughFailurePlayableAndClose() {
        var accounting = VideoPlanPresentationWatchAccounting<String>()

        XCTAssertEqual(
            accounting.update(playerID: "clip-1", mutedMilliseconds: 0, unmutedMilliseconds: 400),
            VideoPlanPresentationWatchTotals(mutedMilliseconds: 0, unmutedMilliseconds: 400)
        )
        XCTAssertEqual(
            accounting.update(playerID: "clip-1", mutedMilliseconds: 0, unmutedMilliseconds: 1_250),
            VideoPlanPresentationWatchTotals(mutedMilliseconds: 0, unmutedMilliseconds: 1_250)
        )

        // Clip 2 fails after muted playback. A playable handoff and close add no video watch time.
        XCTAssertEqual(
            accounting.update(playerID: "clip-2", mutedMilliseconds: 350, unmutedMilliseconds: 0),
            VideoPlanPresentationWatchTotals(mutedMilliseconds: 350, unmutedMilliseconds: 1_250)
        )
        XCTAssertEqual(
            accounting.update(playerID: "clip-2", mutedMilliseconds: 900, unmutedMilliseconds: 0),
            VideoPlanPresentationWatchTotals(mutedMilliseconds: 900, unmutedMilliseconds: 1_250)
        )
        XCTAssertEqual(accounting.totals.mutedMilliseconds, 900)
        XCTAssertEqual(accounting.totals.unmutedMilliseconds, 1_250)
    }

    func testPresentationWatchAccountingDeduplicatesSnapshotsTerminalRetriesAndViewRecreation() {
        var accounting = VideoPlanPresentationWatchAccounting<String>()

        for _ in 0..<3 {
            _ = accounting.update(
                playerID: "clip-1-player",
                mutedMilliseconds: 0,
                unmutedMilliseconds: 1_000
            )
        }
        // A stale recreated view cannot move a cumulative player snapshot backwards.
        _ = accounting.update(
            playerID: "clip-1-player",
            mutedMilliseconds: 0,
            unmutedMilliseconds: 700
        )
        _ = accounting.update(
            playerID: "clip-1-player",
            mutedMilliseconds: 0,
            unmutedMilliseconds: 1_200
        )

        // A replacement player is a distinct attempt; its eligible playback counts once too.
        for _ in 0..<2 {
            _ = accounting.update(
                playerID: "clip-1-retry-player",
                mutedMilliseconds: 300,
                unmutedMilliseconds: 0
            )
        }

        XCTAssertEqual(
            accounting.totals,
            VideoPlanPresentationWatchTotals(
                mutedMilliseconds: 300,
                unmutedMilliseconds: 1_200
            )
        )
    }

    func testInterstitialPrimaryToNextHandoffEmitsOnceWithAggregatedWatchTotals() throws {
        try assertPrimaryToNextHandoff(
            adFormat: "interstitial",
            mutedMilliseconds: 750,
            unmutedMilliseconds: 1_250
        )
    }

    func testRewardedPrimaryToNextHandoffEmitsOnceWithAggregatedWatchTotals() throws {
        try assertPrimaryToNextHandoff(
            adFormat: "rewarded",
            mutedMilliseconds: 500,
            unmutedMilliseconds: 2_000
        )
    }

    private func assertPrimaryToNextHandoff(
        adFormat: String,
        mutedMilliseconds: Int,
        unmutedMilliseconds: Int
    ) throws {
        var accounting = VideoPlanPresentationWatchAccounting<String>()
        var handoff = VideoPlanHandoffState<VideoPlanHandoffTelemetry>()
        _ = accounting.update(
            playerID: "primary",
            mutedMilliseconds: mutedMilliseconds,
            unmutedMilliseconds: unmutedMilliseconds
        )
        // A terminal flush can repeat the latest sampled snapshot without double counting it.
        let terminalTotals = accounting.update(
            playerID: "primary",
            mutedMilliseconds: mutedMilliseconds,
            unmutedMilliseconds: unmutedMilliseconds
        )
        handoff.videoTerminated(
            origin: VideoPlanHandoffTelemetry(
                adFormat: adFormat,
                adUnitId: "unit",
                adId: "ad",
                serveId: "serve",
                creative: nil,
                behavior: nil,
                muted: mutedMilliseconds > 0,
                mutedWatchMs: terminalTotals.mutedMilliseconds,
                unmutedWatchMs: terminalTotals.unmutedMilliseconds,
                videoPositionS: 2,
                durationS: 4,
                secondsSinceVideoStart: 2,
                reason: FullscreenVideoTerminationReason.completed
            ),
            secondsSinceVideoStart: 2,
            now: 10
        )

        var emitted: [(VideoPlanHandoffTelemetry, VideoPlanPresentationWatchTotals)] = []
        if let completion = handoff.nextStepReady(now: 10.25) {
            emitted.append((completion.origin, accounting.totals))
        }
        if let completion = handoff.nextStepReady(now: 10.5) {
            emitted.append((completion.origin, accounting.totals))
        }

        let event = try XCTUnwrap(emitted.first)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(event.0.adFormat, adFormat)
        XCTAssertEqual(event.0.reason, FullscreenVideoTerminationReason.completed)
        XCTAssertEqual(event.0.mutedWatchMs, mutedMilliseconds)
        XCTAssertEqual(event.0.unmutedWatchMs, unmutedMilliseconds)
        XCTAssertEqual(
            event.0.mutedWatchMs + event.0.unmutedWatchMs,
            mutedMilliseconds + unmutedMilliseconds
        )
        XCTAssertEqual(event.1.mutedMilliseconds, mutedMilliseconds)
        XCTAssertEqual(event.1.unmutedMilliseconds, unmutedMilliseconds)
        XCTAssertEqual(
            event.1.mutedMilliseconds + event.1.unmutedMilliseconds,
            mutedMilliseconds + unmutedMilliseconds
        )
    }

    func testFinalVideoPlaybackAccountsMutedTail() {
        var clock = VideoVisiblePlaybackClock()
        var accounting = VideoAudioWatchAccounting()
        clock.admitFirstFrame(mediaTime: 4)
        let sampled = clock.update(mediaTime: 5)
        accounting.update(playedSeconds: sampled, isMuted: true)

        let final = finalizeVideoPlayback(
            clock: &clock,
            accounting: &accounting,
            finalMediaTime: 5.25,
            isMuted: true
        )

        XCTAssertEqual(final.playedSeconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(final.mutedWatchMilliseconds, 1_250)
        XCTAssertEqual(final.unmutedWatchMilliseconds, 0)
    }

    func testFinalVideoPlaybackAccountsUnmutedTail() {
        var clock = VideoVisiblePlaybackClock()
        var accounting = VideoAudioWatchAccounting()
        clock.admitFirstFrame(mediaTime: 2)
        let sampled = clock.update(mediaTime: 3.5)
        accounting.update(playedSeconds: sampled, isMuted: false)

        let final = finalizeVideoPlayback(
            clock: &clock,
            accounting: &accounting,
            finalMediaTime: 3.75,
            isMuted: false
        )

        XCTAssertEqual(final.playedSeconds, 1.75, accuracy: 0.001)
        XCTAssertEqual(final.mutedWatchMilliseconds, 0)
        XCTAssertEqual(final.unmutedWatchMilliseconds, 1_750)
    }

    func testFinalVideoPlaybackAccountsShortClipWithoutPeriodicSample() {
        var clock = VideoVisiblePlaybackClock()
        var accounting = VideoAudioWatchAccounting()
        clock.admitFirstFrame(mediaTime: 10)

        let final = finalizeVideoPlayback(
            clock: &clock,
            accounting: &accounting,
            finalMediaTime: 10.08,
            isMuted: false
        )

        XCTAssertEqual(final.playedSeconds, 0.08, accuracy: 0.001)
        XCTAssertEqual(final.mutedWatchMilliseconds, 0)
        XCTAssertEqual(final.unmutedWatchMilliseconds, 80)
    }

    func testVideoTelemetryWireFieldsAreExact() throws {
        var event = TelemetryEvent(
            type: TelemetryType.lifecycle,
            name: FullscreenVideoTelemetryStage.complete,
            eventId: "event",
            timestamp: 1
        )
        event.clipIndex = 2
        event.muted = false
        event.impressionId = "imp-1"
        event.style = "feed_card"
        event.skoverlayEnabled = true
        event.skoverlayDelaySeconds = 3
        event.videoPositionS = 2.5
        event.pool = "ugc"
        event.durationS = 10
        event.quartile = 25
        event.reason = "background"
        event.pausedMs = 200
        event.watchedS = 2
        event.secondsUnmuted = 1.6
        event.secondsMuted = 0.4
        event.msToNextStepReady = 30
        event.secondsSinceVideoStart = 2.6
        event.on = "video"
        event.visibleS = 4
        event.videoError = "none"
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )

        XCTAssertEqual(object["name"] as? String, "video_complete")
        XCTAssertEqual(object["clip_index"] as? Int, 2)
        XCTAssertEqual(object["muted"] as? Bool, false)
        XCTAssertNil(object["video_pool"])
        XCTAssertNil(object["video_style"])
        XCTAssertNil(object["muted_watch_ms"])
        XCTAssertNil(object["unmuted_watch_ms"])
        XCTAssertEqual(object["impression_id"] as? String, "imp-1")
        XCTAssertEqual(object["style"] as? String, "feed_card")
        XCTAssertEqual(object["skoverlay_enabled"] as? Bool, true)
        XCTAssertEqual(object["skoverlay_delay_seconds"] as? Int, 3)
        XCTAssertEqual(object["video_position_s"] as? Double, 2.5)
        XCTAssertEqual(object["pool"] as? String, "ugc")
        XCTAssertEqual(object["duration_s"] as? Double, 10)
        XCTAssertEqual(object["quartile"] as? Int, 25)
        XCTAssertEqual(object["reason"] as? String, "background")
        XCTAssertEqual(object["paused_ms"] as? Double, 200)
        XCTAssertEqual(object["watched_s"] as? Double, 2)
        XCTAssertEqual(object["seconds_unmuted"] as? Double, 1.6)
        XCTAssertEqual(object["seconds_muted"] as? Double, 0.4)
        XCTAssertEqual(object["ms_to_next_step_ready"] as? Double, 30)
        XCTAssertEqual(object["seconds_since_video_start"] as? Double, 2.6)
        XCTAssertEqual(object["on"] as? String, "video")
        XCTAssertEqual(object["visible_s"] as? Double, 4)
        XCTAssertEqual(object["error"] as? String, "none")
        XCTAssertEqual(FullscreenVideoTelemetryStage.mute, "video_mute")
        XCTAssertEqual(FullscreenVideoTelemetryStage.unmute, "video_unmute")
        XCTAssertEqual(FullscreenVideoTelemetryStage.muteToggle, "video_mute_toggle")
        XCTAssertEqual(FullscreenVideoTelemetryStage.duration, "video_duration")
        XCTAssertEqual(FullscreenVideoTelemetryStage.quartile, "video_duration")
        XCTAssertEqual(FullscreenVideoTelemetryStage.pause, "video_pause")
        XCTAssertEqual(FullscreenVideoTelemetryStage.resume, "video_resume")
        XCTAssertEqual(FullscreenVideoTelemetryStage.close, "video_close")
        XCTAssertEqual(FullscreenVideoTelemetryStage.handoff, "video_handoff")
        XCTAssertEqual(FullscreenVideoTelemetryStage.skoverlayShown, "skoverlay_shown")
        XCTAssertEqual(FullscreenVideoTelemetryStage.skoverlayDismissed, "skoverlay_dismissed")
        XCTAssertEqual(FullscreenVideoTelemetryStage.skoverlayFailed, "skoverlay_failed")
    }

    func testLegacyVideoLifecycleSerializationHasNoV2Fields() throws {
        let event = TelemetryEvent(
            type: TelemetryType.lifecycle,
            name: FullscreenVideoTelemetryStage.start,
            eventId: "legacy",
            timestamp: 1
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        for key in [
            "video_pool", "video_style", "muted_watch_ms", "unmuted_watch_ms",
            "impression_id", "style",
            "skoverlay_enabled", "video_position_s", "pool", "duration_s", "quartile",
            "paused_ms", "watched_s", "ms_to_next_step_ready", "on", "visible_s", "error",
        ] {
            XCTAssertNil(object[key], "Legacy video event unexpectedly serialized \(key)")
        }
    }

    func testFallbackVideoAndBehaviorDecodeAndClamp() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"ad_id":"v","type":"video","url":"https://cdn.example/v.mp4","poster_url":"https://cdn.example/p.jpg","ad_behavior":{"close":{"delay_seconds":999,"treatment":"progress_bar","position":"top_left"}}}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.mediaType, .video)
        XCTAssertEqual(ad.adBehavior.close.delaySeconds, 60)
        XCTAssertEqual(ad.adBehavior.close.treatment, .countdownCircle)
        XCTAssertEqual(ad.adBehavior.close.position, .topLeft)
    }

    func testFallbackRouteFieldsDecodeTolerantly() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"ad_id":"v","type":"video","url":"https://cdn.example/v.mp4","destination":"web","tracking_url":"https://tracker.example/click","ios_store_url":"https://apps.apple.com/app/id123456","android_store_url":"https://play.google.com/store/apps/details?id=example"}]}"#)
        let ad = try XCTUnwrap(ads.first)

        XCTAssertEqual(ad.destination, "web")
        XCTAssertEqual(ad.destinationKind, .web)
        XCTAssertEqual(ad.trackingUrl, "https://tracker.example/click")
        XCTAssertEqual(ad.iosStoreUrl, "https://apps.apple.com/app/id123456")
        XCTAssertEqual(ad.androidStoreUrl, "https://play.google.com/store/apps/details?id=example")

        let malformed = try decodeFallbacks(#"{"ads":[{"type":"video","url":"https://cdn.example/v.mp4","destination":4,"tracking_url":false,"ios_store_url":[],"android_store_url":{}}]}"#)
        XCTAssertNil(malformed.first?.destination)
        XCTAssertNil(malformed.first?.trackingUrl)
        XCTAssertNil(malformed.first?.iosStoreUrl)
        XCTAssertNil(malformed.first?.androidStoreUrl)
    }

    func testFallbackVideoUsesValidItemRouteBeforeParentRoute() throws {
        let ad = try XCTUnwrap(try decodeFallbacks(#"{"ads":[{"type":"video","url":"https://cdn.example/v.mp4","destination":"web","tracking_url":"https://item.example/click"}]}"#).first)
        let route = fallbackVideoCTARoute(
            ad: ad,
            parentTrackingUrl: "https://parent.example/click",
            parentDestination: .appstore,
            allowsParentFallback: true
        )

        XCTAssertEqual(route?.source, .item)
        XCTAssertEqual(route?.destination, .web)
        XCTAssertEqual(route?.trackingUrl, "https://item.example/click")
    }

    func testInvalidItemRouteDoesNotFallBackToParent() throws {
        let ad = try XCTUnwrap(try decodeFallbacks(#"{"ads":[{"type":"video","url":"https://cdn.example/v.mp4","destination":"web","tracking_url":"file:///invalid"}]}"#).first)

        XCTAssertNil(fallbackVideoCTARoute(
            ad: ad,
            parentTrackingUrl: "https://parent.example/click",
            parentDestination: .appstore,
            allowsParentFallback: true
        ))
    }

    func testDestinationAndAndroidOnlyItemRouteInheritParentOnIOS() throws {
        let ad = try XCTUnwrap(try decodeFallbacks(#"{"ads":[{"type":"video","url":"https://cdn.example/v.mp4","destination":"appstore","android_store_url":"https://play.google.com/store/apps/details?id=example"}]}"#).first)

        XCTAssertFalse(ad.hasIOSItemRoutingFields)
        let route = fallbackVideoCTARoute(
            ad: ad,
            parentTrackingUrl: "https://parent.example/click",
            parentDestination: .appstore,
            allowsParentFallback: true
        )
        XCTAssertEqual(route?.source, .parent)
        XCTAssertEqual(route?.trackingUrl, "https://parent.example/click")
    }

    func testAbsentItemRouteFallsBackOnlyForImperativePresentation() throws {
        let ad = try XCTUnwrap(try decodeFallbacks(#"{"ads":[{"type":"video","url":"https://cdn.example/v.mp4"}]}"#).first)
        let imperative = fallbackVideoCTARoute(
            ad: ad,
            parentTrackingUrl: "https://parent.example/click",
            parentDestination: .appstore,
            allowsParentFallback: true
        )

        XCTAssertEqual(imperative?.source, .parent)
        XCTAssertNil(fallbackVideoCTARoute(ad: ad, allowsParentFallback: false))
    }

    func testFallbackDefaultsAndUnknownTypeUsePlayableHTML() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"ad_id":"a","type":"future","rendered_html":"new","html":"old"}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.mediaType, .playable)
        XCTAssertEqual(ad.renderedHtml, "new")
        XCTAssertEqual(ad.adBehavior.close.delaySeconds, 5)
        XCTAssertEqual(ad.adBehavior.close.treatment, .countdownCircle)
        XCTAssertEqual(ad.adBehavior.close.position, .topRight)
    }

    func testFallbackEmptyAndPartialBehaviorKeepFallbackCloseDefaults() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"rendered_html":"a","ad_behavior":{}},{"rendered_html":"b","ad_behavior":{"close":{"delay_seconds":0,"treatment":"hidden"}}}]}"#)
        XCTAssertEqual(ads[0].adBehavior.close.delaySeconds, 5)
        XCTAssertEqual(ads[0].adBehavior.close.treatment, .countdownCircle)
        XCTAssertEqual(ads[1].adBehavior.close.delaySeconds, 0)
        XCTAssertEqual(ads[1].adBehavior.close.treatment, .hidden)
    }

    func testFallbackDecodeIsLossyAndPreservesOriginalStageIndex() throws {
        let ads = try decodeFallbacks(#"{"ads":[42,{"type":"video","url":"file:///bad"},{"ad_id":"ok","rendered_html":"<html/>","tracking_url":"https://item.example/click"}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ads.count, 1)
        XCTAssertEqual(ad.adId, "ok")
        XCTAssertEqual(ad.sourceIndex, 2)
        XCTAssertEqual(ad.trackingUrl, "https://item.example/click")
        XCTAssertNil(AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: ad.sourceIndex))
    }

    func testSkippedFirstFallbackDoesNotShiftEndScreenTwoTrigger() throws {
        let ads = try decodeFallbacks(#"{"ads":[{"type":"video","url":"bad"},{"ad_id":"second","html":"<html/>"}]}"#)
        let ad = try XCTUnwrap(ads.first)
        XCTAssertEqual(ad.sourceIndex, 1)
        XCTAssertEqual(
            AutoStoreRedirectTrigger.endScreenTrigger(forFallbackIndex: ad.sourceIndex),
            .endScreen2Open
        )
    }

    func testVideoGateUsesShorterOfConfiguredDelayAndDuration() {
        var gate = VideoPlaybackGate(configuredDelay: 30)
        gate.update(duration: 8, played: 3.9)
        XCTAssertEqual(gate.gateDuration, 8)
        XCTAssertFalse(gate.isUnlocked)
        XCTAssertFalse(gate.reachedAssetMidpoint)

        gate.update(duration: 8, played: 4)
        XCTAssertTrue(gate.reachedAssetMidpoint)
        XCTAssertEqual(gate.progress, 0.5, accuracy: 0.001)

        gate.update(duration: 8, played: 8)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.secondsRemaining, 0)
        XCTAssertEqual(gate.earnedCompletionReason, .videoCompleted)
    }

    func testVideoEndUnlocksEvenBeforeGate() {
        var gate = VideoPlaybackGate(configuredDelay: 30)
        gate.update(duration: 20, played: 2, ended: true)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.earnedCompletionReason, .videoCompleted)
    }

    func testVideoCompletionSynchronouslyProducesEarnedTerminalOutcome() throws {
        var gate = VideoPlaybackGate(configuredDelay: 30)
        var completion = RewardCompletionState()

        gate.update(duration: 20, played: 2, ended: true)
        completion.earn(reason: try XCTUnwrap(gate.earnedCompletionReason))
        let outcome = rewardedTerminalOutcome(
            earned: completion.earned,
            actualElapsedPlayTime: 2,
            completionReason: completion.reason
        )

        XCTAssertTrue(outcome.earned)
        XCTAssertEqual(outcome.completionReason, .videoCompleted)
    }

    func testVideoConfiguredGateUsesDurationElapsedReason() {
        var gate = VideoPlaybackGate(configuredDelay: 5)
        gate.update(duration: 20, played: 5)

        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.earnedCompletionReason, .durationElapsed)
    }

    func testInterstitialFirstFrameSnapshotUnlocksZeroDelayImmediately() {
        var gate = VideoPlaybackGate(configuredDelay: 0)

        gate.update(duration: nil, played: 0)

        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.progress, 1)
        XCTAssertEqual(gate.secondsRemaining, 0)
        XCTAssertEqual(gate.earnedCompletionReason, .durationElapsed)
    }

    func testInterstitialFirstFrameSnapshotPreservesKnownPositiveGateProgress() {
        var gate = VideoPlaybackGate(configuredDelay: 5)

        gate.update(duration: 20, played: 2)

        XCTAssertFalse(gate.isUnlocked)
        XCTAssertEqual(gate.progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(gate.secondsRemaining, 3)
    }

    func testReadyToPlayUnknownDurationBecomesReadyAndCanPlayWithoutWeakeningItemReadiness() {
        var gate = VideoPlaybackGate(configuredDelay: 5)
        gate.update(duration: nil, played: 0)

        XCTAssertEqual(
            fullscreenVideoReadyStatus(status: .preparing, itemReadyToPlay: true),
            .ready
        )
        XCTAssertTrue(shouldPlayFullscreenVideo(
            wantsPlayback: true,
            requiresUserResume: false,
            appActive: true,
            presentationBlocked: false,
            audioInterrupted: false,
            itemReadyToPlay: true
        ))
        XCTAssertNil(gate.duration)
        XCTAssertFalse(gate.isUnlocked)

        gate.update(duration: .infinity, played: 5.1)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.progress, 1)
        XCTAssertEqual(gate.secondsRemaining, 0)

        XCTAssertEqual(
            fullscreenVideoReadyStatus(status: .preparing, itemReadyToPlay: false),
            .preparing
        )
        XCTAssertFalse(shouldPlayFullscreenVideo(
            wantsPlayback: true,
            requiresUserResume: false,
            appActive: true,
            presentationBlocked: false,
            audioInterrupted: false,
            itemReadyToPlay: false
        ))
    }

    func testUnknownDurationUnlocksAtConfiguredPlayedTimeAndLaterFiniteDurationCanClampShorter() {
        var gate = VideoPlaybackGate(configuredDelay: 8)
        gate.update(duration: nil, played: 8.25)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.gateDuration, 8)

        var clamped = VideoPlaybackGate(configuredDelay: 8)
        clamped.update(duration: nil, played: 3)
        XCTAssertFalse(clamped.isUnlocked)
        clamped.update(duration: 2, played: 3)
        XCTAssertEqual(clamped.gateDuration, 2)
        XCTAssertTrue(clamped.isUnlocked)
    }

    func testTimeControlCallbacksFollowNormalReadyPlayingPausedOrder() {
        var status = FullscreenVideoStatus.ready

        var transition = videoTimeControlTransition(status: status, stopped: false, event: .waiting)
        XCTAssertEqual(transition, VideoTimeControlTransition(status: .ready, effect: .waiting))
        status = transition.status

        transition = videoTimeControlTransition(status: status, stopped: false, event: .playing)
        XCTAssertEqual(transition, VideoTimeControlTransition(status: .playing, effect: .beganPlaying))
        status = transition.status

        transition = videoTimeControlTransition(status: status, stopped: false, event: .paused)
        XCTAssertEqual(transition, VideoTimeControlTransition(status: .paused, effect: .paused))
        status = transition.status

        transition = videoTimeControlTransition(status: status, stopped: false, event: .unknown)
        XCTAssertEqual(transition, VideoTimeControlTransition(status: .paused, effect: .none))
    }

    func testLatePlayingPausedWaitingAndUnknownCallbacksCannotReviveFailedPlayerForPoolReuse() {
        let failure = FullscreenVideoStatus.failed(.playbackFailed)
        var status = failure

        for event in [
            VideoTimeControlEvent.playing,
            .paused,
            .waiting,
            .unknown,
        ] {
            let transition = videoTimeControlTransition(status: status, stopped: false, event: event)
            XCTAssertEqual(transition.status, failure)
            XCTAssertEqual(transition.effect, .cancelDeadlines)
            status = transition.status
            XCTAssertFalse(shouldReusePreparedVideoPlayer(
                status: status,
                isStopped: false,
                isActive: false
            ))
        }
    }

    func testLateTimeControlCallbacksKeepEndedStateTerminalWithoutScheduling() {
        for event in [
            VideoTimeControlEvent.playing,
            .paused,
            .waiting,
            .unknown,
        ] {
            XCTAssertEqual(
                videoTimeControlTransition(status: .ended, stopped: false, event: event),
                VideoTimeControlTransition(status: .ended, effect: .cancelDeadlines)
            )
        }
    }

    func testLateTimeControlCallbacksAfterStopPreserveStatusAndCancelDeadlines() {
        for event in [
            VideoTimeControlEvent.playing,
            .paused,
            .waiting,
            .unknown,
        ] {
            let transition = videoTimeControlTransition(status: .ready, stopped: true, event: event)
            XCTAssertEqual(transition, VideoTimeControlTransition(
                status: .ready,
                effect: .cancelDeadlines
            ))
            XCTAssertFalse(shouldReusePreparedVideoPlayer(
                status: transition.status,
                isStopped: true,
                isActive: false
            ))
        }
    }

    func testQueuedLayerReadyCallbackRequiresCurrentGenerationPlayerAndLayer() {
        let player = NSObject()
        let replacementPlayer = NSObject()
        let layer = NSObject()
        let replacementLayer = NSObject()
        let playerID = ObjectIdentifier(player)
        let layerID = ObjectIdentifier(layer)

        XCTAssertTrue(shouldAcceptVideoLayerReadyCallback(
            callbackGeneration: 4,
            installationGeneration: 4,
            callbackPlayerIdentity: playerID,
            installedPlayerIdentity: playerID,
            callbackLayerIdentity: layerID,
            installedLayerIdentity: layerID,
            layerPlayerIdentity: playerID,
            isReadyForDisplay: true,
            firstFrameReported: false
        ))
        XCTAssertFalse(shouldAcceptVideoLayerReadyCallback(
            callbackGeneration: 3,
            installationGeneration: 4,
            callbackPlayerIdentity: playerID,
            installedPlayerIdentity: playerID,
            callbackLayerIdentity: layerID,
            installedLayerIdentity: layerID,
            layerPlayerIdentity: playerID,
            isReadyForDisplay: true,
            firstFrameReported: false
        ))
        XCTAssertFalse(shouldAcceptVideoLayerReadyCallback(
            callbackGeneration: 4,
            installationGeneration: 4,
            callbackPlayerIdentity: playerID,
            installedPlayerIdentity: ObjectIdentifier(replacementPlayer),
            callbackLayerIdentity: layerID,
            installedLayerIdentity: layerID,
            layerPlayerIdentity: playerID,
            isReadyForDisplay: true,
            firstFrameReported: false
        ))
        XCTAssertFalse(shouldAcceptVideoLayerReadyCallback(
            callbackGeneration: 4,
            installationGeneration: 4,
            callbackPlayerIdentity: playerID,
            installedPlayerIdentity: playerID,
            callbackLayerIdentity: layerID,
            installedLayerIdentity: ObjectIdentifier(replacementLayer),
            layerPlayerIdentity: playerID,
            isReadyForDisplay: true,
            firstFrameReported: false
        ))
        XCTAssertFalse(shouldAcceptVideoLayerReadyCallback(
            callbackGeneration: 4,
            installationGeneration: 4,
            callbackPlayerIdentity: playerID,
            installedPlayerIdentity: playerID,
            callbackLayerIdentity: layerID,
            installedLayerIdentity: layerID,
            layerPlayerIdentity: ObjectIdentifier(replacementPlayer),
            isReadyForDisplay: true,
            firstFrameReported: false
        ))
    }

    func testUninstallGenerationAndExistingLatchRejectQueuedLayerCallback() {
        let player = NSObject()
        let layer = NSObject()
        let playerID = ObjectIdentifier(player)
        let layerID = ObjectIdentifier(layer)

        for (generation, ready, reported) in [
            (6 as UInt64, true, false),
            (5, false, false),
            (5, true, true),
        ] {
            XCTAssertFalse(shouldAcceptVideoLayerReadyCallback(
                callbackGeneration: 5,
                installationGeneration: generation,
                callbackPlayerIdentity: playerID,
                installedPlayerIdentity: playerID,
                callbackLayerIdentity: layerID,
                installedLayerIdentity: layerID,
                layerPlayerIdentity: playerID,
                isReadyForDisplay: ready,
                firstFrameReported: reported
            ))
        }
    }

    func testDisappearedAndReplacementSurfaceCallbacksAreRejected() {
        let player = NSObject()
        let replacement = NSObject()
        let playerID = ObjectIdentifier(player)

        XCTAssertFalse(shouldAcceptFullscreenVideoFirstFrameCallback(
            presentationActive: false,
            failureHandled: false,
            callbackPlayerIdentity: playerID,
            currentPlayerIdentity: playerID,
            status: .playing,
            isStopped: false
        ))
        XCTAssertFalse(shouldAcceptFullscreenVideoFirstFrameCallback(
            presentationActive: true,
            failureHandled: false,
            callbackPlayerIdentity: playerID,
            currentPlayerIdentity: ObjectIdentifier(replacement),
            status: .playing,
            isStopped: false
        ))
        XCTAssertTrue(shouldAcceptFullscreenVideoFirstFrameCallback(
            presentationActive: true,
            failureHandled: false,
            callbackPlayerIdentity: playerID,
            currentPlayerIdentity: playerID,
            status: .playing,
            isStopped: false
        ))
    }

    func testLayerReadinessBeforeAppearanceIsRetainedAndReplayed() {
        let player = NSObject()
        let identity = ObjectIdentifier(player)
        var state = VideoSurfaceFirstFrameHandoffState()

        state.layerBecameReady(playerIdentity: identity, currentPlayerIdentity: identity)
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        state.setPresentationActive(true)
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        state.surfaceDidAppear()
        XCTAssertTrue(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        XCTAssertTrue(state.parentResponded(accepted: true))
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
    }

    func testSameReadySurfaceReplaysParentHandoffOncePerAppearance() {
        let player = NSObject()
        let identity = ObjectIdentifier(player)
        var state = VideoSurfaceFirstFrameHandoffState()
        state.layerBecameReady(playerIdentity: identity, currentPlayerIdentity: identity)
        state.setPresentationActive(true)
        state.surfaceDidAppear()
        XCTAssertTrue(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        XCTAssertTrue(state.parentResponded(accepted: true))
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))

        state.setPresentationActive(false)
        state.setPresentationActive(true)
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))

        state.surfaceDidDisappear()
        state.setPresentationActive(true)
        state.surfaceDidAppear()
        XCTAssertTrue(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        XCTAssertTrue(state.parentResponded(accepted: true))
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
    }

    func testRejectedParentHandoffKeepsFirstFrameAdmissionAndEndRetryOwnedByPlayer() {
        let player = NSObject()
        let identity = ObjectIdentifier(player)
        var handoff = VideoSurfaceFirstFrameHandoffState()
        var deadline = VideoFirstFrameDeadlineState()
        handoff.layerBecameReady(playerIdentity: identity, currentPlayerIdentity: identity)
        handoff.setPresentationActive(true)
        handoff.surfaceDidAppear()
        XCTAssertTrue(deadline.arm())

        XCTAssertFalse(handoff.parentResponded(accepted: false))
        XCTAssertTrue(handoff.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        XCTAssertTrue(deadline.armed)

        XCTAssertTrue(deadline.deferEndUntilFrame())
        XCTAssertTrue(handoff.parentResponded(accepted: true))
        XCTAssertTrue(deadline.admit())
        XCTAssertTrue(deadline.consumePendingEnd())
        XCTAssertFalse(handoff.shouldAttemptParentHandoff(currentPlayerIdentity: identity))
        XCTAssertFalse(handoff.parentResponded(accepted: true))
        XCTAssertFalse(deadline.admit())
    }

    func testStaleLayerReadinessCannotTransferToReplacementSurface() {
        let player = NSObject()
        let replacement = NSObject()
        let playerID = ObjectIdentifier(player)
        let replacementID = ObjectIdentifier(replacement)
        var state = VideoSurfaceFirstFrameHandoffState()
        state.layerBecameReady(playerIdentity: playerID, currentPlayerIdentity: playerID)
        state.setPresentationActive(true)
        state.surfaceDidAppear()

        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: replacementID))
        state.layerBecameReady(playerIdentity: playerID, currentPlayerIdentity: replacementID)
        XCTAssertFalse(state.shouldAttemptParentHandoff(currentPlayerIdentity: replacementID))
        state.layerBecameReady(playerIdentity: replacementID, currentPlayerIdentity: replacementID)
        XCTAssertTrue(state.shouldAttemptParentHandoff(currentPlayerIdentity: replacementID))
    }

    func testRecreatedVideoSurfaceStaysHiddenUntilItsOwnLayerIsReady() {
        let player = NSObject()
        let playerID = ObjectIdentifier(player)
        XCTAssertFalse(videoSurfaceShowsFirstFrame(
            localPlayerIdentity: nil,
            currentPlayerIdentity: playerID
        ))
    }

    func testRecreatedVideoSurfaceShowsAfterItsOwnLayerReadiness() {
        let player = NSObject()
        let replacement = NSObject()
        XCTAssertTrue(videoSurfaceShowsFirstFrame(
            localPlayerIdentity: ObjectIdentifier(player),
            currentPlayerIdentity: ObjectIdentifier(player)
        ))
        XCTAssertFalse(videoSurfaceShowsFirstFrame(
            localPlayerIdentity: ObjectIdentifier(player),
            currentPlayerIdentity: ObjectIdentifier(replacement)
        ))
    }

    func testV2FallbackPreparationGateWaitsOnlyForV2VideoPrimary() {
        XCTAssertTrue(allowsV2FallbackPreparation(
            primaryUsesVideoPlanV2: false,
            primaryV2VideoStarted: false
        ))
        XCTAssertFalse(allowsV2FallbackPreparation(
            primaryUsesVideoPlanV2: true,
            primaryV2VideoStarted: false
        ))
        XCTAssertTrue(allowsV2FallbackPreparation(
            primaryUsesVideoPlanV2: true,
            primaryV2VideoStarted: true
        ))
    }

    func testV2FallbackPreparationKeepsOriginalIndexPastPlayable() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"playable","rendered_html":"HTML"},{"type":"video","url":"https://cdn.example/one.mp4","clip_index":1}]}"#
        )

        XCTAssertEqual(upcomingFallbackVideoIndices(ads), [1])
        XCTAssertEqual(upcomingFallbackVideoIndices(ads, allowV2Preparation: false), [1])
    }

    func testV2FallbackPreparationSelectsOnlyNextVideoAcrossPlayable() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"video","url":"https://cdn.example/one.mp4","clip_index":0},{"type":"playable","rendered_html":"HTML"},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":1}]}"#
        )

        XCTAssertEqual(upcomingFallbackVideoIndices(ads), [0])
        XCTAssertNil(nextV2FallbackVideoIndex(in: ads, after: 0))
        XCTAssertNil(nextV2FallbackVideoIndex(in: ads, after: 2))
    }

    func testVideoV1FallbackPreparationIndicesKeepCurrentAndNextBehavior() throws {
        let ads = try decodeFallbacks(
            #"{"ads":[{"type":"video","url":"https://cdn.example/one.mp4"},{"type":"video","url":"https://cdn.example/two.mp4"},{"type":"video","url":"https://cdn.example/three.mp4"}]}"#
        )

        XCTAssertEqual(upcomingFallbackVideoIndices(ads), [0, 1])
    }

    func testV2PreparationAtCompactIndexTwoSurvivesFromFirstScreen() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"playable","rendered_html":"A"},{"type":"playable","rendered_html":"B"},{"type":"video","url":"https://cdn.example/one.mp4","clip_index":2}]}"#
        )

        XCTAssertEqual(upcomingFallbackVideoIndices(ads), [])
        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 0,
            preparedIndices: [2]
        ), [2])
    }

    func testNextV2PreparationSurvivesTraversalAcrossMultiplePlayables() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"video","url":"https://cdn.example/one.mp4","clip_index":0},{"type":"playable","rendered_html":"A"},{"type":"playable","rendered_html":"B"},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":1}]}"#
        )

        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 1,
            preparedIndices: [3]
        ), [3])
        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 2,
            preparedIndices: [3]
        ), [])
    }

    func testNextV2PreparationSurvivesOnePlayableGap() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"video","url":"https://cdn.example/one.mp4","clip_index":0},{"type":"playable","rendered_html":"A"},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":2}]}"#
        )

        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 1,
            preparedIndices: [2]
        ), [])
    }

    func testVideoV1PreparationDiscardPolicyKeepsAdjacencyPruning() throws {
        let ads = try decodeFallbacks(
            #"{"ads":[{"type":"video","url":"https://cdn.example/one.mp4"},{"type":"video","url":"https://cdn.example/two.mp4"},{"type":"video","url":"https://cdn.example/three.mp4"}]}"#
        )

        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 0,
            preparedIndices: [0, 1, 2]
        ), [2])
        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 1,
            preparedIndices: [0, 1, 2]
        ), [0])
    }

    func testV2PreparationRetentionUsesCompactIndexNotRawSourceIndex() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"video","url":"bad"},{"type":"playable","rendered_html":"A"},{"type":"video","url":"https://cdn.example/one.mp4","clip_index":2}]}"#
        )
        XCTAssertEqual(ads.map(\.sourceIndex), [1, 2])
        XCTAssertEqual(upcomingFallbackVideoIndices(ads), [1])

        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 0,
            preparedIndices: [1]
        ), [])
    }

    func testV2PreparationRetentionKeepsOnlyOneUpcomingToken() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"playable","rendered_html":"A"},{"type":"video","url":"https://cdn.example/one.mp4","clip_index":1},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":2}]}"#
        )

        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 0,
            preparedIndices: [1, 2]
        ), [2])
        XCTAssertEqual(discardedFallbackVideoPreparationIndices(
            in: ads,
            around: 2,
            preparedIndices: [1, 2]
        ), [1])
    }

    func testMiniGameV2PreparationFindsLeadingPlayablePlayableVideo() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"playable","rendered_html":"A"},{"type":"playable","rendered_html":"B"},{"type":"video","url":"https://cdn.example/one.mp4","clip_index":2}]}"#
        )

        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 0,
            preparedIndices: []
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [], discardIndices: []))
    }

    func testMiniGameV2PreparationTraversesGapsAndRecoversMissingToken() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"video","url":"https://cdn.example/one.mp4","clip_index":0},{"type":"playable","rendered_html":"A"},{"type":"playable","rendered_html":"B"},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":1}]}"#
        )

        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 1,
            preparedIndices: []
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [], discardIndices: []))
        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 2,
            preparedIndices: [3]
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [], discardIndices: [3]))
    }

    func testMiniGameV2PreparationDoesNotDuplicateAndStaysBounded() throws {
        let ads = try decodeFallbacks(
            #"{"video_plan_version":"video_plan_v2","ads":[{"type":"playable","rendered_html":"A"},{"type":"video","url":"https://cdn.example/one.mp4","clip_index":1},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":2}]}"#
        )

        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 0,
            preparedIndices: [1]
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [], discardIndices: []))
        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 0,
            preparedIndices: [1, 2]
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [], discardIndices: [2]))
    }

    func testMiniGameV1PreparationPreservesCurrentAndNextParity() throws {
        let ads = try decodeFallbacks(
            #"{"ads":[{"type":"video","url":"https://cdn.example/one.mp4"},{"type":"video","url":"https://cdn.example/two.mp4"},{"type":"video","url":"https://cdn.example/three.mp4"}]}"#
        )

        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 0,
            preparedIndices: []
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [0, 1], discardIndices: []))
        XCTAssertEqual(miniGameFallbackVideoPreparationPlan(
            ads: ads,
            around: 1,
            preparedIndices: [0, 1, 2]
        ), MiniGameFallbackVideoPreparationPlan(prepareIndices: [], discardIndices: [0, 2]))
    }

    func testFallbackPreparedTokenRetentionKeepsOnlyCurrentAndImmediateNext() throws {
        let ads = try decodeFallbacks(
            #"{"ads":[{"type":"video","url":"https://cdn.example/one.mp4"},{"type":"video","url":"https://cdn.example/two.mp4"},{"type":"video","url":"https://cdn.example/three.mp4"}]}"#
        )

        XCTAssertEqual(ads.count, 2)
        XCTAssertEqual(
            boundedFallbackVideoPreparationIndices(
                in: ads,
                around: 0,
                preparedIndices: [0, 1, 2, 9]
            ),
            [0, 1]
        )
        XCTAssertEqual(
            boundedFallbackVideoPreparationIndices(
                in: ads,
                around: 1,
                preparedIndices: [0, 1]
            ),
            [1]
        )
    }

    #if os(iOS)
    @MainActor
    func testInterstitialReadyLeaseOutlivesPoolExpiryAndDeletesAfterPresentationDetach() throws {
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: localURL.path, contents: Data([1])))
        let leaseReleased = LockedVideoLeaseObservation()
        let lease = VideoAssetLease(localURL: localURL) {
            leaseReleased.record()
            try? FileManager.default.removeItem(at: localURL)
        }
        var now: TimeInterval = 0
        let pool = FullscreenVideoPreparationPool(capacity: 2, retention: 300, now: { now })
        let token = try XCTUnwrap(pool.prepare(url: localURL, posterURL: nil, assetLease: lease))
        now = 301
        let replacement = try XCTUnwrap(pool.prepare(
            url: URL(fileURLWithPath: "/dev/null/replacement"),
            posterURL: nil
        ))

        XCTAssertNil(pool.localURL(for: token), "the five-minute preparation entry expires")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertFalse(leaseReleased.wasReleased, "the ready ad independently retains the asset")

        let coldPlayer = FullscreenVideoPlayer(url: lease.localURL, posterURL: nil)
        XCTAssertNotNil(coldPlayer.player.currentItem, "show can cold-start from the ready lease")
        coldPlayer.stop()
        XCTAssertNil(coldPlayer.player.currentItem)
        lease.release()

        XCTAssertTrue(leaseReleased.wasReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        pool.release(replacement)
    }

    @MainActor
    func testRewardedReadyLeaseOutlivesPoolCapEvictionAndSupersedeReleasesOnce() throws {
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: localURL.path, contents: Data([1])))
        let releaseObservation = LockedVideoLeaseObservation()
        let lease = VideoAssetLease(localURL: localURL) {
            releaseObservation.record()
            try? FileManager.default.removeItem(at: localURL)
        }
        let pool = FullscreenVideoPreparationPool(capacity: 1)
        let token = try XCTUnwrap(pool.prepare(
            url: localURL,
            posterURL: nil,
            assetLease: lease
        ))
        let replacement = try XCTUnwrap(pool.prepare(
            url: URL(fileURLWithPath: "/dev/null/rewarded-replacement"),
            posterURL: nil
        ))

        XCTAssertNil(pool.localURL(for: token), "the preparation cap evicts the old idle player")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertFalse(releaseObservation.wasReleased)

        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertTrue(releaseObservation.wasReleased)
        lease.release()
        XCTAssertEqual(releaseObservation.releaseCount, 1, "supersede/stale cleanup is idempotent")
        pool.release(replacement)
    }

    @MainActor
    func testInterstitialFailedPresentationRetryKeepsBothReadyAndPoolOwners() throws {
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: localURL.path, contents: Data([1])))
        let releaseObservation = LockedVideoLeaseObservation()
        let readyLease = VideoAssetLease(localURL: localURL) {
            releaseObservation.record()
            try? FileManager.default.removeItem(at: localURL)
        }
        let pool = FullscreenVideoPreparationPool(capacity: 1)
        let token = try XCTUnwrap(pool.prepare(url: localURL, posterURL: nil, assetLease: readyLease))
        let firstAttempt = try XCTUnwrap(pool.claim(token, url: localURL, posterURL: nil))

        pool.returnToPrepared(token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        let retry = try XCTUnwrap(pool.claim(token, url: localURL, posterURL: nil))
        XCTAssertTrue(firstAttempt === retry)

        pool.release(token)
        XCTAssertNil(retry.player.currentItem, "pool release detaches the claimed player first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        readyLease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(releaseObservation.releaseCount, 1)
    }

    @MainActor
    func testRewardedCloseWaitsForPoolAndPresentationLeaseWithoutDoubleDelete() throws {
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: localURL.path, contents: Data([1])))
        let releaseObservation = LockedVideoLeaseObservation()
        let presentationLease = VideoAssetLease(localURL: localURL) {
            releaseObservation.record()
            try? FileManager.default.removeItem(at: localURL)
        }
        let pool = FullscreenVideoPreparationPool(capacity: 1)
        let token = try XCTUnwrap(pool.prepare(
            url: localURL,
            posterURL: nil,
            assetLease: presentationLease
        ))
        let player = try XCTUnwrap(pool.claim(token, url: localURL, posterURL: nil))

        presentationLease.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        pool.release(token)

        XCTAssertNil(player.player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        presentationLease.release()
        pool.release(token)
        XCTAssertEqual(releaseObservation.releaseCount, 1)
    }

    @MainActor
    func testContractTwoPreparesES1VideoAndRejectsES2Video() throws {
        let ads = try decodeFallbacks(
            #"{"video_contract":2,"ads":[{"type":"video","url":"https://cdn.example/one.mp4","clip_index":1},{"type":"video","url":"https://cdn.example/two.mp4","clip_index":2}]}"#
        )
        var attempts = 0

        let beforeFirstFrame = prepareUpcomingFallbackVideos(
            ads,
            allowV2Preparation: false
        ) { _, _ in
            attempts += 1
            return FullscreenVideoPreparationToken()
        }
        XCTAssertTrue(beforeFirstFrame.isEmpty)
        XCTAssertEqual(attempts, 0)

        let prepared = prepareUpcomingFallbackVideos(ads) { _, _ in
            attempts += 1
            return FullscreenVideoPreparationToken()
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(prepared.keys.sorted(), [0])
    }

    @MainActor
    func testVideoV1FallbackPreparationKeepsCurrentAndNextGoldenBehavior() throws {
        let ads = try decodeFallbacks(
            #"{"ads":[{"type":"video","url":"https://cdn.example/one.mp4"},{"type":"video","url":"https://cdn.example/two.mp4"}]}"#
        )
        var attempts = 0
        let prepared = prepareUpcomingFallbackVideos(ads) { _, _ in
            attempts += 1
            return FullscreenVideoPreparationToken()
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(prepared.keys.sorted(), [0, 1])
    }

    @MainActor
    func testPlayerExposesAdmittedFirstFrameForSurfaceRecreation() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        XCTAssertFalse(player.hasAdmittedFirstVisualFrame)
        XCTAssertTrue(player.admitFirstVisualFrame())
        XCTAssertTrue(player.hasAdmittedFirstVisualFrame)
        XCTAssertFalse(player.admitFirstVisualFrame())
        player.stop()
    }

    @MainActor
    func testNeverReadyLayerTimesOutOnlyWhilePresentationIsActive() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        let view = VideoLayerView(frame: .zero)
        var timeouts = 0
        view.install(
            player: player.player,
            presentationActive: false,
            onFirstFrame: {},
            onReadinessTimeout: { timeouts += 1 }
        )
        view.fireCurrentReadinessDeadline()
        XCTAssertEqual(timeouts, 0)

        view.install(
            player: player.player,
            presentationActive: true,
            onFirstFrame: {},
            onReadinessTimeout: { timeouts += 1 }
        )
        view.fireCurrentReadinessDeadline()
        view.fireCurrentReadinessDeadline()
        XCTAssertEqual(timeouts, 1)
        view.uninstall()
        player.stop()
    }
    #endif
}

private final class LockedVideoLeaseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0

    var wasReleased: Bool {
        lock.lock(); defer { lock.unlock() }
        return releases > 0
    }

    var releaseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return releases
    }

    func record() {
        lock.lock(); releases += 1; lock.unlock()
    }
}
