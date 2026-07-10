import Foundation

/// Dev-only canary module (never shipped; see Package.swift). Spawns the Swift Concurrency
/// shapes common to ad SDKs so a Release-mode (-O) test link carries MULTIPLE modules'
/// byte-identical async thunks and `@_alwaysEmitIntoClient` stdlib copies — the multi-SDK
/// host composition under which affected toolchains abort at task teardown ("freed pointer
/// was not the last allocation" in `swift_task_dealloc`). Deliberately byte-identical to its
/// sibling zoo module (maximum linker fold / same-name-coalesce pressure), and deliberately
/// includes shapes BANNED in `Sources/` (multi-statement bodies, `MainActor.run`,
/// `Task.detached`) — foreign SDKs' shapes are outside our control, so the canary must
/// exercise them. Full rationale: .cursor/skills/swift-concurrency-task-shape/SKILL.md.
public final class SimulaCanaryZooA: @unchecked Sendable {
    public static let shared = SimulaCanaryZooA()

    private let lock = NSLock()
    private var completed = 0

    public init() {}

    /// Number of exercised tasks whose bodies (and therefore teardowns) have finished.
    public var completedCount: Int { lock.lock(); defer { lock.unlock() }; return completed }

    /// Spawn `count` tasks across the common shapes; each bumps `completedCount` exactly once.
    /// The abort under test fires AT task teardown, so the canary's pass condition is simply
    /// that all tasks complete without the process dying.
    public func exercise(count: Int) {
        for i in 0..<count {
            switch i % 4 {
            case 0:
                Task { [weak self] in await self?.noopAsync() }
            case 1:
                Task { @MainActor [weak self] in self?.noopMain() }
            case 2:
                Task { [weak self] in await self?.sleepBriefly() }
            default:
                // The multi-statement detached shape hosts write (banned in Sources/ — the
                // zoo exists to emit exactly what we can't lint away in other vendors).
                Task.detached { [weak self] in
                    guard let self else { return }
                    await self.noopAsync()
                }
            }
        }
    }

    private func noopAsync() async {
        // `MainActor.run` is @_alwaysEmitIntoClient — every module mints a copy (on purpose here).
        await MainActor.run { self.noopMain() }
    }

    @MainActor
    private func noopMain() {
        bump()
    }

    private func sleepBriefly() async {
        do { try await Task.sleep(nanoseconds: 1_000_000) } catch {}
        bump()
    }

    private func bump() { lock.lock(); completed += 1; lock.unlock() }
}
