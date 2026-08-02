# Simula SDK — Reliability and Telemetry Plan

Single source of truth for the cross-SDK reliability program. Keep this file byte-identical
in all three repositories (`simula-ad-sdk-swift`, `simula-ad-sdk-kotlin`,
`simula-ad-sdk-react-native`); verify with
`shasum -a 256 docs/SDK_IMPROVEMENT_PLAN.md`.

Last updated: 2026-08-01 (merged from the v1 plan and the v2 post-audit revision).

## Scope rule (owner direction, 2026-08-01)

This plan contains **only work that is fully client-side**. Anything requiring backend
changes/approvals or external privacy/product sign-off is **removed — not deferred, not
tracked**. Removed: Swift CDN asset label (backend label approval); wiring
`allowsPrimaryUserID` (privacy/product, backend-affecting); all v3 field emission incl.
`schema_version: 3` (backend ingestion approval — i.e. old Phase 2 and the new-field portions
of crash/perf phases); aggregate-only `anr_other` (privacy review); `telemetryCohort`
(backend cardinality + privacy). No SDK emits v3 fields.

## Incident summary (program origin)

The reported 5.2–6.0 s main-thread hang came from React Native 1.3.7 with Swift SDK 1.1.5:
`SimulaAdsModule.initialize → SimulaAds.initialize → SimulaDeviceId.value →
UIDevice.identifierForVendor` (synchronous LaunchServices XPC). Swift 1.1.6 removed the IDFV
lookup from synchronous initialization; React Native 1.3.8 pinned it and removed JS device-ID
work from initialization. The program below closed the residual getter paths, established the
shared telemetry contract, fixed entry-path parity, and hardened against the crash/hang
classes found by two subsequent audits.

## Phase 0/1 record (completed)

- **Swift 1.1.7**: nonblocking lock-protected IDFV cache (`deviceId` returns nil while
  pending; UA fallback while resolving); IDFV/UA resolution only in deferred startup;
  identity headers moved to per-request `makeHeaders` (read live); IDFV memory-only;
  telemetry route normalization (fail-closed); XCFramework version stamping/validation.
- **Kotlin 1.1.6**: one process-wide telemetry/crash startup engine shared by imperative and
  declarative paths; Compose registration in committed `LaunchedEffect`; provider startup
  gates (privacy attach, telemetry readiness, GAID, beacon manager); atomic session+PPID
  identity pair; hidden pre-1.1.6 Compose JVM-descriptor bridge; async nonblocking Android ID
  with request-path retry + 30 s cooldown; same route matrix as Swift.
- **React Native 1.3.9**: pins iOS `SimulaAdSDK "1.1.7"` and Android `ad.simula:ad-sdk:1.1.6`
  exactly; `deviceId()` documented as nonblocking snapshot; init never invokes `getDeviceId`
  (test); stale `dist/internal/ipv4Beacon` removed; `android/build/` excluded from npm.
- Verification at the time: Swift 265 tests, Kotlin 276 tests (32 suites), RN 41 jest tests;
  contract/fixture byte-identical (hashes above).

## Post-audit corrective rounds (completed 2026-08-01)

A full three-repo code audit of Phase 0/1, then implementation of its findings:

- **B1-1 (Kotlin crash-guard gating)**: the startup engine installed the crash guard via
  `withContext(Dispatchers.Main)` *inside* the awaited gate — a wedged main thread would
  stall all ad loads. Fixed with `TelemetryStartupEngine.runUngated` (install strictly after
  telemetry, never awaited by the gate) + stalled-main regression test.
- **B1-2 (false "consent-gated PPID" comments, both platforms)**: corrected to actual
  behavior (PPID re-read live at flush, never consent-gated; consent/COPPA gate the
  advertising id only). `allowsPrimaryUserID` exists but is unwired — stays so (scope rule).
- **B1-4 (Swift identity retry gap)**: `SimulaDeviceIdCache` 30 s retry cooldown +
  `SimulaDeviceId.retryIfNeeded()` nudged from `makeHeaders` — off-main, single-flight
  (Kotlin parity). 5 tests.
