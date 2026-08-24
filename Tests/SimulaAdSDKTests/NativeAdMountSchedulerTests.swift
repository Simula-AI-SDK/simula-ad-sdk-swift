import XCTest
@testable import SimulaAdSDK

@MainActor
final class NativeAdMountSchedulerTests: XCTestCase {
    private final class ManualFrameClock {
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waiterCount: Int { waiters.count }

        func waitForFrame() async {
            await withCheckedContinuation { waiters.append($0) }
        }

        func advance() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }
    }

    @MainActor
    private final class AdmissionRecorder {
        private(set) var values: [Int] = []
        private(set) var cancellationResult: Bool?

        func append(_ value: Int) { values.append(value) }
        func recordCancellation(_ admitted: Bool) { cancellationResult = admitted }
    }

    func testMountTaskIdentityChangesWhenAdmissionChangesForSameResponse() {
        let response = NativeAdResponse(
            impressionId: "impression-1",
            adInserted: true,
            adFormat: "character_ad",
            iframeUrl: "https://example.com/creative",
            renderedHtml: "<html>creative</html>"
        )

        XCTAssertNotEqual(
            nativeAdMountTaskIdentity(response: response, mountAdmitted: false),
            nativeAdMountTaskIdentity(response: response, mountAdmitted: true)
        )
    }

    func testAsyncAdmissionUsesTheSameQueueEngine() async {
        let scheduler = NativeAdMountScheduler(waitForNextFrame: {})

        let admitted = await scheduler.waitForAdmission()
        await scheduler.waitForIdleForTests()

        XCTAssertTrue(admitted)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testAdmitsAtMostOneRequestPerFrameInQueueOrder() async {
        let clock = ManualFrameClock()
        let scheduler = NativeAdMountScheduler(waitForNextFrame: { await clock.waitForFrame() })
        let admitted = AdmissionRecorder()

        scheduler.enqueueForTests { if $0 { admitted.append(1) } }
        await waitUntil { scheduler.pendingCount == 1 && clock.waiterCount == 1 }

        scheduler.enqueueForTests { if $0 { admitted.append(2) } }
        await waitUntil { scheduler.pendingCount == 2 }

        scheduler.enqueueForTests { if $0 { admitted.append(3) } }
        await waitUntil { scheduler.pendingCount == 3 }

        clock.advance()
        await waitUntil { admitted.values == [1] && scheduler.pendingCount == 2 && clock.waiterCount == 1 }
        clock.advance()
        await waitUntil { admitted.values == [1, 2] && scheduler.pendingCount == 1 && clock.waiterCount == 1 }
        clock.advance()

        await scheduler.waitForIdleForTests()
        XCTAssertEqual(admitted.values, [1, 2, 3])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testCancellationRemovesQueuedRequestBeforeAdmission() async {
        let clock = ManualFrameClock()
        let scheduler = NativeAdMountScheduler(waitForNextFrame: { await clock.waitForFrame() })
        let recorder = AdmissionRecorder()

        let request = scheduler.enqueueForTests { recorder.recordCancellation($0) }
        await waitUntil { scheduler.pendingCount == 1 && clock.waiterCount == 1 }

        scheduler.cancelForTests(request)

        XCTAssertEqual(recorder.cancellationResult, false)
        XCTAssertEqual(scheduler.pendingCount, 0)

        // The already-scheduled frame may still arrive, but it must not admit the canceled request.
        clock.advance()
        await scheduler.waitForIdleForTests()
        XCTAssertEqual(recorder.cancellationResult, false)
    }

}
