# Simula Ad SDK (Swift) — AI Development Guide

Rules for any AI agent or developer writing code in this repository. This SDK ships inside third-party apps: a bug here crashes someone else's app.

## Prime directive

**The SDK must never crash the host app.** Priorities, in order:

1. **Stability** — fail gracefully. Degrade to nil / blank view / skipped beacon, never throw into host code.
2. **Performance** — no main-thread I/O, bounded memory, reuse pooled resources, no re-render storms.
3. **Cross-platform parity** — event names, wire keys, and error strings match the Kotlin and React SDKs.
4. **Maintainability** — extend existing layers; never add a parallel code path or new dependency.

## When in doubt (defaults — do not stop to ask)

- Unsure if something can throw? Use `try?`, record telemetry, return a safe default.
- Unsure about threading? UI, WebView, and `SimulaAds` are `@MainActor`; background singletons use lock-guarded snapshots.
- Unsure how to structure a feature? Copy the nearest exemplar file (table below).
- Unsure if a dependency is allowed? It isn't. URLSession, ImageIO, and MetricKit only — no third-party libraries.

## Architecture

```
Host app
  → SimulaProviderView (SwiftUI) | SimulaAds.initialize (imperative)
    → SimulaProvider.init        ← the single init path (cheap, main-thread):
                                     connection monitor, device signals, privacy apply.
                                     Everything disk/syscall-heavy is deferred to
                                     `start()`/`runStartup` (off-main prewarm: IDFV/UA,
                                     shared URLSession, telemetry, crash-guard install,
                                     beacon/verification drains, version check →
                                     session warm-up). WebViews prewarm only from
                                     active ad demand. `ensureSession`
                                     awaits that startup — no request can race ahead of it.
      → SimulaAPI (transport, models, makeHeaders chokepoint)
        → URLSession (SDK-configured session — never URLSession.shared on ad paths)
  → UI: NativeAdSlot / MiniGame / Interstitial / Rewarded
    → CachedAsyncImage + CoverImageCache · WebViewPool (@MainActor)
    → Telemetry.shared.record* (fire-and-forget, never throws)
```

Folder map: `Core/` entry points · `Ads/` fullscreen ads · `NativeAd/` inline ads · `Components/` SwiftUI + WebView · `Networking/` API, queues, connection type · `Telemetry/` pipeline + crash guard · `Privacy/` consent · `Utils/` UA, device id, validation · `Types.swift` shared wire models.

## Hard rules (mechanically checkable)

Never introduce:

- `try!`, `as!`, or force-unwrap (`!`) outside tests
- `URLSession.shared` on ad or telemetry paths — use the `SimulaAPI` session
- Holding `NSLock` across `await` or blocking I/O
- `UIDevice` (battery, etc.) reads off the main thread — snapshot on main, read the snapshot under lock
- POSIX signal handlers (conflicts with host crash reporters; MetricKit + NSSetUncaughtExceptionHandler only)
- A second initialization path bypassing `SimulaProvider.init`
- New dependencies in `Package.swift` / the podspec
- Query strings, tokens, or PII in telemetry `message`/`breadcrumb`/paths
- iOS-only APIs without `#if os(iOS)` / `#if canImport(UIKit)` guards (tests build on macOS)

## Copy an existing pattern (golden examples)

| Task | Model it on |
|---|---|
| New durable retry queue | `Networking/AdBeaconQueue.swift` |
| New API endpoint | `Networking/SimulaAPI.swift` (route through `makeHeaders`) |
| New inline/SwiftUI ad surface | `NativeAd/NativeAdSlot.swift` |
| New fullscreen ad format | `Ads/SimulaInterstitialAd.swift` + its presenter |
| New device/network signal | `Networking/SimulaConnectionType.swift` |
| Engine test with fakes | `Tests/SimulaAdSDKTests/TelemetryManagerTests.swift` |
| Wire-model contract test | `Tests/SimulaAdSDKTests/NativeAdParsingTests.swift` |

Numeric limits (pool sizes, cache caps, timeouts) live as constants in those files — read them there; do not trust docs for values.

## Canonical patterns

Fire-and-forget tracking (never throws to the host):

```swift
_ = try? await SimulaAPI.shared.trackImpression(impressionId: id)
```

Telemetry (signatures are low-cardinality `domain:detail` keys; stage names shared with Android):

```swift
Telemetry.shared.recordLifecycle(stage: "load_success", adFormat: "interstitial", adUnitId: id, durationMs: ms)
Telemetry.shared.recordError(signature: "webview:render_gone", breadcrumb: "surface=native_ad")
```

Lock-guarded snapshot (cross-thread mutable state — `@unchecked Sendable` + `NSLock`):

