# Simula Ad SDK for iOS

AI-powered native ads, interstitial ads, and rewarded ads for iOS apps using SwiftUI.

Simula delivers ads that feel native to AI chat and character-driven applications. The SDK handles ad rendering, contextual targeting, privacy compliance, and server-side reward verification out of the box.

## Ad Formats

| Format | Description |
|---|---|
| **NativeAdSlot** | Inline ad card that fits naturally into SwiftUI layouts |
| **Interstitial Ad** | Full-screen ad with preload/show lifecycle |
| **Rewarded Ad** | Play-to-earn ad with server-side reward verification |

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Getting Started

Full integration guides, API references, and examples are available at:

**[docs.simula.ad/swift-sdk](https://docs.simula.ad/swift-sdk/quick-start)**

- [Quick Start](https://docs.simula.ad/swift-sdk/quick-start) -- installation, provider setup, privacy, ATT, and error handling
- [NativeAdSlot](https://docs.simula.ad/swift-sdk/native-ad-slot) -- inline ad view
- [Interstitial Ad](https://docs.simula.ad/swift-sdk/interstitial-ad) -- full-screen ad
- [Rewarded Ad](https://docs.simula.ad/swift-sdk/rewarded-ad) -- rewarded ad with server-side verification

## Publisher Metadata

Publisher metadata is scoped to an individual impression. Fullscreen ads snapshot it when `load()`
starts. A normal native slot sends its component snapshot on `/load`; a preloaded native ad has
already loaded without metadata, so its consuming `NativeAdSlot` sends the snapshot on `/seen`.

```swift
let interstitial = SimulaInterstitialAd(adUnitId: "home")
interstitial.setMetadata(["placement": "home", "surface": "feed"])
interstitial.load()

NativeAdSlot(
    adUnitId: "chat",
    metadata: ["conversation_type": "group"]
)

let preloadedAdId = await SimulaAds.preloadNativeAd(
    adUnitId: "chat"
)

NativeAdSlot(
    adUnitId: "chat",
    metadata: ["conversation_type": "group"],
    preloadedAdId: preloadedAdId
)
```

Metadata accepts at most 10 entries. Keys must be non-empty, at most 64 Unicode scalars, must not
start with `$`, and must not contain `.`. Values are limited to 256 Unicode scalars. Invalid or excess
entries are ignored without failing the ad load. `SimulaRewardedAd` exposes the same
`setMetadata(_:_:)` and `setMetadata(_:)` overloads as `SimulaInterstitialAd`. Native preloads do not
accept metadata; supply it to the `NativeAdSlot` that consumes the preload.

## Fullscreen Video Contract

Interstitial and rewarded load requests advertise `contracts.video = 2`. A response opts in only
with the exact numeric root field `video_contract: 2`; legacy `video_v1` and `video_plan_v2` markers
are not serialized or activated. Contract 2 uses one stitched primary video URL. Optional
`creative.segments` identify telemetry ranges only and never cause player restarts or fallback-video
handoffs. Each segment emits start, 50%, and completion events with clip-local position, duration,
and muted/unmuted watch time. Ordinary HTML end screens continue in their server order.

Video assets are fully downloaded before the loaded callback. The SDK uses an opaque, backup-excluded
cache under `Library/Caches`, with 50 MiB per-asset and 100 MiB total limits, a 30-second transfer
deadline, at most two concurrent transfers, single-flight URL downloads, and active-lease-safe
eviction. AVPlayer never receives a remote URL and the SDK does not fall back to streaming.

All videos start unmuted, including legacy plans. Activation failure or a bounded activation timeout
falls back to muted playback. A timed-out activation blocks further activation attempts until that
system call returns, so later videos can play muted immediately without queuing blocked work.

Audio-session activation is deliberately asymmetric for host stability. The SDK may best-effort
activate the process-global `AVAudioSession` when unmuted playback needs it, but it never calls
`setActive(false)` because exclusive ownership cannot be proven. Final SDK release pauses or stops
its player and clears only SDK logical accounting. Overlapping SDK playback remains reference-counted,
and idle-timer ownership is independently released and restored to the host's prior value.

For rewarded contract-2 units, `ad_behavior.reward.earn_at = "unit_end"` establishes reward
authority only at the final gate: the primary gate when no fallback is authoritative, or the final
renderable fallback gate/end when fallback screens exist. Host-object teardown does not promote an
earlier gate. The publisher callback and one verification are deferred until the whole unit closes,
using `completion_reason = "unit_end"`. If an admitted primary video fails before its gate, a rendered
end screen can still earn at its final gate; unavailable screens do not manufacture gate evidence.
An explicit `verified: false` permanently reconciles verification; malformed responses remain retryable.

An optional validated top-level `impression_url` is requested once at the existing two-second
impression commit. This measurement request is a plain bounded unauthenticated GET with no SDK,
privacy, or cookie headers and does not affect impression, paid, or reward callbacks.
Cancelling before the first video frame emits `video_close` with reason `pre_first_frame_cancel`;
normal user closes retain reason `user`, so reporting can distinguish preparation cancellations.

## Development Environment

Development artifacts select the staging API when the app's Info.plist contains
`SimulaStagingEnvironmentEnabled` as a Boolean set to `true`. Stable artifacts and missing or
incorrectly typed values fail closed to production. The first environment selection is process-wide,
and `SimulaAds.apiEnvironment` reports the effective value. Development hosts may explicitly call
`configureAPIEnvironment(_:)` before initialization; stable artifacts refuse staging. `devMode` does
not select the API environment.

## Privacy & App Store Compliance

The SDK bundles a `PrivacyInfo.xcprivacy` manifest and supports IAB consent frameworks (TCF, CCPA, GPP), COPPA, and App Tracking Transparency. See the [Quick Start guide](https://docs.simula.ad/swift-sdk/quick-start#privacy-att) for details.

## Dashboard

Create and manage ad units, view analytics, and configure server-side verification at [publisher.simula.ad](https://publisher.simula.ad).

## Support

- Documentation: [docs.simula.ad](https://docs.simula.ad)
- Email: admin@simula.ad
- Website: [simula.ad](https://simula.ad)

## License

MIT
