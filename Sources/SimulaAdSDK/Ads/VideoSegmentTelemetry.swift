import Foundation

/// Bounded per-clip accounting for a stitched asset. Retained by the player across surface changes.
struct VideoSegmentTelemetryState: Sendable {
    private var started = [Bool](repeating: false, count: 3)
    private var midpoint = [Bool](repeating: false, count: 3)
    private var completed = [Bool](repeating: false, count: 3)
    private var mutedSeconds = [Double](repeating: 0, count: 3)
    private var unmutedSeconds = [Double](repeating: 0, count: 3)
    private var previousPosition: Double = 0
    private var previousPlayed: Double = 0

    mutating func update(
        segments: [VideoSegment], position: Double, played: Double, muted: Bool
    ) -> [VideoSegmentTelemetryEvent] {
        guard position.isFinite, position >= previousPosition, played.isFinite else { return [] }
        let delta = position - previousPosition
        let watched = min(delta, max(0, played - previousPlayed))
        var events: [VideoSegmentTelemetryEvent] = []
        for (index, segment) in segments.prefix(3).enumerated() {
            let duration = segment.endSeconds - segment.startSeconds
            guard duration.isFinite, duration > 0, position >= segment.startSeconds else { continue }
            if !started[index] {
                started[index] = true
                events.append(VideoSegmentTelemetryEvent(
                    segment: segment, stage: "video_start", position: 0, duration: duration,
                    mutedSeconds: mutedSeconds[index], unmutedSeconds: unmutedSeconds[index]
                ))
            }
            let overlap = max(0, min(position, segment.endSeconds) - max(previousPosition, segment.startSeconds))
            let clipWatch = delta > 0 ? watched * overlap / delta : 0
            if muted { mutedSeconds[index] += clipWatch } else { unmutedSeconds[index] += clipWatch }
            let localPosition = min(duration, max(0, position - segment.startSeconds))
            if !midpoint[index], localPosition >= duration / 2 {
                midpoint[index] = true
                events.append(VideoSegmentTelemetryEvent(
                    segment: segment, stage: "video_duration", position: localPosition, duration: duration,
                    mutedSeconds: mutedSeconds[index], unmutedSeconds: unmutedSeconds[index]
                ))
            }
            if !completed[index], position >= segment.endSeconds {
                completed[index] = true
                events.append(VideoSegmentTelemetryEvent(
                    segment: segment, stage: "video_complete", position: duration, duration: duration,
                    mutedSeconds: mutedSeconds[index], unmutedSeconds: unmutedSeconds[index]
                ))
            }
        }
        previousPosition = position
        previousPlayed = max(previousPlayed, played)
        return events
    }
}

struct VideoSegmentTelemetryEvent: Equatable, Sendable {
    let segment: VideoSegment
    let stage: String
    let position: Double
    let duration: Double
    let mutedSeconds: Double
    let unmutedSeconds: Double
}