- **B2 hygiene**: stale "UA/IDFV headers" and `/v1/telemetry/events` comments fixed;
  `telemetryEnabled` first-registration-wins documented (KDoc + README); provider coroutine
  no longer retains the composition Activity; RN README Diagnostics section + absolute
  contract link.
- **Phase 3 remnant (Kotlin watermark)**: `ExitSweepOutcome` + pure `sweepWithWatermark` — a
  transient ApplicationExitInfo read failure no longer advances the watermark (records were
  silently lost). 6 tests.
- **Phase 4 remnants**: startup-prewarm memory policy (Android `isLowRamDevice`; iOS 2 GiB
  floor via `WebViewPrewarmPolicy`; existing logging only, normal pooling never gated);
  `TelemetryBackgroundFlush` (Swift process-wide app-background flush; Kotlin flush paths
  verified idempotent); `GIFImage` routed through `SimulaAPI.shared.session` (last
  `URLSession.shared` deviation removed — asset hosts fail-close to `/unknown`).

## External crash & hang audit (2026-08-01)

An external audit ("Simula SDK — Crash & Hang Audit") was re-verified finding-by-finding
against current source. Already fixed by the rounds above: AND-3, AND-8, iOS-9 (and parts of
AND-2 / iOS-5 / RN-2). Severity adjustments recorded: RN-2 → MEDIUM (one `main.sync`, bounded
10 s stall); AND-2 → MEDIUM-HIGH (reward-queue half already fixed); AND-11 → LOW at the
pinned BOM; RN-8 / iOS-7 → LOW-MEDIUM. Confirmed findings became Phases 5–8.

### Phase 5 — Input & payload hardening — DONE

| Finding | Fix |
|---|---|
| iOS-1 `bid_amt` Int64 trap at paid event | `Int64(exactly:) ?? 0` in `AdValue.fromBidCpm` + regression tests |
| iOS-2 `skoverlay.delay_seconds` UInt64 multiply trap | `maxSKOverlayDelaySeconds = 45` clamp in both `SKOverlayConfig` init paths + decode tests |
| iOS-8 `autoCloseDuration: .infinity` trap | `MiniGameInvitation.sanitizedAutoCloseDuration` (isFinite guard) + tests |
| AND-1 `SET_ORIENTATION` crash on Android 8.0 translucent activity | `AndroidBridgeHost.setOrientation`: skip on API 26 + `runCatching` everywhere |
| AND-7 unguarded creative-bridge dispatch | `CreativeBridge.handle` wraps `process()` in try/catch → `Telemetry.recordError("bridge:creative_dispatch")` + regression test |
| RN-1 Android `@ReactMethod` crashes on null/mistyped props | `guard` crash barrier wraps every `@ReactMethod` (26 + 13) → reject/log; null-safe boolean reads on consent/devMode paths |
| RN-3 non-optional bridge strings trap on JS null | Optional-param relaxation + reject/log on both bridges (`checkFrequencyCap`, `destroyPreloadedAd`, `createInterstitial`, `createRewarded`); JS wrappers throw loud `TypeError` (`SimulaBaseAd`, `checkFrequencyCap`, `destroyPreloadedAd`) + tests |
| RN-4 `JSON.stringify(hostObject)` during provider render | `safeStringify` (stable fallback) for both effect-identity keys + tests (circular, BigInt, throwing `toJSON`) |

Gates: Swift 283 tests, Kotlin full suite + bridge regression, RN 49 jest tests + `tsc` —
all green.

**Logging rule (2026-08-01, owner directive):** no console logging — operational signals go
to telemetry (`recordOperation`/`recordError`); dev-mode mirrors are the only sanctioned
console output, and where no telemetry surface exists (the RN bridge) the JS layer surfaces
the error. Codified in Swift/Kotlin `AGENTS.md` hard rules and the non-goals below; applied
retroactively to this program's additions (prewarm-skip now records `webview_prewarm` with
`outcome=skipped;reason=…` in the existing breadcrumb field on both platforms; RN bridge
guard/param logs removed).

### Phase 6 — Wedge & deadlock elimination — DONE (2026-08-01)

