import Foundation
import XCTest
@testable import SimulaAdSDK

final class BoundedURLSessionDataTests: XCTestCase {
    override func tearDown() {
        StreamingResponseURLProtocol.reset()
        super.tearDown()
    }

    func testChunkedResponseAbortsImmediatelyAfterCrossingLimit() async throws {
        StreamingResponseURLProtocol.configure(
            body: Data(repeating: 7, count: 4_096),
            chunkSize: 8
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await boundedURLSessionData(
                for: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/chunked"))),
                using: session,
                maximumBytes: 32
            )
            XCTFail("Expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? BoundedURLSessionDataError, .responseTooLarge)
        }

        await waitUntil { StreamingResponseURLProtocol.stopCount > 0 }
        XCTAssertLessThan(StreamingResponseURLProtocol.deliveredByteCount, 4_096)
    }

    func testChunkedResponseAtTenMiBLimitSucceeds() async throws {
        StreamingResponseURLProtocol.configure(
            body: Data(repeating: 5, count: fullscreenResponseMaximumBytes),
            chunkSize: 64 * 1_024
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await boundedURLSessionData(
            for: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/exact"))),
            using: session,
            maximumBytes: fullscreenResponseMaximumBytes
        )

        XCTAssertEqual(data.count, fullscreenResponseMaximumBytes)
        XCTAssertEqual(data.first, 5)
        XCTAssertEqual(data.last, 5)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testChunkedResponseOneByteOverTenMiBLimitFails() async throws {
        StreamingResponseURLProtocol.configure(
            body: Data(repeating: 6, count: fullscreenResponseMaximumBytes + 1),
            chunkSize: 64 * 1_024
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await boundedURLSessionData(
                for: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/one-over"))),
                using: session,
                maximumBytes: fullscreenResponseMaximumBytes
            )
            XCTFail("Expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? BoundedURLSessionDataError, .responseTooLarge)
        }

        XCTAssertEqual(StreamingResponseURLProtocol.deliveredByteCount, fullscreenResponseMaximumBytes + 1)
    }

    func testDeclaredOversizeResponseAbortsBeforeFullBodyDelivery() async throws {
        StreamingResponseURLProtocol.configure(
            body: Data(repeating: 9, count: 4_096),
            chunkSize: 64,
            declaredLength: fullscreenResponseMaximumBytes + 1
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await boundedURLSessionData(
                for: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/declared-over"))),
                using: session,
                maximumBytes: fullscreenResponseMaximumBytes
            )
            XCTFail("Expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? BoundedURLSessionDataError, .responseTooLarge)
        }

        XCTAssertLessThan(StreamingResponseURLProtocol.deliveredByteCount, 4_096)
    }

    func testCancellationStopsStreamingTask() async throws {
        StreamingResponseURLProtocol.configure(
            body: Data(repeating: 3, count: 8),
            chunkSize: 8,
            hangsAfterBody: true
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let task = Task {
            try await boundedURLSessionData(
                for: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/hang"))),
                using: session,
                maximumBytes: 32
            )
        }
        await waitUntil { StreamingResponseURLProtocol.deliveredByteCount == 8 }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            let urlError = error as? URLError
            XCTAssertTrue(error is CancellationError || urlError?.code == .cancelled, "Unexpected error: \(error)")
        }
        await waitUntil { StreamingResponseURLProtocol.stopCount > 0 }
    }

    func testDuplicateProtocolCompletionOnlyCompletesRequestOnce() async throws {
        StreamingResponseURLProtocol.configure(
            body: Data([1, 2, 3]),
            chunkSize: 3,
            sendsDuplicateCompletion: true
        )
        let delegate = RecordingTaskDelegate()
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await boundedURLSessionData(
            for: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/duplicate"))),
            using: session,
            maximumBytes: 32
        )

        XCTAssertEqual(data, Data([1, 2, 3]))
        await waitUntil { delegate.completionCount == 1 }
        XCTAssertEqual(delegate.completionCount, 1)
    }

    func testRepeatedRequestsReuseSessionAndReleaseCompletedTasks() async throws {
        StreamingResponseURLProtocol.configure(body: Data([4, 5, 6]), chunkSize: 2)
        let delegate = RecordingTaskDelegate()
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        for index in 0..<100 {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/repeated/\(index)")))
            request.setValue("request-value", forHTTPHeaderField: "X-Request-Header")
            let (data, _) = try await boundedURLSessionData(
                for: request,
                using: session,
                maximumBytes: 32
            )
            XCTAssertEqual(data, Data([4, 5, 6]))
        }

        XCTAssertEqual(StreamingResponseURLProtocol.startCount, 100)
        XCTAssertEqual(delegate.completionCount, 100)
        XCTAssertEqual(delegate.metricsCount, 100)
        let headers = StreamingResponseURLProtocol.lastRequestHeaders
        XCTAssertEqual(headers["X-Request-Header"], "request-value")
        XCTAssertEqual(headers["X-Session-Header"], "session-value")
        await waitForNoTasks(in: session)
    }

    func testAllFullscreenEndpointsRejectDeclaredOversizeResponseAsInvalidResponse() async throws {
        let calls: [(SimulaAPI) async throws -> Void] = [
            { api in _ = try await api.loadAd(adUnitId: "interstitial", sessionId: "session") },
            { api in _ = try await api.loadRewarded(adUnitId: "rewarded", sessionId: "session") },
            { api in _ = try await api.fetchFallbacks(impressionId: "impression") },
        ]

        for call in calls {
            StreamingResponseURLProtocol.configure(
                body: Data(),
                chunkSize: 1,
                declaredLength: fullscreenResponseMaximumBytes + 1
            )
            let session = makeSession()
            let api = SimulaAPI(session: session, environment: .production)
            do {
                try await call(api)
                XCTFail("Expected invalidResponse")
            } catch {
                guard case SimulaAPIError.invalidResponse = error else {
                    session.invalidateAndCancel()
                    return XCTFail("Expected invalidResponse, got \(error)")
                }
            }
            session.invalidateAndCancel()
        }
    }

    private func makeSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingResponseURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Session-Header": "session-value"]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                return
            }
        }
        XCTFail("Timed out waiting for URLProtocol state")
    }

    private func waitForNoTasks(in session: URLSession) async {
        for _ in 0..<1_000 {
            if await session.allTasks.isEmpty { return }
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                return
            }
        }
        XCTFail("Timed out waiting for URLSession tasks to be released")
    }
}

private final class RecordingTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _completionCount = 0
    private var _metricsCount = 0

