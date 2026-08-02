// No platform guard: pure policy, unit-tested on macOS (the coordinator itself is iOS-only).
import Foundation

/// Maximum reload-after-termination recoveries per creative (iOS-6). CUMULATIVE, never reset:
/// a creative that loads and then repeatedly kills its web-content process (memory bomb,
/// repeated OS jettison while backgrounded) gets at most this many recoveries, ever — the old
/// one-shot flag reset on every clean load and let such a creative cycle forever.
let maxRenderRecoveries = 3

/// Backoff before re-issuing the creative after a web-content-process termination:
/// 1 s, 2 s, 4 s for attempts 1–3 (clamped for out-of-range inputs). The immediate reload it
/// replaces let a crash-looping creative churn WebContent processes back-to-back.
func renderRecoveryBackoff(attempt: Int) -> TimeInterval {
    let clamped = min(max(attempt, 1), maxRenderRecoveries)
    return pow(2.0, Double(clamped - 1)) // 1, 2, 4
}

/// Returns the next recovery attempt only when there is content to reload and budget remains.
/// Keeping this decision pure prevents a renderer termination before the first real load from
/// consuming one of the creative's cumulative recovery attempts.
func nextRenderRecoveryAttempt(currentCount: Int, hasReloadableContent: Bool) -> Int? {
    guard hasReloadableContent, currentCount < maxRenderRecoveries else { return nil }
    return max(currentCount, 0) + 1
}