| Finding | Fix |
|---|---|
| iOS-3 `isPresentingExternal` wedge (permanent silent CTA outage) | `WeakPresentationSlot<UIViewController>` replaces the static bool — a sheet destroyed without its dismissal delegate firing (window teardown, host VC dismissed under the sheet, StoreKit swipe-down miss) self-clears. 3 tests |
| AND-5 wedged GAID bind deadlocks all ad loads | `raceGaidRead` (8 s): the caller's suspension carries the timeout, not the non-cancellable binder thread — mutex freed, TTL stamps even on timeout (throttles retries), `privacy:gaid_read_timeout` telemetry. Plus `awaitStartupGate` (15 s) fail-open on `ensureSession`'s gate + `session:startup_gate_timeout`. 7 tests |
| AND-6 dropped `startActivity` bricks the ad + leaks the listener | `armLaunchWatchdog` (3 s) on both interstitial and rewarded: Activity claims the handoff in `onCreate` (`launchClaimed`); unclaimed → remove handoff, restore `State.Ready` (the ad never displayed), fire `onAdFailedToDisplay(NoPresentationContext)`. A late Activity reads a null token and finishes itself. 3 tests |
| RN-2 `invalidate()` `main.sync` freezes the JS thread (10 s cap) | `syncOnMain` deleted; `_didInvalidate`/`_hasListeners` now lock-guarded and written on `moduleQueue` (observers never hop); teardown via `runOnMain` async |
| RN-5 `MainActor.assumeIsolated` = release abort on off-main delegate | `enforceMain` (sync on main, async hop otherwise) wraps all five `emit*` helpers in one hop, preserving the guard→mutate→emit ordering; `noteLifecycle`'s `assumeIsolated` is now reachable only on-main |
| RN-6 stranded bridge promises (dropped completions) | iOS `SimulaOnceResolver` one-shot guard on `checkFrequencyCap`, `preloadNativeAd`, `requestTrackingAuthorization`, MiniGame `preload`/`createSession`; JS `withTimeout` (10 s) on `checkFrequencyCap` (→ false), `preloadNativeAd` (→ null), both ATT queries (→ "unavailable"). 5 tests |

Gates: Kotlin full suite (incl. `SimulaSessionStoreGateTest` 4/4, `GaidReadRaceTest` 3/3,
`LaunchWatchdogTest` 3/3); RN 54 jest tests + `tsc`; Swift gate covered iOS-3 (286 tests).

### Phase 7 — Queue durability & resource bounds — DONE (2026-08-01)

| Finding | Fix |
|---|---|
| AND-2 billing queues: uncapped single-JSON-blob SharedPreferences, O(n²) drain, QueuedWork ANR | `AdBeaconQueue` rewritten: in-memory cache (one lazy load), cap 200 drop-oldest + `beacon:queue_overflow` telemetry, ONE batched persist per drain pass. Both stores migrated to new `SqliteBeaconStore` / `SqliteVerificationStore` (WAL, row-level, 24h TTL prune, one-time legacy-prefs migration — mirrors `SqliteTelemetryStore`). `RewardVerificationManager` capped (200) + `reward:queue_overflow`. 3 regression tests (cap ×2, batch persist) |
| iOS-4 same class in Swift | Same treatment on both Swift queues (`AdBeaconManager`, `RewardVerificationManager`): in-memory cache, cap 200 + telemetry, 24h TTL prune at load (legacy rows stamped: baseline = last attempt or now), one batched persist per pass on a serial utility queue (`performPersist`, sync in tests), `UncheckedSendableDefaults` box for Swift-6 captures. 6 tests (cap ×2, TTL prune ×2, legacy stamping, batched write counting) |
| AND-10 per-error SQLite txn + eager flush chain | `recordError`: a repeat of an already-aggregated signature now only bumps the count in memory — durable save + eager flush remain for FIRST-seen signatures. +1 test (no save/no flush on repeat, count preserved) |
| iOS-5 GIF decode spikes | Preload fan-out bounded to 3 (`chunks`); per-decode budget 24 MB (truncate, durations folded); cache ceiling 96 → 32 MB. Worst transient now 3 × 24 MB (was unbounded). 2 tests (chunking) |
| iOS-6 render-recovery loop | `renderRecoveryAttempted` (reset per load) → cumulative `renderRecoveryCount` (never reset, cap 3) + backoff 1/2/4 s (`renderRecoveryBackoff`). 3 tests |
| AND-9 uncapped attached WebViews | Process-wide budget `MAX_ATTACHED_NATIVE_WEBVIEWS = 8` with counted `markAttached`/`markDetached` transitions; over budget → zero-cost blank `View` + `nativead:attached_budget` (count aggregates). `release` handles the blank |
| iOS-7 `persistQueue.sync` QoS inversion on the cooperative pool | `completeFlush` now persists async (serial queue preserves ordering; the reconcile already landed under lock). Sync durability stays on the app-background path (`persistNow`) |
| RN-8 per-tap URLSession leak | `finishTasksAndInvalidate()` on the redirect-resolution session in `endResolving` and `resetLinkHandlingState` (outside the lock) |

