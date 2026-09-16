import XCTest
@testable import SimulaAdSDK

final class CreativeVideoTests: XCTestCase {
    private func decodeInterstitial(_ json: String) throws -> AdLoadResponse {
        try JSONDecoder().decode(AdLoadResponse.self, from: Data(json.utf8))
    }

    private func decodeRewarded(_ json: String) throws -> RewardedInitResponse {
        try JSONDecoder().decode(RewardedInitResponse.self, from: Data(json.utf8))
    }

    private func decodeFallbacks(_ json: String) throws -> [FallbackAd] {
        try JSONDecoder().decode(FallbackAdsAPIResponse.self, from: Data(json.utf8)).resolvedAds
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

    func testCapabilitiesEncodeVideoV1ForFullscreenRequests() throws {
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
        XCTAssertEqual((object["capabilities"] as? [String: Any])?["video_v1"] as? Bool, true)
        XCTAssertEqual(capabilities.dictionary["video_v1"] as? Bool, true)
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

    func testVideoConfiguredGateUsesDurationElapsedReason() {
        var gate = VideoPlaybackGate(configuredDelay: 5)
        gate.update(duration: 20, played: 5)

        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.earnedCompletionReason, .durationElapsed)
    }

    func testInterstitialFirstFrameSnapshotUnlocksZeroDelayImmediately() {
        var gate = VideoPlaybackGate(configuredDelay: 0)

        gate.update(duration: 20, played: 0)

        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(gate.progress, 1)
        XCTAssertEqual(gate.secondsRemaining, 0)
    }

    func testInterstitialFirstFrameSnapshotPreservesKnownPositiveGateProgress() {
        var gate = VideoPlaybackGate(configuredDelay: 5)

        gate.update(duration: 20, played: 2)

        XCTAssertFalse(gate.isUnlocked)
        XCTAssertEqual(gate.progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(gate.secondsRemaining, 3)
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
            viewAppeared: false,
            visible: true,
            failureHandled: false,
            primaryCreativeReady: false,
            callbackPlayerIdentity: playerID,
            currentPlayerIdentity: playerID
        ))
        XCTAssertFalse(shouldAcceptFullscreenVideoFirstFrameCallback(
            viewAppeared: true,
            visible: true,
            failureHandled: false,
            primaryCreativeReady: false,
            callbackPlayerIdentity: playerID,
            currentPlayerIdentity: ObjectIdentifier(replacement)
        ))
        XCTAssertTrue(shouldAcceptFullscreenVideoFirstFrameCallback(
            viewAppeared: true,
            visible: true,
            failureHandled: false,
            primaryCreativeReady: false,
            callbackPlayerIdentity: playerID,
            currentPlayerIdentity: playerID
        ))
    }

    func testRecreatedVideoSurfaceShowsAlreadyAdmittedPlayerFrame() {
        let player = NSObject()
        let replacement = NSObject()
        XCTAssertFalse(videoSurfaceShowsFirstFrame(
            localPlayerIdentity: nil,
            currentPlayerIdentity: ObjectIdentifier(player),
            playerFirstFrameAdmitted: false
        ))
        XCTAssertTrue(videoSurfaceShowsFirstFrame(
            localPlayerIdentity: nil,
            currentPlayerIdentity: ObjectIdentifier(player),
            playerFirstFrameAdmitted: true
        ))
        XCTAssertFalse(videoSurfaceShowsFirstFrame(
            localPlayerIdentity: ObjectIdentifier(player),
            currentPlayerIdentity: ObjectIdentifier(replacement),
            playerFirstFrameAdmitted: false
        ))
    }

    #if os(iOS)
    @MainActor
    func testPlayerExposesAdmittedFirstFrameForSurfaceRecreation() {
        let player = FullscreenVideoPlayer(url: URL(fileURLWithPath: "/dev/null"), posterURL: nil)
        XCTAssertFalse(player.hasAdmittedFirstVisualFrame)
        XCTAssertTrue(player.admitFirstVisualFrame())
        XCTAssertTrue(player.hasAdmittedFirstVisualFrame)
        XCTAssertFalse(player.admitFirstVisualFrame())
        player.stop()
    }
    #endif
}
