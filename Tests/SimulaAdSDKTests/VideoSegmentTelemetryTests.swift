import XCTest
@testable import SimulaAdSDK

final class VideoSegmentTelemetryTests: XCTestCase {
    private let segments = [VideoSegment(clipIndex: 1, videoPool: "A", startSeconds: 0, endSeconds: 4),
                            VideoSegment(clipIndex: 2, videoPool: "B", startSeconds: 4, endSeconds: 10)]

    func testStitchBoundariesHaveLocalPositionDurationAndWatch() {
        var state = VideoSegmentTelemetryState()
        var events = state.update(segments: segments, position: 0, played: 0, muted: false)
        events += state.update(segments: segments, position: 2, played: 2, muted: false)
        events += state.update(segments: segments, position: 6, played: 6, muted: true)
        events += state.update(segments: segments, position: 10, played: 10, muted: false)
        XCTAssertEqual(events.map(\.stage), ["video_start", "video_duration", "video_complete", "video_start", "video_duration", "video_complete"])
        let completes = events.filter { $0.stage == "video_complete" }
        XCTAssertEqual(completes.map(\.segment.clipIndex), [1, 2])
        XCTAssertEqual(completes.map(\.duration), [4, 6])
        XCTAssertEqual(completes.map(\.position), [4, 6])
        XCTAssertEqual(completes.map(\.mutedSeconds), [2, 2])
        XCTAssertEqual(completes.map(\.unmutedSeconds), [2, 4])
        XCTAssertTrue(state.update(segments: segments, position: 10, played: 10, muted: false).isEmpty)
        XCTAssertTrue(state.update(segments: segments, position: 3, played: 10, muted: false).isEmpty)
    }

    func testWatchDoesNotCountUnsampledSeekGapAndStateIsBounded() {
        var state = VideoSegmentTelemetryState()
        let events = state.update(segments: segments + segments + segments, position: 10, played: 1, muted: false)
        XCTAssertLessThanOrEqual(events.count, 9)
        XCTAssertEqual(events.first { $0.stage == "video_complete" }?.unmutedSeconds ?? -1, 0.4, accuracy: 0.00001)
        XCTAssertTrue(state.update(segments: segments, position: .nan, played: 1, muted: false).isEmpty)
    }
}