Gates: Kotlin full suite (incl. cap ×2, batch, AND-10 repeat-signature tests); Swift **297 tests,
0 failures**; RN 54 jest + `tsc`.

### Phase 8 — Diagnostics & hygiene — DONE (2026-08-01)

| Finding | Fix |
|---|---|
| AND-12 `SimulaScope` swallowed uncaught failures to Logcat only | Console log removed; handler invokes injected `uncaughtExceptionReporter`, wired by `Telemetry.initialize` to `recordError("scope:uncaught")`. Failures remain terminally consumed (host never crashes), supervisor stays active. 2 tests |
| Swift off-main `UIDevice` battery reads (AGENTS.md violation) | `SimulaDeviceSignals` starts/reads `BatteryMonitor`'s lock-guarded main-thread snapshot; `BatteryInfo` carries `stateRaw` for `X-Battery-State`. No direct battery read remains on the utility queue |
| Kotlin interstitial preview before init crashed in Activity content | `showPreview` now mirrors rewarded: `SimulaAds.isInitialized` guard → `NotInitialized` failure |
| Kotlin retained native-ad wiring held dead composition closures | `NativeAdWiring.clearCallbacks()` clears height/click/load/render/page callbacks on every real WebView release; recomposition hot-swaps them back on reattach |
| Kotlin idle WebView pool destroyed on every app background | `shouldTrimIdlePool`: excludes `TRIM_MEMORY_UI_HIDDEN`, still trims on real pressure levels. 3 tests |
| Both privacy listeners reacted to every host preferences write | Kotlin filters by the six exact IAB keys (or bulk/null callback) via tested `shouldRecomputePrivacy`. Swift's keyless `UserDefaults.didChangeNotification` now compares a normalized six-value IAB fingerprint and recomputes only when it changed; dynamic post-init IAB update test added |
| Swift carousel `CADisplayLink` lived until spring settle/deinit | `MobileCarouselView.onDisappear` calls `animator.stopAnimation()` immediately |
| Legacy operational console output contradicted the logging rule | Swift `initialize`, SKOverlay, and native-preload signals now use telemetry; Kotlin invalid-key/provider/preload warnings now use telemetry; RN JS expected no-op/catch paths are silent (RN must not duplicate native telemetry). Source scan leaves only the explicit dev-mode native telemetry mirrors |

Gates: Kotlin full suite (incl. `SimulaScopeTest` 2/2, `WebViewPoolTrimTest` 3/3,
IAB-key predicate); Swift **298 tests, 0 failures**.

**Infrastructure follow-up (not SDK code):** AND-11 still needs a dedicated compatibility
host + emulator CI lane that runs the SDK (compiled at its pinned Compose BOM) against the
newest stable host BOM. The Kotlin repo currently has no sample/compat host module, so this is
kept as a release-infrastructure task rather than falsely marked complete here. The ad-serving
kill-switch idea remains out of scope (product/monetization semantics).

## Release sequence for Phase 1 (pending)

Step 0 (committed + CI green on `dev`) is satisfied. In order:

