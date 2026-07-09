---
name: swift-concurrency-task-shape
description: >-
  Required shape for Swift Concurrency Task closures in this SDK to avoid a
  known Swift 6.1–6.3 optimizer miscompilation that aborts host apps at task
  teardown ("freed pointer was not the last allocation"). Apply when writing or
  reviewing any code using Task {}, Task.detached, try? await, Task.sleep,
  async let, or when investigating SIGABRT crashes in swift_task_dealloc /
  completeTaskWithClosure.
---

# Swift Concurrency Task Shape

This SDK ships as **source** (CocoaPods/SPM) and is compiled by each host app's
own Xcode. Swift 6.1–6.3 optimizers (Xcode 16.3 through at least 26.x) can
miscompile certain async-closure shapes into out-of-LIFO-order task-stack
deallocations. The result is a hard `abort()` in the host app at task teardown:

```
libswift_Concurrency  swift_Concurrency_fatalError        ("freed pointer was not the last allocation")
libswift_Concurrency  StackAllocator::dealloc / swift_task_dealloc
<app binary>          <deduplicated_symbol>                (async thunk)
libswift_Concurrency  completeTaskWithClosure              (or asyncLet_finish_after_task_completion)
```

Our code is valid Swift — the bug is in the toolchain — but because hosts
compile us with affected Xcodes, we must avoid the implicated shapes. This
crashed a production host app at startup (telemetry flush tasks, July 2026;
confirmed by the crash disappearing with `telemetryEnabled=false`).

## Rules

1. **Keep `Task {}` closure bodies to a single call into a named method.**

```swift
// Good
Task { [weak self] in await self?.timedFlush() }

private func timedFlush() async {
    do { try await Task.sleep(nanoseconds: delayNs) } catch {}
    await flush()
}

// Bad — multi-statement body with try? await inside the closure
Task { [weak self] in
    guard let self else { return }
    try? await Task.sleep(nanoseconds: delayNs)
    await self.flush()
}
```

2. **Never use `try?` around an `await` inside a Task closure or task body.**
   Use explicit `do/catch`. For `Task.sleep`, the only error is cancellation:

```swift
do { try await Task.sleep(nanoseconds: ns) } catch { return }  // cancelled
```

3. **Do not introduce `async let`.** It is the most-reported trigger
   (especially inside `do {}` blocks, with `try?`, or with large result
   types). Use sequential `await` or a task group instead. The SDK currently
   contains zero `async let` — keep it that way until minimum supported host
   toolchains are confirmed fixed.

4. **Prefer minimal captures** in task closures (`[weak self]` + method call);
   avoid capturing large structs or doing work inline.

## Recognizing a report of this crash

If a host reports SIGABRT with `swift_task_dealloc` → `fatalError` →
`completeTaskWithClosure` (thread can be main or a pool thread): it is this
bug class, not a data race or double-resume. Ask for (a) the Xcode version
that built the app, (b) whether `telemetryEnabled=false` changes behavior,
(c) the dSYM symbolication of the app frame — noting linker dedup
(`<deduplicated_symbol>`) usually makes (c) inconclusive.

## History / upstream references

- swiftlang/swift#81771 — `async let` teardown ordering crash (Swift 6.1+)
- swiftlang/swift#75501 — umbrella "freed pointer was not the last allocation"
- Partial fix shipped in Swift 6.3.1 / Xcode 26.4.1 (`async let` builtins +
  LLVM `ArgMemOnly` correction); other task-stack operations were still
  pending follow-up fixes, and a host on Xcode 26.6 still reproduced it.
- Precedent: Firebase shipped the same source-level workaround (12.12.0,
  `HTTPSCallable.call`); Stripe hit it in Swift 6.3.