```swift
lock.lock(); let snapshot = state; lock.unlock()
await sender.send(snapshot)          // never await while holding the lock
```

Main-actor hop for imperative API from background code:

```swift
await MainActor.run { SimulaAds.initialize(apiKey: key) }
```

## Non-negotiable behaviors

- **Single init path**: everything funnels through `SimulaProvider.init` — but `init` must stay cheap enough to run inline at app launch. One-time disk/syscall costs (IDFV, UA, shared `URLSession` build, telemetry install, version check) belong in the deferred startup (`start()` → `runStartup`/`runStartupPrewarm`), not inline in `init`. `ensureSession` gates on that startup (and lazily kicks it), so "telemetry + privacy before the first request" holds for every entry path.
- **Session**: `ensureSession()` coalesces concurrent callers into one Task; a failed task is cleared so the next call retries. Never re-create sessions per ad load.
- **Feed performance**: reads that only need config use `@Environment(\.simulaProvider)` (non-observing), not `@EnvironmentObject` — prevents whole-feed re-renders on `@Published` changes.
- **WebView pool**: `@MainActor`; one idle view (zero on constrained devices), five-minute pressure/background cooldown, active-demand prewarm only, consent-aware data store; release = stop loading, nil delegates, `about:blank`; script handlers use the stable-forwarder pattern (never re-register per acquire, never leak on discard).
- **Crash guard**: reports MetricKit diagnostics only when the Apple-attributed thread contains SDK frames; chains to the host's existing handler; sync persist on crash, replay next launch. Fingerprint/dedupe semantics and bounded frame counts match Android while stack formats remain OS-native.
- **CTA/MMP redirects**: use `SimulaUserAgent.sessionConfiguration()` (Safari-style UA, no `X-Device-Id`) — first-party API and telemetry keep `standardHeaders()`.
- **Connection type**: `X-Connection-Type` read live per request in `makeHeaders`, never cached at init.
- **Consent**: always via `SimulaPrivacy.shared.currentSnapshot`; PII re-read at telemetry flush.
- **Wire models**: snake_case `CodingKeys`, tolerant decoding (`try?`, defaults) — a malformed server field must never fail the whole response.

## Testing

Tests in `Tests/SimulaAdSDKTests/`, XCTest with `@testable import`. Tier 0: pure functions (parsing, classify, backoff). Tier 1: engines with `FakeStore`/`FakeSender` and isolated `UserDefaults(suiteName: UUID)`. Inject `now`, `random`, `backoff` for determinism. No real network.

## Distribution (binary XCFramework since 1.1.4)

Consumers get a **prebuilt XCFramework** — host Xcodes never compile SDK source (the mitigation for the Swift 6.1–6.3 optimizer task-teardown miscompile; see `.cursor/skills/swift-concurrency-task-shape/SKILL.md`). Consequences for code changes:

- `main` keeps the source manifest; each release **tag** carries a generated binary manifest (`scripts/make-release-manifest.sh`). Never hand-edit a tag's `Package.swift`.
- The release workflow (`.github/workflows/release.yml`) runs only from `main`: pinned Xcode, optimized macOS and iOS tests, `scripts/build-xcframework.sh`, local CocoaPods lint, generated binary/checksummed release manifests, binary tag + GitHub Release, asset checksum verification, then `pod trunk push`. The `Cocoa Pod` GitHub environment holds the trunk credentials for the irreversible publication step.
- The public API must stay **library-evolution clean** (`BUILD_LIBRARY_FOR_DISTRIBUTION=YES` — CI checks this). No `@inlinable`/`@_alwaysEmitIntoClient` on public API: inlined bodies would be compiled by host toolchains, re-opening the miscompile.
- Resources (including `PrivacyInfo.xcprivacy`) ship inside the framework's `SimulaAdSDK_SimulaAdSDK.bundle`; the build script hard-fails if they're missing.

## Version sync (all, always together)

1. `Sources/SimulaAdSDK/Telemetry/Telemetry.swift` — `SIMULA_SDK_VERSION`
2. `SimulaAdSDK.podspec` — `s.version`
3. The release tag (created by the release workflow, which also writes the binary `Package.swift` url/checksum for that tag)

## Definition of done — mandatory gate

The task is not complete until both commands pass:

```bash
swift build
swift test
```

CI (`.github/workflows/ci.yml`) additionally runs the test suite on an iOS Simulator (exercises `#if os(iOS)` code), the suite again under `-c release` (optimized — the only lane that can catch the task-teardown miscompile class), and a `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` build (binary-artifact readiness) — keep platform guards and the public interface clean or CI fails even when `swift test` passes locally. If you changed public API or behavior, check whether the same change is needed in `../simula-ad-sdk-kotlin` and say so in your summary.