1. Swift CI: Debug, optimized (`-O`), iOS Simulator, and library-evolution lanes.
2. Build Swift 1.1.7 through the pinned release workflow (not a local build).
3. Generate the binary Swift package manifest with the **workflow** checksum.
4. Tag and publish Swift 1.1.7; publish the 1.1.7 CocoaPod.
5. Validate Swift 1.1.7 in the demo/host app; record the final binary UUID.
6. Merge and publish Kotlin 1.1.6 to Maven Central; resolve from a clean external Gradle host.
7. Build React Native 1.3.9 in clean iOS/Android host apps using the published natives;
   verify `Podfile.lock` and Gradle resolution contain the exact versions.
8. Publish React Native 1.3.9 to npm; install the tarball into a clean host and smoke test.

Do not publish React Native before both native versions are publicly resolvable.

**Rollout checks**: verify the loaded Swift binary UUID (not just the version string); the old
`initialize → SimulaDeviceId.value → identifierForVendor` signature is zero;
`SimulaAds.deviceId()` returns promptly at startup; later requests gain `X-Device-Id` after
background resolution; provider-only Kotlin integrations emit telemetry and install
crash/exit capture; blank-Android-ID retries ≤ 1 per cooldown window; telemetry paths carry
`/impressions/:id/seen`-style templates, never raw IDs.

## Parity matrix (current client-side state)

| Contract rule / behavior | Swift | Kotlin | RN |
|---|---|---|---|
| Route templates (`/impressions/:id/*`, `/load/fallbacks/:id`) | ✅ + tests (full allowlist) | ✅ + tests | n/a (no JS telemetry) |
| Drop telemetry-delivery and PPID routes | ✅ + tests | ✅ + tests | n/a |
| Fail-closed unknown → `/unknown` | ✅ + tests | ✅ + tests | n/a |
| Device-ID resolution: async, memory-only | ✅ | ✅ | n/a (forwards) |
| Device-ID request-path retry + 30 s cooldown | ✅ | ✅ | n/a |
| Nonblocking `deviceId` getter | ✅ | ✅ | ✅ (+ test) |
| Identity headers read live per request | ✅ + test | ✅ + test | n/a |
| Crash-guard install never gates ad requests | ✅ | ✅ (`runUngated`) | n/a |
| Startup engine shared by imperative + declarative | n/a (single init path) | ✅ + tests | n/a |
| PPID re-read live at flush, not consent-gated | ✅ (documented) | ✅ (documented) | n/a |
| ApplicationExitInfo watermark survives transient failures | n/a | ✅ + tests | n/a |
| Startup prewarm memory policy | ✅ (2 GiB floor) | ✅ (`isLowRamDevice`) | n/a |
| App-background telemetry flush | ✅ (`TelemetryBackgroundFlush`) | ✅ (imperative + provider) | n/a |
| Bridge dispatch crash barrier | n/a | ✅ (`CreativeBridge` try/catch) | ✅ (Android `guard`; iOS coerces) |
| Host-input validation at bridge (non-empty strings) | n/a (native API) | n/a (native API) | ✅ (JS `TypeError` + optional native params) |

Known accepted divergence (out of scope per the scope rule): Kotlin emits the contract's
`"cdn"` asset label; Swift does not — Swift asset traffic fail-closes to `/unknown`, which
stays compliant with the "never a per-asset path" prohibition.

## Explicit non-goals

- Do not persist IDFV or Android ID without a separate demonstrated requirement.
- Do not upload raw host stacks or top-frame host binary names by default.
- Do not duplicate native network telemetry in React Native JavaScript.
- Do not add per-scroll telemetry.
- Do not await full startup/session creation from device-ID getters.
- Do not classify app suspension from dual-clock divergence alone.
- Do not implement the Swift CDN label or wire `allowsPrimaryUserID` (external approval).
- Do not emit any v3 field (including `schema_version: 3`).
- Do not change Kotlin `telemetryEnabled` engine semantics in a patch release; doc-only.
- Do not couple any ad-request gate to a main-thread hop.
- Do not publish any artifact from an uncommitted tree.
- Do not use console logging (`print` / `NSLog` / `Log.*` / `console.*`) — operational
  signals go to telemetry (`recordOperation` / `recordError`); dev-mode mirrors are the only
  sanctioned console output. Where no telemetry surface exists (the RN bridge), fail silently
  natively and surface the error to JS (rejected promise / thrown `TypeError`).
