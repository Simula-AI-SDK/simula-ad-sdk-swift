import Foundation

/// Cancellable one-shot / repeating scheduling on the main queue, backed by GCD — the SDK's
/// replacement for `Task {}` + `Task.sleep` timers on ad and launch paths.
///
/// WHY GCD: affected Swift toolchains (6.1–6.3, Xcode 16.3 through at least 26.x) miscompile
/// optimized async code into task-teardown aborts inside host apps ("freed pointer was not the
/// last allocation" in `swift_task_dealloc` / `completeTaskWithClosure`). A dispatch work item
/// never touches the Swift Concurrency task allocator, so timers built on this type are
/// structurally outside that crash class. See the concurrency note in `TelemetryManager` and
/// .cursor/skills/swift-concurrency-task-shape/SKILL.md.
///
/// Semantics (mirroring the `Task` handles it replaces in the SwiftUI surfaces):
/// - `schedule(after:)` / `tick(every:)` arm the timer; re-arming or `cancel()` invalidates
///   anything still pending via a generation token — a stale fire is dropped on arrival, the
///   moral equivalent of the old `Task.isCancelled` checks.
/// - `isArmed` answers "is a fire pending" (replaces the old `xxxTask == nil` re-entry guards).
/// - Main-actor only: fires are delivered on `DispatchQueue.main` and run isolated; the
///   dispatch guarantees main before the isolation cast, so the cast can never trap.
/// - Dropping the last reference cancels implicitly (pending fires hold `self` weakly).
@MainActor
final class MainQueueTimer {
    /// Bumped to invalidate pending fires; a fire captured with an older generation is dropped.
    private var generation = 0
    private(set) var isArmed = false

    /// `nonisolated` so the type can be a `@State` default value (View property initializers
    /// run nonisolated); all mutable state is touched only from the main actor afterwards.
    nonisolated init() {}

    /// One-shot: run `fire` on the main actor after `seconds` (clamped to ≥ 0).
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        generation &+= 1
        let gen = generation
        isArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.isArmed = false
                fire()
            }
        }
    }

    /// Repeating: run `tick` on the main actor every `interval` until `cancel()` or a re-arm.
    /// The next tick is scheduled AFTER the body returns (fixed delay between runs, matching
    /// the `while { sleep; work }` loops this replaces).
    func tick(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        generation &+= 1
        isArmed = true
        scheduleTick(interval: max(interval, 0.001), generation: generation, tick)
    }

    func cancel() {
        generation &+= 1
        isArmed = false
    }

    private func scheduleTick(interval: TimeInterval, generation gen: Int, _ tick: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                tick()
                // The body may have cancelled or re-armed; continue this chain only if it didn't.
                guard self.generation == gen else { return }
                self.scheduleTick(interval: interval, generation: gen, tick)
            }
        }
    }
}