    var completionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _completionCount
    }

    var metricsCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _metricsCount
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        _metricsCount += 1
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        _completionCount += 1
        lock.unlock()
    }
}

private final class StreamingResponseURLProtocol: URLProtocol {
    private struct Configuration {
        let body: Data
        let chunkSize: Int
        let hangsAfterBody: Bool
        let declaredLength: Int?
        let sendsDuplicateCompletion: Bool
    }

    private static let stateLock = NSLock()
    private static var configuration = Configuration(
        body: Data(),
        chunkSize: 1,
        hangsAfterBody: false,
        declaredLength: nil,
        sendsDuplicateCompletion: false
    )
    private static var _deliveredByteCount = 0
    private static var _stopCount = 0
    private static var _startCount = 0
    private static var _lastRequestHeaders: [String: String] = [:]

    private let instanceLock = NSLock()
    private var stopped = false

    static var deliveredByteCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deliveredByteCount
    }

    static var stopCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _stopCount
    }

    static var startCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _startCount
    }

    static var lastRequestHeaders: [String: String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastRequestHeaders
    }

    static func configure(
        body: Data,
        chunkSize: Int,
        hangsAfterBody: Bool = false,
        declaredLength: Int? = nil,
        sendsDuplicateCompletion: Bool = false
    ) {
        stateLock.lock()
        configuration = Configuration(
            body: body,
            chunkSize: max(1, chunkSize),
            hangsAfterBody: hangsAfterBody,
            declaredLength: declaredLength,
            sendsDuplicateCompletion: sendsDuplicateCompletion
        )
        _deliveredByteCount = 0
        _stopCount = 0
        _startCount = 0
        _lastRequestHeaders = [:]
        stateLock.unlock()
    }

    static func reset() {
        configure(body: Data(), chunkSize: 1)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        let configuration = Self.configuration
        Self._startCount += 1
        Self._lastRequestHeaders = request.allHTTPHeaderFields ?? [:]
        Self.stateLock.unlock()
        var headers: [String: String] = [:]
        if let declaredLength = configuration.declaredLength {
            headers["Content-Length"] = String(declaredLength)
        } else {
            headers["Transfer-Encoding"] = "chunked"
        }
        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(configuration: configuration, offset: 0)
    }

    override func stopLoading() {
        instanceLock.lock()
        stopped = true
        instanceLock.unlock()
        Self.stateLock.lock()
        Self._stopCount += 1
        Self.stateLock.unlock()
    }

    private func send(configuration: Configuration, offset: Int) {
        guard offset < configuration.body.count else {
            if !configuration.hangsAfterBody {
                client?.urlProtocolDidFinishLoading(self)
                if configuration.sendsDuplicateCompletion {
                    client?.urlProtocolDidFinishLoading(self)
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
            }
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self else { return }
            self.instanceLock.lock()
            let stopped = self.stopped
            self.instanceLock.unlock()
            guard !stopped else { return }
            let end = min(offset + configuration.chunkSize, configuration.body.count)
            let chunk = configuration.body.subdata(in: offset..<end)
            Self.stateLock.lock()
            Self._deliveredByteCount += chunk.count
            Self.stateLock.unlock()
            self.client?.urlProtocol(self, didLoad: chunk)
            self.send(configuration: configuration, offset: end)
        }
    }
}
