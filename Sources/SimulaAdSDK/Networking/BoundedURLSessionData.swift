import Foundation

enum BoundedURLSessionDataError: Error, Equatable {
    case responseTooLarge
}

/// Loads through the caller's existing session while retaining no more than `maximumBytes`.
/// A per-task delegate preserves the session configuration and receives whole `Data` chunks
/// without creating a short-lived session for every request.
func boundedURLSessionData(
    for request: URLRequest,
    using session: URLSession,
    maximumBytes: Int
) async throws -> (Data, URLResponse) {
    guard maximumBytes >= 0 else { throw BoundedURLSessionDataError.responseTooLarge }
    let loader = BoundedURLSessionDataLoader(
        maximumBytes: maximumBytes,
        forwardingTo: session.delegate as? URLSessionTaskDelegate
    )
    return try await loader.load(for: request, using: session)
}

private final class BoundedURLSessionDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let forwardedDelegate: URLSessionTaskDelegate?
    private let lock = NSLock()

    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var body = Data()
    private var terminalError: Error?
    private var cancellationRequested = false
    private var completed = false

    init(maximumBytes: Int, forwardingTo delegate: URLSessionTaskDelegate?) {
        self.maximumBytes = maximumBytes
        self.forwardedDelegate = delegate
    }

    func load(for request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(for: request, using: session, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(
        for request: URLRequest,
        using session: URLSession,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        let task = session.dataTask(with: request)
        task.delegate = self

        lock.lock()
        if cancellationRequested {
            completed = true
            lock.unlock()
            task.delegate = nil
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()

        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        if !completed, terminalError == nil {
            terminalError = CancellationError()
        }
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let expectedLength = response.expectedContentLength

        lock.lock()
        guard !completed, terminalError == nil else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        guard expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
            terminalError = BoundedURLSessionDataError.responseTooLarge
            body.removeAll(keepingCapacity: false)
            let task = task
            lock.unlock()
            completionHandler(.cancel)
            task?.cancel()
            return
        }
        self.response = response
        if expectedLength > 0 {
            body.reserveCapacity(Int(expectedLength))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed, terminalError == nil else {
            lock.unlock()
            return
        }
        guard data.count <= maximumBytes - body.count else {
            terminalError = BoundedURLSessionDataError.responseTooLarge
            body.removeAll(keepingCapacity: false)
            let task = task
            lock.unlock()
            task?.cancel()
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        let shouldForward = !completed
        lock.unlock()
        guard shouldForward else { return }
        forwardedDelegate?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        let result: Result<(Data, URLResponse), Error>
        if let terminalError {
            result = .failure(terminalError)
        } else if let error {
            result = .failure(error)
        } else if let response {
            result = .success((body, response))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        body.removeAll(keepingCapacity: false)
        self.response = nil
        lock.unlock()

        forwardedDelegate?.urlSession?(session, task: task, didCompleteWithError: error)
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))) {
            forwardedDelegate.urlSession?(
                session,
                task: task,
                didReceive: challenge,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))) {
            forwardedDelegate.urlSession?(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:needNewBodyStream:))) {
            forwardedDelegate.urlSession?(session, task: task, needNewBodyStream: completionHandler)
        } else {
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        forwardedDelegate?.urlSession?(
            session,
            task: task,
            didSendBodyData: bytesSent,
            totalBytesSent: totalBytesSent,
            totalBytesExpectedToSend: totalBytesExpectedToSend
        )
    }
}
