---
name: swift-concurrency-task-shape
description: >-
  Concurrency rules for this SDK. Affected host toolchains abort optimized
  Swift Concurrency at task teardown ("freed pointer was not the last
  allocation"); the primary mitigation is the binary XCFramework distribution
  (1.1.4+), and SDK source keeps a constrained task shape as defense in depth.
  Apply when writing or reviewing any code using Task {}, Task.detached,
  Task.sleep, try? await, async let, or when investigating SIGABRT crashes in
  swift_task_dealloc / completeTaskWithClosure.
---

# Swift Concurrency Task Shape

Host apps embedding this SDK have aborted at task teardown in optimized builds:

```
libswift_Concurrency  swift_Concurrency_fatalError        ("freed pointer was not the last allocation")
libswift_Concurrency  StackAllocator::dealloc / swift_task_dealloc (or _swift_task_dealloc_specific)
<app binary>          <deduplicated_symbol>                (folded async thunk)
libswift_Concurrency  completeTaskWithClosure              (or asyncLet_finish_after_task_completion)
```

Our code is valid Swift — the defect is toolchain-level — and it is **not
reliably shape-fixable**: a production host (Character AI, RN, Xcode 26.6-era,
July 2026) still crashed at launch (gated by `telemetryEnabled`) and at
native-ad render after every Task body in the SDK was reduced to a single call
into a named method.

## Primary mitigation: binary distribution (1.1.4+)

Releases ship a prebuilt, module-stable **XCFramework** — host Xcodes never
compile SDK Swift, so their optimizer cannot miscompile it:

- Built by `.github/workflows/release.yml` with a **pinned Xcode 16.2
  (Swift 6.0.3)** — older than the implicated 6.1–6.3 optimizer window.
- Linked **dynamically**, so the SDK's own copies of `@_alwaysEmitIntoClient`
  concurrency entry points are sealed inside the SimulaAdSDK dylib instead of
  being coalesced with other vendors' copies at app link time (mechanism 2
  below). Bonus: our binary image name appears in crash reports.
- Source builds (the `main` branch) remain exposed on affected host toolchains;
  the interim mitigation there is per-pod `SWIFT_OPTIMIZATION_LEVEL = -Onone`
  via a Podfile `post_install` hook, plus the rules below.

## Upstream mechanisms (two open classes fit the evidence)

1. **Optimizer dealloc reordering** — `swift_task_alloc`/`swift_task_dealloc`
   were mis-annotated `ArgMemOnly` in LLVM IR, letting `-O` passes move
   task-frame deallocs across suspension points in ANY optimized async code
   (forums "Fix for async let teardown ordering crash" / PR #87571; partial
   fix ~Swift 6.3.1 / Xcode 26.4.1, #87481 still reproducing after).
2. **Divergent `@_alwaysEmitIntoClient` copies** of concurrency APIs
   (`Task.init`, `Task.detached`, `MainActor.run`, `Task.sleep(for:)`) —
   every module mints its own copy; the linker keeps one per symbol name, and
   copies from prebuilt static SDKs built by OTHER toolchains can diverge from
   what the survivor's callers assume (swiftlang/swift#86204, #84793 — the
   latter needs a prebuilt static Swift dependency, exactly the ad-SDK-zoo
   composition of our hosts).

## Attribution caveat (reading crash reports)

