---
name: swift-concurrency-task-shape
description: >-
  Concurrency rules for this SDK: launch and ad paths run on GCD (never
  Swift Concurrency) because affected host toolchains abort task teardown
  ("freed pointer was not the last allocation"); the few surviving Task
  sites must keep a constrained shape. Apply when writing or reviewing any
  code using Task {}, Task.sleep, MainQueueTimer, DispatchQueue hops, or when
  investigating SIGABRT crashes in swift_task_dealloc / completeTaskWithClosure.
---

# Swift Concurrency Task Shape

This SDK ships as **source** (CocoaPods/SPM) and is compiled by each host app's
own Xcode, then linked into a binary full of other vendors' Swift. In that
environment, optimized (`-O`) Swift Concurrency code aborts at task teardown in
some hosts:

```
libswift_Concurrency  swift_Concurrency_fatalError        ("freed pointer was not the last allocation")
libswift_Concurrency  StackAllocator::dealloc / swift_task_dealloc (or _swift_task_dealloc_specific)
<app binary>          <deduplicated_symbol>                (folded async thunk)
libswift_Concurrency  completeTaskWithClosure              (or asyncLet_finish_after_task_completion)
```

Our code is valid Swift — the defect is toolchain-level — and it is **not**
shape-fixable: a production host still crashed after every Task body here was
reduced to a single call (July 2026, Character AI, Xcode 26.6). Two upstream
mechanism classes fit the evidence:

1. **Optimizer dealloc reordering** — `swift_task_alloc`/`swift_task_dealloc`
   were annotated `ArgMemOnly` in LLVM IR, letting passes move task-frame
   deallocs across suspension points in ANY optimized async code (forums
   thread "Fix for async let teardown ordering crash", PR #87571; partially
   fixed ~Swift 6.3.1/Xcode 26.4.1, still reproducing after — see #87481).
2. **Divergent copies of `@_alwaysEmitIntoClient` concurrency APIs**
   (`Task.init`, `Task.detached`, `MainActor.run`, `Task.sleep(for:)`) —
   every module carries its own copy; the linker keeps one per symbol name,
   and copies from prebuilt static SDKs built with OTHER toolchains can
   diverge from what the survivor's callers assume (swiftlang/swift#86204,
   #84793 — the latter needs a prebuilt static Swift dependency, exactly the
   ad-SDK-zoo composition of our hosts).

**Attribution caveat:** async partial-apply teardown thunks call their closure
via a context-loaded function pointer (no static relocation), so the linker
folds byte-identical thunks from EVERY module to one address. The symbol name
on the crashing frame (`<deduplicated_symbol>`, or a random vendor's closure
after dSYM symbolication) identifies the **fold winner, not the dying task's
owner**. Attribute ownership behaviorally (which feature flag / surface gates
the crash), and use `dwarfdump --lookup <offset>` on the host dSYM to list all
folded candidates.

## Rules

1. **Launch-path and ad-path work runs on GCD, never Swift Concurrency.**
   No task ⇒ no task teardown ⇒ this crash class is structurally unreachable,
   regardless of which upstream mechanism a host tickles.
   - Telemetry flush engine: serial `flushQueue` + `asyncAfter` backoff
     (`TelemetryManager`), completion-based `TelemetrySending` /
     `SimulaAPI.postTelemetry`.
   - `Ipv4Beacon`: completion-based sender.
   - Main-thread hops around synchronous `@MainActor` work:
     `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` — the
     dispatch guarantees main before the cast, so it can never trap.
   - Sleep-then-act and tick timers: `MainQueueTimer` (GCD one-shot/repeating
     with generation-token cancellation), held in `@State` on SwiftUI
     surfaces, cancelled in `.onDisappear`.

2. **The surviving `Task` sites are value-producing async chains only**
   (session create/ensure, ad load, prefetch-await-present, SwiftUI `.task`
   lifecycle modifiers, the reward-verification manager). Keep their closure
   bodies to a **single call into a named method** with minimal captures.

3. **Never `try?`/`try!` around an `await`** — explicit `do/catch` only.
   (CI greps enforce this and rule 4.)

4. **No `async let`.** The SDK contains zero — keep it that way.

5. **`Task.sleep(nanoseconds:)` only, never `Task.sleep(for:)` /
   `sleep(until:)`** — the `for:`/`until:` variants are generic
   `@_alwaysEmitIntoClient` stdlib functions that mint per-module copies (the
   #86204 trigger); `nanoseconds:` is a single dylib entry point. Inside SDK
   code prefer `MainQueueTimer`/`asyncAfter` over any sleep (rule 1); the
   remaining sleeps live in the surviving async chains of rule 2.

6. **No continuations** (`withCheckedContinuation` etc.) — bridge
   delegate/completion callbacks with one-shot-guarded closure registries
   (see `RewardVerificationManager.invokeCallback`, `RedirectResolver.finish`).

## Recognizing a report of this crash

SIGABRT with `swift_task_dealloc` → `fatalError` → `completeTaskWithClosure`
(main or pool thread) ⇒ this bug class, not a data race or double-resume.
Collect: (a) exact Xcode/linker that built the app and pod/app
`SWIFT_OPTIMIZATION_LEVEL` (incl. Podfile `post_install` overrides, `-Osize`,
LTO); (b) which feature flags / surfaces gate it behaviorally; (c) the host
dSYM + slide-corrected crash offset, then `dwarfdump --lookup <offset>` for
the full folded-candidate list (plain `atos` shows only
`<deduplicated_symbol>`); (d) the host's prebuilt static Swift dependencies
(`nm -m <app binary> | grep '_$sScT'` surfaces foreign-toolchain concurrency
weak symbols); (e) a `-Wl,-no_deduplicate` Release build — if the crash
persists, the frame gains a real name (diagnostic, not a fix).

## History / upstream references

- Forums "Fix for async let teardown ordering crash" / PR #87571 — the
  `ArgMemOnly` dealloc-reordering diagnosis (applies beyond `async let`);
  partial fix ~6.3.1/Xcode 26.4.1, #87481 still reproducing after.
- swiftlang/swift#86204 — multi-module `Task.sleep(for:)` specialisation
  copies, same abort signature (open).
- swiftlang/swift#84793 — same message, Xcode 26, requires a prebuilt static
  Swift dependency; reproduces even in Debug (so `-no_deduplicate`/ICF is not
  the root cause; folding only NAMES the frame).
- swiftlang/swift#81771 (`async let` in `do{}`) / #75501 (umbrella).
- Precedent: Firebase 12.12.0 (`HTTPSCallable.call`) shipped a source-level
  workaround; the interim community mitigation was per-pod `-Onone`.
- July 2026, Character AI (RN 0.77 old arch): crashed at launch (100%,
  gated by `telemetryEnabled`) and at native-ad show; single-line-Task
  refactor did NOT fix; frame folded at one offset across both crashes,
  dSYM-named to a Meta Audience Network thunk (fold winner — see the
  attribution caveat). Led to the rule-1 GCD conversion in 1.1.4.
