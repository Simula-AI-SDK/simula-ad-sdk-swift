import Foundation
import XCTest
@testable import SimulaAdSDK

final class VideoContractTests: XCTestCase {
    private func decodeInterstitial(_ json: String) throws -> AdLoadResponse {
        try decodeFullscreenPayload(AdLoadResponse.self, from: Data(json.utf8))
    }

    private func decodeRewarded(_ json: String) throws -> RewardedInitResponse {
        try decodeFullscreenPayload(RewardedInitResponse.self, from: Data(json.utf8))
    }

    func testOnlyExactNumericRootActivatesContractTwo() throws {
        let active = try decodeInterstitial(
            #"{"ad_inserted":true,"video_contract":2,"creative":{"type":"video","url":"https://cdn.example/a.mp4"}}"#
        )
        let old = try decodeInterstitial(
            #"{"ad_inserted":true,"video_plan_version":"video_plan_v2","creative":{"type":"video","url":"https://cdn.example/a.mp4"}}"#
        )
        let rejected = try ["2.0", "2e0", "true", "\"2\""].map { marker in
            try decodeInterstitial(
                "{\"ad_inserted\":true,\"video_contract\":\(marker)," +
                    "\"creative\":{\"type\":\"video\",\"url\":\"https://cdn.example/a.mp4\"}}"
            )
        }

        XCTAssertTrue(active.usesVideoPlanV2Contract)
        XCTAssertTrue(active.primaryUsesVideoPlanV2)
        XCTAssertFalse(old.usesVideoPlanV2Contract)
        XCTAssertTrue(rejected.allSatisfy { !$0.usesVideoPlanV2Contract })
    }