Async partial-apply teardown thunks call their closure via a context-loaded
pointer (no static relocation), so the linker ICF-folds byte-identical thunks
from EVERY module to one address. The name on the crashing frame
(`<deduplicated_symbol>`, or some vendor's closure after dSYM symbolication)
identifies the **fold winner, not the dying task's owner**. A frame naming
another vendor does NOT exonerate us, and vice versa. Attribute ownership
behaviorally (which feature flag / surface gates the crash) and use
`dwarfdump --lookup <slide-corrected offset>` on the host dSYM to list all
folded candidates.

## Rules for SDK source

These keep `main`-branch/source builds as safe as possible and harden the
binary's own internals; CI lints the mechanical ones:

1. **Launch-path and high-frequency ad-path work runs on GCD, never Swift
   Concurrency.** No task ⇒ no task teardown ⇒ this crash class is
   structurally unreachable there, whichever upstream mechanism a host
   tickles.
   - Telemetry flush engine: serial `flushQueue` + `asyncAfter` backoff
     (`TelemetryManager`); completion-based `TelemetrySending` /
     `SimulaAPI.postTelemetry`. `Ipv4Beacon`: completion-based sender.
     (CI-linted: no task creation in those files.)
   - Main-thread hops around synchronous `@MainActor` work:
     `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` — the
     dispatch guarantees main before the cast, so it can never trap.
   - Sleep-then-act and tick timers on ad surfaces: `MainQueueTimer` (GCD
     one-shot/repeating with generation-token cancellation), held in `@State`
     on SwiftUI surfaces, cancelled in `.onDisappear`.

2. **The surviving `Task` sites are value-producing async chains only**
   (session create/ensure, ad load, prefetch-await-present,
   `NativeAdPreloadCache`, the reward-verification manager, SwiftUI `.task`
   lifecycle modifiers). Keep their closure bodies to a **single call into a
   named method** with minimal captures (`[weak self]` + method call).

```swift
Task { [weak self] in await self?.runLoad(provider: provider) }
```

3. **Never `try?` or `try!` around an `await`** — explicit `do/catch` only.
   For `Task.sleep`, the only error is cancellation:

```swift
do { try await Task.sleep(nanoseconds: ns) } catch { return }  // cancelled
```

4. **No `async let`.** The SDK contains zero — keep it that way.

5. **`Task.sleep(nanoseconds:)` only — never `Task.sleep(for:)` /
   `sleep(until:)`.** The `for:`/`until:` variants are generic
   `@_alwaysEmitIntoClient` functions that mint per-module copies (the #86204
   trigger); `nanoseconds:` is a single dylib entry point. Prefer
   `MainQueueTimer`/`asyncAfter` over any sleep (rule 1); remaining sleeps
   live only in rule-2 chains.

6. **No continuations** (`withCheckedContinuation` etc.) — bridge
   delegate/completion callbacks with one-shot-guarded closure registries
   instead.

## Recognizing a report of this crash

SIGABRT with `swift_task_dealloc` → `fatalError` → `completeTaskWithClosure`
(main or pool thread) ⇒ this bug class, not a data race or double-resume.
Collect: (a) the exact Xcode that built the app and the effective
`SWIFT_OPTIMIZATION_LEVEL` (including Podfile `post_install` overrides, LTO);
(b) the embedded SimulaAdSDK version (binary ≥ 1.1.4 vs source) — a binary
install with our image absent from the crashing frames is not ours;
(c) which feature flags / surfaces gate it behaviorally (`telemetryEnabled`,
ad formats); (d) the host dSYM + slide-corrected offset, then
`dwarfdump --lookup <offset>` for the folded-candidate list (plain `atos`
shows only the fold winner); (e) the host's prebuilt static Swift dependencies
(`nm -m <app binary> | grep '_$sScT'` surfaces foreign-toolchain concurrency
weak symbols).

## History / upstream references

- Forums "Fix for async let teardown ordering crash" / PR #87571 — the
  `ArgMemOnly` dealloc-reordering diagnosis (applies beyond `async let`);
  partial fix ~Swift 6.3.1 / Xcode 26.4.1, #87481 still reproducing after.
- swiftlang/swift#86204 — multi-module `Task.sleep(for:)` specialization
  copies, same abort signature (open).
- swiftlang/swift#84793 — same message, Xcode 26, requires a prebuilt static
  Swift dependency; reproduces even in Debug.
- swiftlang/swift#81771 (`async let` in `do{}`) / #75501 (umbrella).
- Precedent: Firebase 12.12.0 (`HTTPSCallable.call`) shipped a source-level
  workaround; the interim community mitigation is per-pod `-Onone`.
- July 2026, Character AI: crashed at launch (100%, gated by
  `telemetryEnabled`) and at native-ad render on SDK 1.1.3 — i.e. AFTER the
  single-call task-shape refactor — with both TestFlight crashes dying at one
  ICF-folded offset dSYM-named to another vendor's thunk (fold winner; see the
  attribution caveat). Drove the switch to binary distribution in 1.1.4.