    func testBothFullscreenRequestsAdvertiseContractAtTopLevel() throws {
        for data in [
            try JSONEncoder().encode(AdLoadRequest(adUnitId: "i")),
            try JSONEncoder().encode(RewardedInitRequest(adUnitId: "r")),
        ] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["contracts"] as? [String: Any])?["video"] as? Int, 2)
            let capabilities = try XCTUnwrap(object["capabilities"] as? [String: Any])
            XCTAssertNil(capabilities["video_v1"])
            XCTAssertNil(capabilities["video_plan_v2"])
        }
    }

    func testSegmentsDecodeAndValidateAsOneStitchedTimeline() throws {
        let response = try decodeInterstitial(#"""
        {"ad_inserted":true,"video_contract":2,"creative":{
          "type":"video","url":"https://cdn.example/a.mp4","segments":[
            {"clip_index":0,"video_pool":"ugc","start_seconds":0,"end_seconds":2.5},
            {"clip_index":1,"video_pool":"gameplay","start_seconds":2.5,"end_seconds":8}
          ]}}
        """#)
        let segments = try XCTUnwrap(response.creative).segments

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(activeVideoSegment(in: segments, at: 0)?.clipIndex, 0)
        XCTAssertEqual(activeVideoSegment(in: segments, at: 2.5)?.videoPool, "gameplay")
        XCTAssertEqual(activeVideoSegment(in: segments, at: 8)?.clipIndex, 1)
        XCTAssertEqual(activeVideoSegment(in: segments, at: 80)?.clipIndex, 1)
    }

    func testSegmentClipIndexRequiresLexicalJSONIntegerWithoutDroppingVideo() throws {
        for token in ["0.0", "0e0", "\"0\"", "true"] {
            let response = try decodeInterstitial(
                "{\"ad_inserted\":true,\"video_contract\":2,\"creative\":{" +
                    "\"type\":\"video\",\"url\":\"https://cdn.example/a.mp4\"," +
                    "\"segments\":[{\"clip_index\":\(token),\"video_pool\":\"ugc\"," +
                    "\"start_seconds\":0,\"end_seconds\":1}]}}"
            )
            XCTAssertNotNil(response.creativeContent, token)
            XCTAssertEqual(response.creative?.segments, [], token)
        }
    }

    func testSegmentsAllowOneMillisecondBoundaryDrift() throws {
        let response = try decodeInterstitial(#"""
        {"ad_inserted":true,"video_contract":2,"creative":{
          "type":"video","url":"https://cdn.example/a.mp4","segments":[
            {"clip_index":0,"video_pool":"ugc","start_seconds":0.0009,"end_seconds":2.5},
            {"clip_index":1,"video_pool":"gameplay","start_seconds":2.5009,"end_seconds":8}
          ]}}
        """#)
        XCTAssertEqual(response.creative?.segments.map(\.startSeconds), [0, 2.5])

        let oversizedPool = String(repeating: "x", count: 65)
        let invalid = try decodeInterstitial(
            "{\"ad_inserted\":true,\"creative\":{\"type\":\"video\"," +
                "\"url\":\"https://cdn.example/a.mp4\",\"segments\":[{" +
                "\"clip_index\":0,\"video_pool\":\"\(oversizedPool)\"," +
                "\"start_seconds\":0,\"end_seconds\":1}]}}"
        )
        XCTAssertEqual(invalid.creative?.segments, [])

        let reversedWithinTolerance = try decodeInterstitial(#"""
        {"ad_inserted":true,"video_contract":2,"creative":{
          "type":"video","url":"https://cdn.example/a.mp4","segments":[
            {"clip_index":0,"video_pool":"ugc","start_seconds":0,"end_seconds":2.5},
            {"clip_index":1,"video_pool":"gameplay","start_seconds":2.5009,"end_seconds":2.5005}
          ]}}
        """#)
        XCTAssertEqual(reversedWithinTolerance.creative?.segments, [])
    }

    func testAnyMalformedSegmentInvalidatesInterleavedAndTrailingListsWithoutDroppingVideo() throws {
        let segmentLists = [
            #"[{"clip_index":0,"video_pool":"a","start_seconds":0,"end_seconds":1},false,{"clip_index":1,"video_pool":"b","start_seconds":1,"end_seconds":2}]"#,
            #"[{"clip_index":0,"video_pool":"a","start_seconds":0,"end_seconds":1},{"clip_index":1,"video_pool":"b","start_seconds":1,"end_seconds":2},{"clip_index":"2","video_pool":"c","start_seconds":2,"end_seconds":3}]"#,
            #"[{"clip_index":0,"video_pool":"a","start_seconds":0,"end_seconds":1},{"clip_index":1,"video_pool":"b","start_seconds":1,"end_seconds":2},null]"#,
        ]

        for segments in segmentLists {
            let response = try decodeInterstitial(
                "{\"ad_inserted\":true,\"video_contract\":2,\"creative\":{" +
                    "\"type\":\"video\",\"url\":\"https://cdn.example/a.mp4\"," +
                    "\"segments\":\(segments)}}"
            )
            XCTAssertNotNil(response.creativeContent, segments)
            XCTAssertEqual(response.creative?.segments, [], segments)
        }
    }

    func testMalformedNonFiniteUnsortedAndGappedSegmentsFailClosedWithoutDroppingCreative() throws {
        let payloads = [
            #"[{"clip_index":0,"video_pool":"a","start_seconds":1,"end_seconds":2}]"#,
            #"[{"clip_index":1,"video_pool":"a","start_seconds":0,"end_seconds":2}]"#,
            #"[{"clip_index":0,"video_pool":"a","start_seconds":0,"end_seconds":2},{"clip_index":1,"video_pool":"b","start_seconds":3,"end_seconds":4}]"#,
            #"[{"clip_index":0,"video_pool":"a","start_seconds":0,"end_seconds":"bad"}]"#,
        ]
        for segments in payloads {
            let response = try decodeInterstitial(
                "{\"ad_inserted\":true,\"video_contract\":2,\"creative\":{" +
                    "\"type\":\"video\",\"url\":\"https://cdn.example/a.mp4\"," +
                    "\"segments\":\(segments)}}"
            )
            XCTAssertNotNil(response.creativeContent)
            XCTAssertEqual(response.creative?.segments, [])
        }
    }

    func testUnitEndRewardProgressStyleImpressionAndOverlayDecode() throws {
        let response = try decodeInterstitial(#"""
        {"ad_inserted":true,"video_contract":2,"impression_url":"https://measure.example/pixel",
         "rendered_html":"HTML","ad_behavior":{
           "reward":{"earn_at":"unit_end"},"progress_bar":{"style":"two_tone"},
           "skoverlay":{"delay_seconds":999}}}
        """#)

        XCTAssertEqual(response.adBehavior?.reward.earnAt, .unitEnd)
        XCTAssertEqual(response.adBehavior?.progressBar.style, .twoTone)
        XCTAssertEqual(response.adBehavior?.skoverlay?.delaySeconds, 3)
        XCTAssertEqual(response.validatedImpressionURL?.host, "measure.example")
    }

    func testContractTwoOverlayDelayRequiresExactBoundedInteger() throws {
        for token in ["-1", "61", "2.0", "2e0", "true", "\"2\""] {
            let response = try decodeInterstitial(
                "{\"ad_inserted\":true,\"video_contract\":2,\"ad_behavior\":{" +
                    "\"skoverlay\":{\"delay_seconds\":\(token)}}}"
            )
            XCTAssertEqual(response.adBehavior?.skoverlay?.delaySeconds, 3, token)
        }
        for value in [0, 3, 60] {
            let response = try decodeInterstitial(
                "{\"ad_inserted\":true,\"video_contract\":2,\"ad_behavior\":{" +
                    "\"skoverlay\":{\"delay_seconds\":\(value)}}}"
            )
            XCTAssertEqual(response.adBehavior?.skoverlay?.delaySeconds, value)
        }
    }

    func testLegacyOverlayDelayKeepsLegacyClamp() throws {
        let response = try decodeInterstitial(
            #"{"ad_inserted":true,"ad_behavior":{"skoverlay":{"delay_seconds":999}}}"#
        )
        XCTAssertEqual(response.adBehavior?.skoverlay?.delaySeconds, 300)
        XCTAssertEqual(SKOverlayConfig(enabled: true, delaySeconds: -1).delaySeconds, 0)
        XCTAssertEqual(SKOverlayConfig(enabled: true, delaySeconds: 300).delaySeconds, 300)
        XCTAssertEqual(SKOverlayConfig(enabled: true, delaySeconds: 999).delaySeconds, 300)
    }

    func testClickIdentityIsReusedOrMintedWithSemanticFallback() {
        let supplied = resolvedClickInteraction(
            identity: HTMLClickIdentity(
                interactionId: "00000000-0000-4000-8000-000000000001",
                clickSource: "html_cta"
            ),
            fallbackSource: .primaryUnknown,
            makeID: { "minted" }
        )
        let invalid = resolvedClickInteraction(
            identity: HTMLClickIdentity(interactionId: String(repeating: "x", count: 65), clickSource: "bad source"),
            fallbackSource: .endScreen2Unknown,
            makeID: { "minted" }
        )

        XCTAssertEqual(supplied.id, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(supplied.source, .primaryUnknown)
        XCTAssertEqual(invalid.id, "minted")
        XCTAssertEqual(invalid.source, .endScreen2Unknown)
    }

    func testClickSourceGoldenListExactlyMatchesBackendAndPreservesValidHTMLID() {
        let id = "00000000-0000-4000-8000-000000000001"
        let backendGolden = [
            "auto_redirect", "companion", "cta", "end_screen",
            "end_screen_ad_1_backdrop", "end_screen_ad_1_cta",
            "end_screen_ad_2_backdrop", "end_screen_ad_2_cta",
            "end_screen_ad_2_interested_button", "fallback_cta", "install_banner",
            "interstitial", "native", "native_backdrop", "native_cta", "playable",
            "primary_cta", "primary_unknown", "rewarded", "sdk", "store_prompt",
            "video_preview_cta", "end_screen_1_unknown", "end_screen_2_unknown",
        ]
        XCTAssertEqual(ClickSource.contract2AllowedSources.map(\.rawValue).sorted(), backendGolden.sorted())
        for rawSource in backendGolden {
            let source = ClickSource(rawValue: rawSource)
            XCTAssertEqual(
                resolvedClickInteraction(
                    identity: HTMLClickIdentity(interactionId: id, clickSource: source.rawValue),
                    fallbackSource: .endScreen1Unknown
                ),
                ClickInteraction(id: id, source: source)
            )
        }
        for source in [nil, "html_cta", "future_source", "bad source"] {
            let interaction = resolvedClickInteraction(
                identity: HTMLClickIdentity(interactionId: id, clickSource: source),
                fallbackSource: .endScreen1Unknown
            )
            XCTAssertEqual(interaction.id, id)
            XCTAssertEqual(interaction.source, .endScreen1Unknown)
        }
    }

    func testClickIdentityAcceptsRFC4122VersionsOneThroughFiveAndRejectsOtherVariants() {
        for version in 1...5 {
            let value = "00000000-0000-\(version)000-8000-000000000001"
            XCTAssertEqual(validatedRFC4122ClickID(value), value)
        }
        for value in [
            "00000000-0000-0000-8000-000000000001",
            "00000000-0000-6000-8000-000000000001",
            "00000000-0000-4000-7000-000000000001",
            "{00000000-0000-4000-8000-000000000001}",
        ] {
            XCTAssertNil(validatedRFC4122ClickID(value), value)
        }

        let native = resolvedClickInteraction(identity: nil, fallbackSource: .primaryCTA)
        XCTAssertEqual(Array(native.id.utf8)[14], 52)
        XCTAssertTrue(["8", "9", "A", "B"].contains(String(native.id[native.id.index(native.id.startIndex, offsetBy: 19)]).uppercased()))
    }

    func testAuthenticatedCTAEnvelopeCarriesIdentity() {
        let body = #"{"type":"SIMULA_CTA_OPEN","activation_nonce":"nonce","url":"https://example.com","interaction_id":"id-1","click_source":"html_cta"}"#
        guard case .accepted(_, let identity) = CreativeCTAOpenMessage.authenticate(
            body,
            expectedNonce: "nonce"
        ) else { return XCTFail("Expected authenticated CTA") }
        XCTAssertEqual(identity?.interactionId, "id-1")
        XCTAssertEqual(identity?.clickSource, "html_cta")
    }

    func testUnitEndClaimAndMidpointTelemetryAreExactlyOnce() {
        var reward = UnitEndRewardState()
        XCTAssertFalse(reward.primaryGateDidOpen())
        XCTAssertTrue(reward.fallbackDidResolve(renderableScreenCount: 0))
        XCTAssertFalse(reward.fallbackDidResolve(renderableScreenCount: 0))

        var quartiles = VideoQuartileState()
        XCTAssertEqual(quartiles.crossed(position: 4.9, duration: 10), [])
        XCTAssertEqual(quartiles.crossed(position: 8, duration: 10), [50])
        XCTAssertEqual(quartiles.crossed(position: 10, duration: 10), [])
    }

    func testUnitEndUnavailableUsesPrimaryWhenNoFallbackRendered() {
        var destroyedBeforeAuthority = UnitEndRewardState()
        XCTAssertFalse(destroyedBeforeAuthority.primaryGateDidOpen())
        XCTAssertTrue(destroyedBeforeAuthority.fallbackBecameUnavailable())
        XCTAssertTrue(destroyedBeforeAuthority.earned)

        var fetchFailedBeforeGate = UnitEndRewardState()
        XCTAssertFalse(fetchFailedBeforeGate.fallbackBecameUnavailable())
        XCTAssertTrue(fetchFailedBeforeGate.primaryGateDidOpen())
        XCTAssertFalse(fetchFailedBeforeGate.fallbackBecameUnavailable())

        var fallbackRemains = UnitEndRewardState()
        XCTAssertFalse(fallbackRemains.primaryGateDidOpen())
        XCTAssertFalse(fallbackRemains.fallbackDidResolve(renderableScreenCount: 2))
        XCTAssertFalse(fallbackRemains.fallbackGateDidOpen(isFinal: false))
        XCTAssertTrue(fallbackRemains.fallbackBecameUnavailable())
        XCTAssertFalse(fallbackRemains.fallbackDeliveryDidFinish())
    }

    @MainActor
    func testUnitEndGateDefersDelegateAndQueueUntilWholeUnitClose() {
        var events: [String] = []
        let claim = UnitEndRewardClaim()
        claim.primaryGateDidOpen()
        claim.fallbackDidResolve(renderableScreenCount: 2)
        claim.fallbackGateDidOpen(isFinal: true)

        XCTAssertTrue(claim.earned)
        XCTAssertTrue(events.isEmpty, "the authoritative gate is internal only")

        events.append("close")
        XCTAssertTrue(claim.consumeAtUnitClose(
            onEarn: { events.append("earned") },
            enqueueVerification: { events.append("queue") }
        ))
        XCTAssertEqual(events, ["close", "earned", "queue"])
    }

    @MainActor
    func testAuthoritativeRewardIsDeliveredOnceEvenWithoutVerificationInputs() throws {
        final class Delegate: SimulaRewardedAdDelegate {
            var events: [String] = []
            func rewardedDidEarnReward(_ ad: SimulaRewardedAd) { events.append("earned") }
            func rewardedRewardVerificationDidFail(_ ad: SimulaRewardedAd, error: Error) {
                events.append("verification_failed")
            }
        }
        for elapsed in [5.0, Double.nan] {
            let ad = SimulaRewardedAd(adUnitId: "unit")
            let delegate = Delegate()
            ad.delegate = delegate
            let response = try decodeRewarded(#"{"impression_id":"serve","video_contract":2}"#)
            let claim = UnitEndRewardClaim()
            claim.primaryGateDidOpen()
            claim.fallbackDidResolve(renderableScreenCount: 0)
            ad.handleUnitEndClose(response: response, claim: claim, elapsedPlayTime: elapsed)
            ad.handleUnitEndClose(response: response, claim: claim, elapsedPlayTime: elapsed)
            XCTAssertEqual(delegate.events, ["earned", "verification_failed"])
        }
    }

    @MainActor
    func testUnitEndDuplicateCloseDoesNotDuplicateDelegateOrQueue() {
        var earned = 0
        var queued = 0
        let claim = UnitEndRewardClaim()
        claim.primaryGateDidOpen()
        claim.fallbackDidResolve(renderableScreenCount: 0)

        XCTAssertTrue(claim.consumeAtUnitClose(
            onEarn: { earned += 1 },
            enqueueVerification: { queued += 1 }
        ))
        XCTAssertFalse(claim.consumeAtUnitClose(
            onEarn: { earned += 1 },
            enqueueVerification: { queued += 1 }
        ))
        XCTAssertEqual(earned, 1)
        XCTAssertEqual(queued, 1)
    }

    @MainActor
    func testUnitEndTeardownBeforeUnitCloseDoesNotGrant() {
        var earned = 0
        var queued = 0
        do {
            let claim = UnitEndRewardClaim()
            claim.primaryGateDidOpen()
            claim.fallbackDidResolve(renderableScreenCount: 0)
            XCTAssertTrue(claim.earned)
        }

        XCTAssertEqual(earned, 0)
        XCTAssertEqual(queued, 0)
    }

    func testUnitEndAuthorityBeforePrimaryGateClaimsOnlyAfterGate() {
        var state = UnitEndRewardState()
        XCTAssertFalse(state.fallbackDidResolve(renderableScreenCount: 0))
        XCTAssertFalse(state.earned)
        XCTAssertTrue(state.primaryGateDidOpen())
        XCTAssertFalse(state.primaryGateDidOpen())
    }

    func testRewardVerificationWireOmitsInternalAdUnitMetadata() throws {
        let data = try JSONEncoder().encode(VerifyRewardRequest(
            serveId: "serve",
            sessionId: "session",
            elapsedPlayTime: 3,
            adUnitId: "internal-unit",
            completionReason: .unitEnd
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["ad_unit_id"])
        XCTAssertEqual(object["completion_reason"] as? String, "unit_end")
    }

    func testTwoToneProgressUsesExactFractionsAndColorsContract() {
        XCTAssertEqual(progressBarGateFraction(gateSeconds: 0, mediaDuration: 10), 1)
        XCTAssertEqual(progressBarGateFraction(gateSeconds: 10, mediaDuration: 10), 1)
        XCTAssertEqual(progressBarGateFraction(gateSeconds: 4, mediaDuration: 10), 0.4)
        let before = twoToneProgressSegments(progress: 0.25, gateFraction: 0.4)
        XCTAssertEqual(before.bright, 0.25)
        XCTAssertEqual(before.dark, 0)
        let after = twoToneProgressSegments(progress: 0.75, gateFraction: 0.4)
        XCTAssertEqual(after.bright, 0.4)
        XCTAssertEqual(after.dark, 0.35, accuracy: 0.0001)
        XCTAssertEqual(twoToneProgressTrackHex, "#3A3A40")
        XCTAssertEqual(twoToneProgressGateHex, "#1186F2")
        XCTAssertEqual(twoToneProgressPostGateHex, "#1156B6")
        XCTAssertTrue(shouldMountProgressBar(
            treatment: .progressBar,
            style: .twoTone,
            dismissUnlocked: true
        ))
        XCTAssertFalse(shouldMountProgressBar(
            treatment: .progressBar,
            style: .single,
            dismissUnlocked: true
        ))
        for treatment in [CloseTreatment.hidden, .countdownCircle, .rewardOrCloseLabel] {
            XCTAssertTrue(shouldMountProgressBar(
                treatment: treatment,
                style: .twoTone,
                dismissUnlocked: false
            ))
            XCTAssertTrue(shouldMountProgressBar(
                treatment: treatment,
                style: .twoTone,
                dismissUnlocked: true
            ))
        }
    }

    func testContractTwoTwoToneMountsForDefaultAndHiddenCloseInBothFormats() throws {
        let payloads = [
            #"{"video_contract":2,"creative":{"type":"video","url":"https://cdn.example/a.mp4"},"ad_behavior":{"close":{"treatment":"hidden"},"progress_bar":{"style":"two_tone"}}}"#,
            #"{"video_contract":2,"creative":{"type":"video","url":"https://cdn.example/a.mp4"},"ad_behavior":{"progress_bar":{"style":"two_tone"}}}"#,
        ]
        for payload in payloads {
            let interstitial = try decodeInterstitial(payload)
            let rewarded = try decodeRewarded(payload)
            for (isContract2Video, style) in [
                (interstitial.primaryUsesVideoPlanV2, interstitial.adBehavior?.progressBar.style),
                (rewarded.primaryUsesVideoPlanV2, rewarded.adBehavior?.progressBar.style),
            ] {
                let effective = effectiveVideoProgressBarStyle(
                    isContract2Video: isContract2Video,
                    configured: style ?? .single
                )
                XCTAssertEqual(effective, .twoTone)
                XCTAssertTrue(shouldMountProgressBar(
                    treatment: .hidden,
                    style: effective,
                    dismissUnlocked: true
                ))
            }
        }
    }

    func testMissingAndMalformedMarkersKeepV1VideoAndDisableContractTwoOwnership() throws {
        for marker in [nil, "2.0", "2e0", "\"2\"", "true"] {
            let markerField = marker.map { "\"video_contract\":\($0)," } ?? ""
            let response = try decodeInterstitial(
                "{\"ad_inserted\":true,\(markerField)\"impression_url\":\"https://measure.example/p\"," +
                    "\"creative\":{\"type\":\"video\",\"url\":\"https://cdn.example/a.mp4\"," +
                    "\"segments\":[{\"clip_index\":0,\"video_pool\":\"ugc\"," +
                    "\"start_seconds\":0,\"end_seconds\":1}]}," +
                    "\"ad_behavior\":{\"progress_bar\":{\"style\":\"two_tone\"}}}"
            )
            XCTAssertNotNil(response.creativeContent, marker ?? "missing")
            XCTAssertFalse(response.primaryUsesVideoPlanV2, marker ?? "missing")
            XCTAssertEqual(response.creative?.segments, [], marker ?? "missing")
            XCTAssertNil(response.validatedImpressionURL, marker ?? "missing")
            XCTAssertEqual(
                effectiveVideoProgressBarStyle(
                    isContract2Video: response.primaryUsesVideoPlanV2,
                    configured: response.adBehavior?.progressBar.style ?? .single
                ),
                .single,
                marker ?? "missing"
            )
        }
    }

    func testImpressionURLIsOwnedOnlyByExactContractTwoMarker() throws {
        let active = try decodeInterstitial(
            #"{"video_contract":2,"impression_url":"https://measure.example/p"}"#
        )
        XCTAssertEqual(active.validatedImpressionURL?.absoluteString, "https://measure.example/p")
        for marker in ["2.0", "2e0", "\"2\"", "true"] {
            let response = try decodeInterstitial(
                "{\"video_contract\":\(marker),\"impression_url\":\"https://measure.example/p\"}"
            )
            XCTAssertNil(response.validatedImpressionURL, marker)
        }
        XCTAssertNil(try decodeInterstitial(
            #"{"impression_url":"https://measure.example/p"}"#
        ).validatedImpressionURL)
    }

    func testMediaTimelineDrivesMidpointSegmentsAndTwoToneWhileWatchTimeStaysSeparate() {
        var gate = VideoPlaybackGate(configuredDelay: 5)
        gate.update(duration: 10, played: 1, mediaPosition: 6)
        XCTAssertFalse(gate.isUnlocked)
        XCTAssertEqual(gate.progress, 0.2)
        XCTAssertTrue(gate.reachedAssetMidpoint)

        var midpoint = VideoQuartileState()
        XCTAssertEqual(midpoint.crossed(position: 6, duration: 10), [50])
        let fill = twoToneProgressSegments(progress: 0.6, gateFraction: 0.5)
        XCTAssertEqual(fill.bright, 0.5)
        XCTAssertEqual(fill.dark, 0.1, accuracy: 0.0001)
        XCTAssertEqual(resolvedVideoMediaPosition(sample: 6, fallback: 0), 6)
        XCTAssertEqual(resolvedVideoMediaPosition(sample: .nan, fallback: 6), 6)

        var watch = VideoVisiblePlaybackClock()
        watch.admitFirstFrame(mediaTime: 6)
        XCTAssertEqual(watch.playedSeconds, 0)
        XCTAssertEqual(watch.firstFrameMediaTime, 6)
    }

    func testPlainImpressionRequestHasNoHeadersOrCookies() throws {
        let request = plainImpressionRequest(url: try XCTUnwrap(URL(string: "https://measure.example/p")))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.allHTTPHeaderFields, [:])
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 5)
    }

    func testPlainImpressionAdmissionRejectsLocalPrivateMalformedAndMixedDNS() throws {
        let literalResolver: ImpressionHostResolver = { [$0] }
        for value in [
            "https://localhost/pixel",
            "https://sub.localhost/pixel",
            "https://127.0.0.1/pixel",
            "https://10.0.0.1/pixel",
            "https://169.254.169.254/pixel",
            "https://224.0.0.1/pixel",
            "https://240.0.0.1/pixel",
            "https://0.0.0.0/pixel",
            "https://[::1]/pixel",
            "https://[fc00::1]/pixel",
            "https://[fe80::1]/pixel",
            "https://[ff02::1]/pixel",
            "https://[::]/pixel",
            "https://user:secret@tracker.example/pixel",
            "https://tracker.example:0/pixel",
            "https://tracker.example:65536/pixel",
            "https://tracker.example:/pixel",
        ] {
            let url = try XCTUnwrap(URL(string: value), value)
            XCTAssertNil(
                admittedPlainImpressionRequest(url: url, resolve: literalResolver),
                value
            )
        }

        let mixed = try XCTUnwrap(URL(string: "https://tracker.example/pixel"))
        XCTAssertNil(admittedPlainImpressionRequest(url: mixed) { _ in
            ["8.8.8.8", "192.168.1.1"]
        })
        XCTAssertNil(admittedPlainImpressionRequest(url: mixed) { _ in nil })
    }

    func testPlainImpressionAdmissionAcceptsOnlyAllPublicResolvedAddresses() throws {
        let url = try XCTUnwrap(URL(string: "https://tracker.example:8443/pixel"))
        let request = admittedPlainImpressionRequest(url: url) { _ in
            ["8.8.8.8", "2606:4700:4700::1111"]
        }

        XCTAssertEqual(request?.url, url)
        XCTAssertEqual(request?.httpMethod, "GET")
    }

    func testPlainImpressionRedirectRejectsPrivateTargetAndSixthRedirect() throws {
        let privateTarget = try XCTUnwrap(URL(string: "https://internal.example/pixel"))
        XCTAssertNil(admittedPlainImpressionRedirectRequest(
            url: privateTarget,
            redirectCount: 0,
            timeout: 5,
            resolve: { _ in ["192.168.1.1"] }
        ))

        let publicTarget = try XCTUnwrap(URL(string: "https://tracker.example/next"))
        XCTAssertNotNil(admittedPlainImpressionRedirectRequest(
            url: publicTarget,
            redirectCount: 4,
            timeout: 1,
            resolve: { _ in ["8.8.8.8"] }
        ))
        XCTAssertNil(admittedPlainImpressionRedirectRequest(
            url: publicTarget,
            redirectCount: 5,
            timeout: 1,
            resolve: { _ in ["8.8.8.8"] }
        ))
    }

    func testPlainImpressionCommitDoesNotDependOnHostAdLifetime() throws {
        var owner: ImpressionTestOwner? = ImpressionTestOwner()
        let weakOwner = WeakFullscreenPresentationOwner(try XCTUnwrap(owner))
        var commitCount = 0
        let sink = FullscreenPresentationAccountingSink(
            recordDisplayed: { _ in },
            recordImpression: { _ in },
            enqueueShown: { _ in },
            enqueueSeen: { _ in }
        )
        let callbacks = fullscreenPresentationAccountingCallbacks(
            owner: weakOwner,
            snapshot: FullscreenPresentationAccountingSnapshot(
                adFormat: "rewarded",
                adUnitId: "unit",
                adId: "impression",
                serveId: nil,
                adValue: .fromBidCpm(0),
                metadata: nil,
                showStartNanos: 0
            ),
            sink: sink,
            onCommittedImpression: { commitCount += 1 },
            notifyDisplayed: { _ in },
            notifyDisplayFailed: { _ in },
            notifyImpression: { _, _ in XCTFail("Released owner must not receive callback") }
        )
        owner = nil

        callbacks.onImpression()

        XCTAssertEqual(commitCount, 1)
    }

    func testPlainImpressionSenderUsesActualCookieFreeFiveSecondRequest() throws {
        let received = expectation(description: "request")
        ImpressionURLProtocol.recorder.install { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertGreaterThan(request.timeoutInterval, 4.9)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            received.fulfill()
        }
        defer { ImpressionURLProtocol.recorder.install(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImpressionURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let sender = PlainImpressionSender(
            configuration: configuration,
            resolver: { _ in ["8.8.8.8"] }
        )

        sender.send(try XCTUnwrap(URL(string: "https://measure.example/pixel")))

        wait(for: [received], timeout: 1)
    }

    func testPlainImpressionFailureReportsLowCardinalityEventExactlyOnce() throws {
        XCTAssertEqual(plainImpressionFailureSignature, "impression_url:get_failed")
        XCTAssertFalse(plainImpressionFailureSignature.contains("measure.example"))
        XCTAssertFalse(plainImpressionFailureSignature.contains("?"))
        let failed = expectation(description: "failure telemetry")
        failed.assertForOverFulfill = true
        ImpressionURLProtocol.recorder.install({ _ in }, statusCode: 500)
        defer { ImpressionURLProtocol.recorder.install(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImpressionURLProtocol.self]
        let sender = PlainImpressionSender(
            configuration: configuration,
            resolver: { _ in ["8.8.8.8"] },
            recordFailure: { failed.fulfill() }
        )

        sender.send(try XCTUnwrap(URL(string: "https://measure.example/private?token=secret")))

        wait(for: [failed], timeout: 1)
    }

    func testBlockedResolverReturnsAtAbsoluteDeadlineWithoutWaitingForWorker() async throws {
        let blocker = DispatchSemaphore(value: 0)
        let resolver = BoundedPublicNetworkHostResolver(
            maximumWorkers: 1,
            maximumPending: 1,
            lookup: { _ in
                blocker.wait()
                return ["8.8.8.8"]
            }
        )
        let started = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await resolver.resolve("blocked.example", deadline: started + 0.03)
            XCTFail("Expected resolver deadline")
        } catch {
            XCTAssertEqual(error as? PublicNetworkResolverError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    }

    func testResolverFastCompletionDeadlineRaceIsStable() async throws {
        let resolver = BoundedPublicNetworkHostResolver(
            maximumWorkers: 2,
            maximumPending: 16,
            lookup: { _ in ["8.8.8.8"] }
        )

        for index in 0..<2_000 {
            let addresses = try await resolver.resolve(
                "fast-\(index).example",
                deadline: ProcessInfo.processInfo.systemUptime + 1
            )
            XCTAssertEqual(addresses, ["8.8.8.8"])
        }
    }

    func testResolverOverloadAndQueuedCancellationFailClosed() async throws {
        let blocker = DispatchSemaphore(value: 0)
        let workerStarted = DispatchSemaphore(value: 0)
        let resolver = BoundedPublicNetworkHostResolver(
            maximumWorkers: 1,
            maximumPending: 1,
            lookup: { _ in
                workerStarted.signal()
                blocker.wait()
                return ["8.8.8.8"]
            }
        )
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let active = Task { try await resolver.resolve("active.example", deadline: deadline) }
        XCTAssertEqual(workerStarted.wait(timeout: .now() + 1), .success)
        let queued = Task { try await resolver.resolve("queued.example", deadline: deadline) }
        while resolver.pendingRequestCount == 0 { await Task.yield() }

        do {
            _ = try await resolver.resolve("overflow.example", deadline: deadline)
            XCTFail("Expected resolver overload")
        } catch {
            XCTAssertEqual(error as? PublicNetworkResolverError, .overloaded)
        }

        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("Expected queued cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        active.cancel()
        blocker.signal()
        _ = try? await active.value
    }

    func testPlainImpressionSendOnlyEnqueuesWhileResolverIsBlocked() throws {
        let blocker = DispatchSemaphore(value: 0)
        let resolver = BoundedPublicNetworkHostResolver(
            maximumWorkers: 1,
            maximumPending: 1,
            lookup: { _ in
                blocker.wait()
                return ["8.8.8.8"]
            }
        )
        let sender = PlainImpressionSender(resolver: resolver)
        let started = ProcessInfo.processInfo.systemUptime

        sender.send(try XCTUnwrap(URL(string: "https://measure.example/pixel")))

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.05)
        blocker.signal()
    }
}

private final class ImpressionTestOwner {}

private final class ImpressionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) -> Void)?
    private var responseStatusCode = 204

    func install(_ handler: ((URLRequest) -> Void)?, statusCode: Int = 204) {
        lock.lock()
        self.handler = handler
        responseStatusCode = statusCode
        lock.unlock()
    }

    func record(_ request: URLRequest) {
        lock.lock(); let handler = handler; lock.unlock()
        handler?(request)
    }

    var statusCode: Int {
        lock.lock(); defer { lock.unlock() }
        return responseStatusCode
    }
}

private final class ImpressionURLProtocol: URLProtocol {
    static let recorder = ImpressionRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        if let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: Self.recorder.statusCode,
            httpVersion: nil,
            headerFields: nil
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class VideoAssetCacheTests: XCTestCase {
    override func tearDown() {
        VideoAssetURLProtocol.recorder.reset()
        super.tearDown()
    }

    func testVideoDownloaderAdmitsPublicInitialURL() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoAssetURLProtocol.self]
        let downloader = URLSessionVideoAssetDownloader(
            configuration: configuration,
            resolver: { _ in ["8.8.8.8", "2606:4700:4700::1111"] }
        )

        try await downloader.download(
            from: try XCTUnwrap(URL(string: "https://cdn.example/video.mp4")),
            to: destination,
            maximumBytes: videoAssetMaximumBytes,
            timeout: videoAssetDownloadTimeout
        )

        XCTAssertEqual(VideoAssetURLProtocol.recorder.requestCount, 1)
    }

    func testVideoDownloaderRejectsPrivateInitialURLBeforeStartingRequest() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoAssetURLProtocol.self]
        let downloader = URLSessionVideoAssetDownloader(
            configuration: configuration,
            resolver: { _ in ["127.0.0.1"] }
        )

        do {
            try await downloader.download(
                from: try XCTUnwrap(URL(string: "https://cdn.example/video.mp4")),
                to: destination,
                maximumBytes: videoAssetMaximumBytes,
                timeout: videoAssetDownloadTimeout
            )
            XCTFail("Expected private initial URL rejection")
        } catch {
            XCTAssertEqual(error as? VideoAssetCacheError, .unsafeTarget)
        }
        XCTAssertEqual(VideoAssetURLProtocol.recorder.requestCount, 0)
    }

    func testVideoDownloaderRejectsMixedDNSBeforeStartingRequest() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoAssetURLProtocol.self]
        let downloader = URLSessionVideoAssetDownloader(
            configuration: configuration,
            resolver: { _ in ["8.8.8.8", "192.168.1.1"] }
        )

        do {
            try await downloader.download(
                from: try XCTUnwrap(URL(string: "https://cdn.example/video.mp4")),
                to: destination,
                maximumBytes: videoAssetMaximumBytes,
                timeout: videoAssetDownloadTimeout
            )
            XCTFail("Expected mixed DNS rejection")
        } catch {
            XCTAssertEqual(error as? VideoAssetCacheError, .unsafeTarget)
        }
        XCTAssertEqual(VideoAssetURLProtocol.recorder.requestCount, 0)
    }

    func testVideoRedirectAdmissionRejectsPrivateAndAcceptsPublicTarget() throws {
        let privateTarget = try XCTUnwrap(URL(string: "https://private.example/video.mp4"))
        XCTAssertNil(admittedPublicNetworkRedirectRequest(
            url: privateTarget,
            redirectCount: 0,
            maximumRedirects: videoAssetMaximumRedirects,
            timeout: videoAssetDownloadTimeout,
            resolve: { _ in ["10.0.0.1"] }
        ))

        let publicTarget = try XCTUnwrap(URL(string: "https://cdn2.example/video.mp4"))
        XCTAssertNotNil(admittedPublicNetworkRedirectRequest(
            url: publicTarget,
            redirectCount: 4,
            maximumRedirects: videoAssetMaximumRedirects,
            timeout: 12,
            resolve: { _ in ["8.8.4.4"] }
        ))
        XCTAssertNil(admittedPublicNetworkRedirectRequest(
            url: publicTarget,
            redirectCount: 5,
            maximumRedirects: videoAssetMaximumRedirects,
            timeout: 12,
            resolve: { _ in ["8.8.4.4"] }
        ))
    }

    func testVideoDownloaderCancellationStopsActiveRequest() async throws {
        VideoAssetURLProtocol.recorder.hangRequests = true
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoAssetURLProtocol.self]
        let downloader = URLSessionVideoAssetDownloader(
            configuration: configuration,
            resolver: { _ in ["8.8.8.8"] }
        )
        let task = Task {
            try await downloader.download(
                from: try XCTUnwrap(URL(string: "https://cdn.example/video.mp4")),
                to: destination,
                maximumBytes: videoAssetMaximumBytes,
                timeout: videoAssetDownloadTimeout
            )
        }
        while VideoAssetURLProtocol.recorder.requestCount == 0 { await Task.yield() }

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        for _ in 0..<100 where VideoAssetURLProtocol.recorder.stopCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(VideoAssetURLProtocol.recorder.stopCount, 1)
    }

    func testVideoDownloaderDNSResolutionConsumesOriginalDeadline() async throws {
        let clock = LockedMonotonicClock()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoAssetURLProtocol.self]
        let downloader = URLSessionVideoAssetDownloader(
            configuration: configuration,
            resolver: { _ in
                clock.advance(by: videoAssetDownloadTimeout)
                return ["8.8.8.8"]
            },
            monotonicNow: { clock.now }
        )

        do {
            try await downloader.download(
                from: try XCTUnwrap(URL(string: "https://cdn.example/video.mp4")),
                to: destination,
                maximumBytes: videoAssetMaximumBytes,
                timeout: videoAssetDownloadTimeout
            )
            XCTFail("Expected deadline rejection")
        } catch {
            XCTAssertEqual(error as? VideoAssetCacheError, .timedOut)
        }
        XCTAssertEqual(VideoAssetURLProtocol.recorder.requestCount, 0)
    }

    func testSingleFlightCreatesOpaqueLocalAssetAndReusesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeVideoDownloader(bytes: 8, delayNanos: 5_000_000)
        let cache = VideoAssetCache(rootURL: root, downloader: downloader)
        let remote = try XCTUnwrap(URL(string: "https://cdn.example/private/path.mp4?token=secret"))

        async let first = cache.acquire(remote)
        async let second = cache.acquire(remote)
        let leases = try await [first, second]

        let callCount = await downloader.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(leases[0].localURL, leases[1].localURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leases[0].localURL.path))
        XCTAssertTrue(VideoAssetCache.isOpaqueAssetName(leases[0].localURL.lastPathComponent))
        XCTAssertFalse(leases[0].localURL.lastPathComponent.contains("path"))
        let localURL = leases[0].localURL
        leases.forEach { $0.release() }
        await cache.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testPerAssetLimitIsEnforcedWithoutContentLength() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeVideoDownloader(bytes: videoAssetMaximumBytes + 1)
        let cache = VideoAssetCache(rootURL: root, downloader: downloader)

        do {
            _ = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/large.mp4")))
            XCTFail("Expected oversized asset rejection")
        } catch {
            XCTAssertEqual(error as? VideoAssetCacheError, .tooLarge)
        }
        await cache.waitUntilIdle()
    }

    func testActiveLeaseIsNeverEvictedByTotalCap() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeVideoDownloader(bytes: 40 * 1024 * 1024)
        let cache = VideoAssetCache(rootURL: root, downloader: downloader)
        let first = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/one.mp4")))
        let second = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/two.mp4")))
        let secondURL = second.localURL
        second.release()
        await Task.yield()
        let third = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/three.mp4")))

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.localURL.path))
        first.release()
        third.release()
        await cache.waitUntilIdle()
    }

    func testCacheConstantsMatchBoundedContract() {
        XCTAssertEqual(videoAssetMaximumBytes, 50 * 1024 * 1024)
        XCTAssertEqual(videoAssetCacheMaximumBytes, 100 * 1024 * 1024)
        XCTAssertEqual(videoAssetDownloadTimeout, 30)
        XCTAssertEqual(videoAssetOrphanLifetime, 24 * 60 * 60)
        XCTAssertEqual(videoAssetMaximumConcurrentTransfers, 2)
    }

    func testEveryVideoAssetCacheErrorMapsToExactCallbackAndTelemetryClassification() {
        let cases: [(VideoAssetCacheError, String, String)] = [
            (.invalidURL, "no_fill", "invalid_url"),
            (.unsafeTarget, "no_fill", "unsafe_target"),
            (.unavailable, "network:http_503", "transfer_failed"),
            (.tooLarge, "no_fill", "asset_too_large"),
            (.cacheFull, "no_fill", "cache_full"),
            (.admissionOverflow, "no_fill", "cache_admission"),
            (.timedOut, "network:http_408", "cache_timeout"),
        ]

        XCTAssertEqual(cases.map(\.0), VideoAssetCacheError.allCases)
        for (cacheError, expectedCallback, expectedTelemetryCode) in cases {
            let failure = videoAssetLoadFailure(for: cacheError)
            XCTAssertEqual(callbackClassification(failure.callbackError), expectedCallback, "\(cacheError)")
            XCTAssertEqual(failure.telemetryCode, expectedTelemetryCode, "\(cacheError)")
            XCTAssertEqual(
                failure.telemetrySignature,
                "video_asset:\(expectedTelemetryCode)",
                "\(cacheError)"
            )
        }
    }

    func testMalformedFullscreenJSONRemainsInvalidResponse() {
        XCTAssertThrowsError(
            try decodeFullscreenPayload(AdLoadResponse.self, from: Data("not json".utf8))
        ) { error in
            XCTAssertFalse(error is VideoAssetCacheError)
            XCTAssertEqual(
                self.callbackClassification(.network(.invalidResponse)),
                "network:invalid_response"
            )
        }
    }

    func testStrictTokenMapRetainsOnlyRequiredExactNumericPaths() throws {
        let html = String(repeating: "x", count: 100_000)
        let data = Data(#"""
        {"video_contract":2,"rendered_html":"\#(html)","bid_amt":4.5,
         "ad_behavior":{"close":{"delay_seconds":8},"skoverlay":{"delay_seconds":3}},
         "creative":{"segments":[{"clip_index":0,"video_pool":"ugc","start_seconds":0,"end_seconds":1}]},
         "ads":[{"ad_behavior":{"skoverlay":{"delay_seconds":4}},
                  "creative":{"segments":[{"clip_index":1,"video_pool":"gameplay","start_seconds":1,"end_seconds":2}]}}]}
        """#.utf8)
        let tokens = try XCTUnwrap(StrictJSONTokenMap.parse(data))

        XCTAssertEqual(tokens, [
            "video_contract": "2",
            "ad_behavior.skoverlay.delay_seconds": "3",
            "creative.segments[0].clip_index": "0",
            "ads[0].ad_behavior.skoverlay.delay_seconds": "4",
            "ads[0].creative.segments[0].clip_index": "1",
        ])
        XCTAssertNil(tokens["rendered_html"])
        XCTAssertNil(tokens["bid_amt"])
    }

    func testFullscreenPayloadRejectsOversizeAndExcessiveNestingBeforeTypedDecode() {
        let oversized = Data(repeating: 32, count: fullscreenResponseMaximumBytes + 1)
        XCTAssertThrowsError(try decodeFullscreenPayload(AdLoadResponse.self, from: oversized)) {
            guard case SimulaAPIError.invalidResponse = $0 else {
                return XCTFail("Expected invalid response, got \($0)")
            }
        }

        let nesting = strictJSONMaximumNestingDepth + 2
        let deep = String(repeating: "[", count: nesting)
            + "0"
            + String(repeating: "]", count: nesting)
        XCTAssertThrowsError(try decodeFullscreenPayload(AdLoadResponse.self, from: Data(deep.utf8))) {
            guard case SimulaAPIError.invalidResponse = $0 else {
                return XCTFail("Expected invalid response, got \($0)")
            }
        }
    }

    func testTransferConcurrencyIsCappedAtTwo() async throws {
        let root = temporaryDirectory()
        let downloader = ConcurrencyGatedVideoDownloader(bytes: 8)
        let cache = VideoAssetCache(rootURL: root, downloader: downloader)
        let urls = try ["a", "b", "c"].map {
            try XCTUnwrap(URL(string: "https://cdn.example/\($0).mp4"))
        }

        let first = Task { try await cache.acquire(urls[0]) }
        await downloader.waitUntilStarted(1)
        let second = Task { try await cache.acquire(urls[1]) }
        await downloader.waitUntilStarted(2)
        let third = Task { try await cache.acquire(urls[2]) }
        while await cache.transferAdmissionSnapshot().pending < 1 { await Task.yield() }

        let maximumActiveCalls = await downloader.maximumActiveCalls
        XCTAssertEqual(maximumActiveCalls, 2)
        let admission = await cache.transferAdmissionSnapshot()
        XCTAssertEqual(admission.active, 2)
        XCTAssertEqual(admission.pending, 1)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await downloader.waitUntilStarted(3)
        await downloader.releaseAll()
        let leases = try await [second.value, third.value]
        leases.forEach { $0.release() }
        await cache.waitUntilIdle()
        try FileManager.default.removeItem(at: root)
    }

    func testTransferAdmissionIsFIFOAndUsesOneDeadlineWaitInsteadOfPolling() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = OrderedGatedVideoDownloader()
        let sleeps = LockedCounter()
        let cache = VideoAssetCache(
            rootURL: root,
            downloader: downloader,
            maximumConcurrentTransfers: 1,
            sleep: { delay in
                sleeps.increment()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        )
        let urls = try ["a", "b", "c"].map {
            try XCTUnwrap(URL(string: "https://cdn.example/\($0).mp4"))
        }
        let first = Task { try await cache.acquire(urls[0]) }
        while await downloader.started.count < 1 { await Task.yield() }
        let second = Task { try await cache.acquire(urls[1]) }
        while await cache.transferAdmissionSnapshot().pending < 1 { await Task.yield() }
        let third = Task { try await cache.acquire(urls[2]) }
        while await cache.transferAdmissionSnapshot().pending < 2 { await Task.yield() }
        while sleeps.value < 2 { await Task.yield() }

        XCTAssertEqual(sleeps.value, 2)
        await downloader.releaseNext()
        while await downloader.started.count < 2 { await Task.yield() }
        let firstTwo = await downloader.started
        XCTAssertEqual(firstTwo, ["a.mp4", "b.mp4"])
        await downloader.releaseNext()
        while await downloader.started.count < 3 { await Task.yield() }
        let allStarted = await downloader.started
        XCTAssertEqual(allStarted, ["a.mp4", "b.mp4", "c.mp4"])
        await downloader.releaseNext()

        let leases = try await [first.value, second.value, third.value]
        leases.forEach { $0.release() }
        await cache.waitUntilIdle()
    }

    func testTransferPendingQueueCapFailsOverflowGracefully() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = OrderedGatedVideoDownloader()
        let cache = VideoAssetCache(
            rootURL: root,
            downloader: downloader,
            maximumConcurrentTransfers: 1
        )
        let firstURL = try XCTUnwrap(URL(string: "https://cdn.example/active.mp4"))
        let first = Task { try await cache.acquire(firstURL) }
        while await downloader.started.isEmpty { await Task.yield() }
        var queued: [Task<VideoAssetLease, Error>] = []
        for index in 0..<videoAssetMaximumPendingTransfers {
            let url = try XCTUnwrap(URL(string: "https://cdn.example/queued-\(index).mp4"))
            queued.append(Task { try await cache.acquire(url) })
        }
        while await cache.transferAdmissionSnapshot().pending < videoAssetMaximumPendingTransfers {
            await Task.yield()
        }

        do {
            _ = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/overflow.mp4")))
            XCTFail("Expected bounded queue rejection")
        } catch {
            XCTAssertEqual(error as? VideoAssetCacheError, .admissionOverflow)
        }
        let started = await downloader.started
        XCTAssertEqual(started, ["active.mp4"])

        queued.forEach { $0.cancel() }
        await downloader.releaseNext()
        let lease = try await first.value
        lease.release()
        for task in queued { _ = try? await task.value }
        await cache.waitUntilIdle()
    }

    func testOldPartialIsCleanedBeforeDownload() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("orphan.partial")
        FileManager.default.createFile(atPath: partial.path, contents: Data([1]))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -videoAssetOrphanLifetime - 1)],
            ofItemAtPath: partial.path
        )
        let cache = VideoAssetCache(rootURL: root, downloader: FakeVideoDownloader(bytes: 8))
        let lease = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/a.mp4")))

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        lease.release()
        await cache.waitUntilIdle()
    }

    func testFreshOrphanPartialBytesCountTowardTotalCap() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("fresh.partial")
        XCTAssertTrue(FileManager.default.createFile(atPath: partial.path, contents: nil))
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: UInt64(60 * 1024 * 1024))
        try handle.close()
        let cache = VideoAssetCache(rootURL: root, downloader: FakeVideoDownloader(bytes: 8))

        let lease = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/a.mp4")))

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        lease.release()
        await cache.waitUntilIdle()
    }

    func testOrphanCleanupCoversCompletedAndPartialFilesAcrossBatches() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDate = Date(timeIntervalSinceNow: -videoAssetOrphanLifetime - 1)
        var oldURLs: [URL] = []
        for index in 0..<260 {
            let name = VideoAssetCache.key(for: URL(string: "https://old.example/\(index)") ?? root)
            let url = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
            oldURLs.append(url)
        }
        let partial = root.appendingPathComponent("old.partial")
        FileManager.default.createFile(atPath: partial.path, contents: Data([1]))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: partial.path)
        oldURLs.append(partial)
        let cache = VideoAssetCache(rootURL: root, downloader: FakeVideoDownloader(bytes: 8))

        try await cache.waitUntilMaintenanceComplete()
        XCTAssertTrue(oldURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let current = try XCTUnwrap(URL(string: "https://cdn.example/current.mp4"))
        let lease = try await cache.acquire(current)
        lease.release()
        await cache.waitUntilIdle()
    }

    func testQueueWaitConsumesTheSingleThirtySecondDeadline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = GatedVideoDownloader()
        let clock = LockedMonotonicClock()
        let cache = VideoAssetCache(
            rootURL: root,
            downloader: downloader,
            monotonicNow: { clock.now },
            maximumConcurrentTransfers: 1,
            sleep: { delay in clock.advance(by: delay) }
        )
        let first = Task {
            try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/first.mp4")))
        }
        while await downloader.callCount == 0 { await Task.yield() }

        do {
            _ = try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/queued.mp4")))
            XCTFail("Expected queue deadline")
        } catch {
            XCTAssertEqual(error as? VideoAssetCacheError, .timedOut)
        }
        XCTAssertGreaterThanOrEqual(clock.now, videoAssetDownloadTimeout)
        await downloader.releaseAll()
        first.cancel()
        // The transfer can finish before cancellation; its Task retains the returned lease.
        // Release it explicitly before waiting for the cache's lease count to reach zero.
        do {
            let lease = try await first.value
            lease.release()
        } catch {
            // Cancellation/timeout already reconciles the unsuccessful acquire.
        }
        await cache.waitUntilIdle()
    }

    func testQueuedCancellationDoesNotStartOrLeakATransfer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = GatedVideoDownloader()
        let cache = VideoAssetCache(
            rootURL: root,
            downloader: downloader,
            maximumConcurrentTransfers: 1
        )
        let first = Task {
            try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/first.mp4")))
        }
        while await downloader.callCount == 0 { await Task.yield() }
        let queued = Task {
            try await cache.acquire(try XCTUnwrap(URL(string: "https://cdn.example/queued.mp4")))
        }
        await Task.yield()
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let callCount = await downloader.callCount
        XCTAssertEqual(callCount, 1)
        await downloader.releaseAll()
        let lease = try await first.value
        lease.release()
        await cache.waitUntilIdle()
    }

    func testLastWaiterCancellationAllowsImmediateSameURLReacquire() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = GatedVideoDownloader()
        let cache = VideoAssetCache(rootURL: root, downloader: downloader)
        let remote = try XCTUnwrap(URL(string: "https://cdn.example/same.mp4"))
        let cancelled = Task { try await cache.acquire(remote) }
        while await downloader.callCount < 1 { await Task.yield() }

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let activeCallCount = await downloader.activeCallCount
        XCTAssertEqual(activeCallCount, 0)
        let partials = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "partial" }
        XCTAssertTrue(partials.isEmpty)

        let replacement = Task { try await cache.acquire(remote) }
        while await downloader.callCount < 2 { await Task.yield() }
        await downloader.releaseAll()
        let lease = try await replacement.value
        let callCount = await downloader.callCount

        XCTAssertEqual(callCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.localURL.path))
        lease.release()
        await cache.waitUntilIdle()
    }

    func testFileCapIsEnforcedBeforeAdmittingAnotherTransfer() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<256 {
            let remote = try XCTUnwrap(URL(string: "https://seed.example/\(index).mp4"))
            let file = root.appendingPathComponent(VideoAssetCache.key(for: remote))
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
        }
        let cache = VideoAssetCache(rootURL: root, downloader: FakeVideoDownloader(bytes: 1))
        let remote = try XCTUnwrap(URL(string: "https://cdn.example/new.mp4"))
        var lease: VideoAssetLease?
        for _ in 0..<20 where lease == nil {
            do { lease = try await cache.acquire(remote) }
            catch VideoAssetCacheError.cacheFull { await Task.yield() }
        }
        let acquired = try XCTUnwrap(lease)
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { VideoAssetCache.isOpaqueAssetName($0.lastPathComponent) }

        XCTAssertLessThanOrEqual(files.count, 256)
        acquired.release()
        await cache.waitUntilIdle()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func callbackClassification(_ error: SimulaAdError) -> String {
        switch error {
        case .noFill:
            return "no_fill"
        case .network(let apiError):
            switch apiError {
            case .httpError(let statusCode): return "network:http_\(statusCode)"
            case .invalidResponse: return "network:invalid_response"
            case .invalidURL: return "network:invalid_url"
            case .invalidApiKey: return "network:invalid_api_key"
            case .noFill: return "network:no_fill"
            case .decodingError: return "network:decoding_error"
            case .adUnitNotFound: return "network:ad_unit_not_found"
            }
        default:
            return error.telemetryCode
        }
    }
}

private final class VideoAssetURLProtocolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var stops = 0
    private var shouldHang = false

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }

    var hangRequests: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return shouldHang
        }
        set {
            lock.lock(); shouldHang = newValue; lock.unlock()
        }
    }

    func recordRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return shouldHang
    }

    func recordStop() {
        lock.lock(); stops += 1; lock.unlock()
    }

    func reset() {
        lock.lock()
        requests = 0
        stops = 0
        shouldHang = false
        lock.unlock()
    }
}

private final class VideoAssetURLProtocol: URLProtocol {
    static let recorder = VideoAssetURLProtocolRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard !Self.recorder.recordRequest() else { return }
        if let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "1"]
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.recorder.recordStop()
    }
}

private actor FakeVideoDownloader: VideoAssetDownloading {
    private let bytes: Int64
    private let delayNanos: UInt64
    private var calls = 0
    private var activeCalls = 0
    private var peakActiveCalls = 0

    init(bytes: Int64, delayNanos: UInt64 = 0) {
        self.bytes = bytes
        self.delayNanos = delayNanos
    }

    var callCount: Int { calls }
    var maximumActiveCalls: Int { peakActiveCalls }

    func download(
        from remoteURL: URL,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        calls += 1
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.truncate(atOffset: UInt64(max(0, bytes)))
        try handle.close()
    }
}

private actor ConcurrencyGatedVideoDownloader: VideoAssetDownloading {
    private let bytes: Int64
    private var startedCalls = 0
    private var activeCalls = 0
    private var peakActiveCalls = 0
    private var gates: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(bytes: Int64) {
        self.bytes = bytes
    }

    var maximumActiveCalls: Int { peakActiveCalls }

    func waitUntilStarted(_ count: Int) async {
        guard startedCalls < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        let current = Array(gates.values)
        gates.removeAll()
        current.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        gates.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func download(
        from remoteURL: URL,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        startedCalls += 1
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        let ready = startedWaiters.filter { startedCalls >= $0.count }
        startedWaiters.removeAll { startedCalls >= $0.count }
        ready.forEach { $0.continuation.resume() }
        defer { activeCalls -= 1 }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                gates[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.truncate(atOffset: UInt64(max(0, bytes)))
        try handle.close()
    }
}

private final class LockedMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by amount: TimeInterval) {
        lock.lock(); value += amount; lock.unlock()
    }
}

private actor GatedVideoDownloader: VideoAssetDownloading {
    private var calls = 0
    private var activeCalls = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    var callCount: Int { calls }
    var activeCallCount: Int { activeCalls }

    func releaseAll() {
        let current = Array(waiters.values)
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func download(
        from remoteURL: URL,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        calls += 1
        activeCalls += 1
        defer { activeCalls -= 1 }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
        FileManager.default.createFile(atPath: temporaryURL.path, contents: Data([1]))
    }
}

private actor OrderedGatedVideoDownloader: VideoAssetDownloading {
    private(set) var started: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func download(
        from remoteURL: URL,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        started.append(remoteURL.lastPathComponent)
        await withCheckedContinuation { waiters.append($0) }
        try Task.checkCancellation()
        FileManager.default.createFile(atPath: temporaryURL.path, contents: Data([1]))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
