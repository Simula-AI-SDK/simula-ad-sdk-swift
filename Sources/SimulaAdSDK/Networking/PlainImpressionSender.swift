import Foundation

#if canImport(Darwin)
import Darwin
#endif

let plainImpressionTimeout: TimeInterval = 5
let plainImpressionMaxRedirects = 5
let plainImpressionFailureSignature = "impression_url:get_failed"
let publicNetworkResolverMaximumWorkers = 2
let publicNetworkResolverMaximumPending = 16

typealias PublicNetworkHostResolver = @Sendable (String) -> [String]?
typealias ImpressionHostResolver = PublicNetworkHostResolver

enum PublicNetworkResolverError: Error, Equatable {
    case timedOut
    case overloaded
    case unavailable
}

protocol PublicNetworkHostResolving: Sendable {
    func resolve(_ host: String, deadline: TimeInterval) async throws -> [String]
}

private final class PublicNetworkResolveRequest: @unchecked Sendable {
    let id = UUID()
    let host: String
    let deadline: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    private var result: Result<[String], Error>?
    private var timer: DispatchSourceTimer?

    init(host: String, deadline: TimeInterval) {
        self.host = host
        self.deadline = deadline
    }

    func install(_ continuation: CheckedContinuation<[String], Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func armDeadline(after delay: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler(handler: onTimeout)
        // A dispatch source must be activated before cancellation/release. Activate before
        // publishing it so fast worker completion can only ever cancel an active source.
        timer.activate()
        lock.lock()
        guard result == nil else {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }

    @discardableResult
    func finish(_ result: Result<[String], Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
        return true
    }
}

/// `getaddrinfo` has no cancellation API. Two dedicated blocking workers contain stuck libc calls;
/// async callers are completed independently by their monotonic deadline or cancellation.
final class BoundedPublicNetworkHostResolver: PublicNetworkHostResolving, @unchecked Sendable {
    static let shared = BoundedPublicNetworkHostResolver()

    private let condition = NSCondition()
    private var pending: [PublicNetworkResolveRequest] = []
    private let maximumPending: Int
    private let monotonicNow: @Sendable () -> TimeInterval
    private let lookup: @Sendable (String) -> [String]?

    internal var pendingRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pending.count
    }

    init(
        maximumWorkers: Int = publicNetworkResolverMaximumWorkers,
        maximumPending: Int = publicNetworkResolverMaximumPending,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        lookup: @escaping @Sendable (String) -> [String]? = { resolvePublicNetworkHost($0) }
    ) {
        self.maximumPending = max(0, maximumPending)
        self.monotonicNow = monotonicNow
        self.lookup = lookup
        for index in 0..<max(1, min(publicNetworkResolverMaximumWorkers, maximumWorkers)) {
            let thread = Thread { [weak self] in self?.runWorker() }
            thread.name = "simula.dns.\(index)"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    func resolve(_ host: String, deadline: TimeInterval) async throws -> [String] {
        let request = PublicNetworkResolveRequest(host: host, deadline: deadline)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !Task.isCancelled else {
                    request.finish(.failure(CancellationError()))
                    return
                }
                let remaining = deadline - monotonicNow()
                guard remaining > 0 else {
                    request.finish(.failure(PublicNetworkResolverError.timedOut))
                    return
                }
                condition.lock()
                guard pending.count < maximumPending else {
                    condition.unlock()
                    request.finish(.failure(PublicNetworkResolverError.overloaded))
                    return
                }
                pending.append(request)
                condition.signal()
                condition.unlock()
                request.armDeadline(after: remaining) { [weak self, weak request] in
                    guard let request else { return }
                    self?.removePending(request.id)
                    request.finish(.failure(PublicNetworkResolverError.timedOut))
                }
            }
        } onCancel: {
            self.removePending(request.id)
            request.finish(.failure(CancellationError()))
        }
    }

    private func runWorker() {
        while true {
            condition.lock()
            while pending.isEmpty { condition.wait() }
            let request = pending.removeFirst()
            condition.unlock()
            guard !request.isComplete else { continue }
            let addresses = lookup(request.host)
            if let addresses, !addresses.isEmpty {
                request.finish(.success(addresses))
            } else {
                request.finish(.failure(PublicNetworkResolverError.unavailable))
            }
        }
    }

    private func removePending(_ id: UUID) {
        condition.lock()
        pending.removeAll { $0.id == id }
        condition.unlock()
    }
}

struct ImmediatePublicNetworkHostResolver: PublicNetworkHostResolving {
    let resolveSynchronously: PublicNetworkHostResolver
    var monotonicNow: @Sendable () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }

    func resolve(_ host: String, deadline: TimeInterval) async throws -> [String] {
        guard deadline > monotonicNow() else {
            throw PublicNetworkResolverError.timedOut
        }
        guard let addresses = resolveSynchronously(host), !addresses.isEmpty else {
            throw PublicNetworkResolverError.unavailable
        }
        return addresses
    }
}

func publicNetworkRequest(url: URL, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: max(0.001, timeout)
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.allHTTPHeaderFields = [:]
    return request
}

func admittedPublicNetworkRequest(
    url: URL,
    timeout: TimeInterval,
    resolve: PublicNetworkHostResolver
) -> URLRequest? {
    guard timeout.isFinite, timeout > 0,
          let host = validatedPublicNetworkHost(url),
          let addresses = resolve(host),
          !addresses.isEmpty,
          addresses.allSatisfy(isPublicNetworkAddress) else { return nil }
    return publicNetworkRequest(url: url, timeout: timeout)
}

func admittedPublicNetworkRedirectRequest(
    url: URL,
    redirectCount: Int,
    maximumRedirects: Int,
    timeout: TimeInterval,
    resolve: PublicNetworkHostResolver
) -> URLRequest? {
    guard redirectCount < maximumRedirects else { return nil }
    return admittedPublicNetworkRequest(url: url, timeout: timeout, resolve: resolve)
}

func deadlineAdmittedPublicNetworkRequest(
    url: URL,
    deadline: TimeInterval,
    monotonicNow: @Sendable () -> TimeInterval,
    resolver: PublicNetworkHostResolving
) async throws -> URLRequest? {
    let remaining = deadline - monotonicNow()
    guard remaining > 0, let host = validatedPublicNetworkHost(url) else { return nil }
    let addresses = try await resolver.resolve(host, deadline: deadline)
    guard monotonicNow() < deadline else { throw PublicNetworkResolverError.timedOut }
    guard !addresses.isEmpty,
          addresses.allSatisfy(isPublicNetworkAddress) else { return nil }
    return publicNetworkRequest(url: url, timeout: deadline - monotonicNow())
}

func plainImpressionRequest(url: URL, timeout: TimeInterval = plainImpressionTimeout) -> URLRequest {
    publicNetworkRequest(url: url, timeout: min(timeout, plainImpressionTimeout))
}

func admittedPlainImpressionRequest(
    url: URL,
    timeout: TimeInterval = plainImpressionTimeout,
    resolve: ImpressionHostResolver
) -> URLRequest? {
    admittedPublicNetworkRequest(
        url: url,
        timeout: min(timeout, plainImpressionTimeout),
        resolve: resolve
    )
}

func admittedPlainImpressionRedirectRequest(
    url: URL,
    redirectCount: Int,
    timeout: TimeInterval,
    resolve: ImpressionHostResolver
) -> URLRequest? {
    admittedPublicNetworkRedirectRequest(
        url: url,
        redirectCount: redirectCount,
        maximumRedirects: plainImpressionMaxRedirects,
        timeout: min(timeout, plainImpressionTimeout),
        resolve: resolve
    )
}

private func validatedPublicNetworkHost(_ url: URL) -> String? {
    let raw = url.absoluteString
    guard !raw.isEmpty,
          !raw.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 32 || $0.value == 127 }),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.user == nil,
          components.password == nil,
          let authorityStart = raw.range(of: "://")?.upperBound else { return nil }

    let remainder = raw[authorityStart...]
    let authority = String(remainder.prefix { character in
        character != "/" && character != "?" && character != "#"
    })
    guard validPublicNetworkAuthority(authority),
          let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
          !host.isEmpty else { return nil }
    let normalized = host.lowercased()
    guard normalized != "localhost",
          !normalized.hasSuffix(".localhost"),
          !normalized.hasSuffix(".local"),
          !normalized.hasSuffix(".internal"),
          !normalized.hasSuffix(".home.arpa") else { return nil }
    return normalized
}

private func validPublicNetworkAuthority(_ authority: String) -> Bool {
    guard !authority.isEmpty, !authority.contains("@") else { return false }
    let portText: Substring?
    if authority.first == "[" {
        guard let closing = authority.firstIndex(of: "]"), closing > authority.startIndex else { return false }
        let suffix = authority[authority.index(after: closing)...]
        if suffix.isEmpty {
            portText = nil
        } else {
            guard suffix.first == ":" else { return false }
            portText = suffix.dropFirst()
        }
    } else {
        guard authority.filter({ $0 == ":" }).count <= 1 else { return false }
        if let colon = authority.lastIndex(of: ":") {
            guard colon > authority.startIndex else { return false }
            portText = authority[authority.index(after: colon)...]
        } else {
            portText = nil
        }
    }
    guard let portText else { return true }
    guard !portText.isEmpty, portText.allSatisfy(\.isNumber),
          let port = Int(portText), (1...65_535).contains(port) else { return false }
    return true
}

private func isPublicNetworkAddress(_ value: String) -> Bool {
    if let bytes = parsedAddress(value, family: AF_INET, byteCount: 4) {
        let first = Int(bytes[0])
        let second = Int(bytes[1])
        let third = Int(bytes[2])
        switch (first, second, third) {
        case (0, _, _), (10, _, _), (127, _, _), (224...255, _, _): return false
        case (100, 64...127, _), (169, 254, _), (172, 16...31, _): return false
        case (192, 168, _), (192, 0, 0), (192, 0, 2), (192, 88, 99): return false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        default: return true
        }
    }
    guard let bytes = parsedAddress(value, family: AF_INET6, byteCount: 16) else { return false }
    let first = Int(bytes[0])
    let second = Int(bytes[1])
    let third = Int(bytes[2])
    let fourth = Int(bytes[3])
    let globalUnicast = (0x20...0x3f).contains(first)
    let special2001 = first == 0x20 && second == 0x01 && (
        third <= 0x01 || (third == 0x0d && fourth == 0xb8)
    )
    let documentation3fff = first == 0x3f && second == 0xff && (third & 0xf0) == 0
    let sixToFour = first == 0x20 && second == 0x02
    let publicNat64 = first == 0x00 && second == 0x64 && third == 0xff && fourth == 0x9b &&
        bytes[4..<12].allSatisfy { $0 == 0 } &&
        isPublicNetworkAddress(bytes[12..<16].map(String.init).joined(separator: "."))
    return (globalUnicast || publicNat64) && !special2001 && !documentation3fff && !sixToFour
}

private func parsedAddress(_ value: String, family: Int32, byteCount: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let parsed = value.withCString { source in
        bytes.withUnsafeMutableBytes { destination in
            inet_pton(family, source, destination.baseAddress)
        }
    }
    return parsed == 1 ? bytes : nil
}

func resolvePublicNetworkHost(_ host: String) -> [String]? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(first) }

    var addresses: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor?.pointee {
        if let address = info.ai_addr {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = buffer.withUnsafeMutableBufferPointer { output in
                getnameinfo(
                    address,
                    info.ai_addrlen,
                    output.baseAddress,
                    socklen_t(output.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            if status == 0 { addresses.append(String(cString: buffer)) }
        }
        cursor = info.ai_next
    }
    return addresses.isEmpty ? nil : addresses
}

private struct PlainImpressionTaskState {
    let deadline: TimeInterval
    var redirects: Int
    var successfulStatus = false
}

private final class PlainImpressionSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let resolver: PublicNetworkHostResolving
    private let monotonicNow: @Sendable () -> TimeInterval
    private let recordFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var states: [Int: PlainImpressionTaskState] = [:]
    private var pendingStarts = 0

    init(
        resolver: PublicNetworkHostResolving,
        monotonicNow: @escaping @Sendable () -> TimeInterval,
        recordFailure: @escaping @Sendable () -> Void
    ) {
        self.resolver = resolver
        self.monotonicNow = monotonicNow
        self.recordFailure = recordFailure
    }

    func send(_ url: URL, using session: URLSession) {
        lock.lock()
        guard pendingStarts < publicNetworkResolverMaximumPending else {
            lock.unlock()
            recordFailure()
            return
        }
        pendingStarts += 1
        lock.unlock()
        let deadline = monotonicNow() + plainImpressionTimeout
        Task(priority: .utility) { [weak self, weak session] in
            guard let self else { return }
            defer { self.finishPendingStart() }
            guard let session else {
                self.recordFailure()
                return
            }
            let request: URLRequest?
            do {
                request = try await deadlineAdmittedPublicNetworkRequest(
                    url: url,
                    deadline: deadline,
                    monotonicNow: self.monotonicNow,
                    resolver: self.resolver
                )
            } catch {
                self.recordFailure()
                return
            }
            guard let request, self.remaining(deadline: deadline) != nil else {
                self.recordFailure()
                return
            }
            let task = session.dataTask(with: request)
            self.register(taskIdentifier: task.taskIdentifier, deadline: deadline)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let state = state(taskIdentifier: task.taskIdentifier)
        guard let state, let url = request.url,
              remaining(deadline: state.deadline) != nil else {
            completionHandler(nil)
            return
        }
        guard state.redirects < plainImpressionMaxRedirects else {
            completionHandler(nil)
            return
        }
        Task(priority: .utility) { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            let redirected: URLRequest?
            do {
                redirected = try await deadlineAdmittedPublicNetworkRequest(
                    url: url,
                    deadline: state.deadline,
                    monotonicNow: self.monotonicNow,
                    resolver: self.resolver
                )
            } catch {
                completionHandler(nil)
                return
            }
            guard let redirected, self.remaining(deadline: state.deadline) != nil else {
                completionHandler(nil)
                return
            }
            if self.claimRedirect(taskIdentifier: task.taskIdentifier, expectedCount: state.redirects) {
                completionHandler(redirected)
            } else {
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode
        markResponse(
            taskIdentifier: dataTask.taskIdentifier,
            successful: status.map { (200...299).contains($0) } == true
        )
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = remove(taskIdentifier: task.taskIdentifier) else { return }
        if error != nil || !state.successfulStatus { recordFailure() }
    }

    private func register(taskIdentifier: Int, deadline: TimeInterval) {
        lock.lock()
        states[taskIdentifier] = PlainImpressionTaskState(deadline: deadline, redirects: 0)
        lock.unlock()
    }

    private func state(taskIdentifier: Int) -> PlainImpressionTaskState? {
        lock.lock(); defer { lock.unlock() }
        return states[taskIdentifier]
    }

    private func claimRedirect(taskIdentifier: Int, expectedCount: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var current = states[taskIdentifier], current.redirects == expectedCount else { return false }
        current.redirects += 1
        states[taskIdentifier] = current
        return true
    }

    private func markResponse(taskIdentifier: Int, successful: Bool) {
        lock.lock()
        if var state = states[taskIdentifier] {
            state.successfulStatus = successful
            states[taskIdentifier] = state
        }
        lock.unlock()
    }

    private func remove(taskIdentifier: Int) -> PlainImpressionTaskState? {
        lock.lock(); defer { lock.unlock() }
        return states.removeValue(forKey: taskIdentifier)
    }

    private func remaining(deadline: TimeInterval) -> TimeInterval? {
        let now = monotonicNow()
        guard deadline > now else { return nil }
        return min(plainImpressionTimeout, deadline - now)
    }

    private func finishPendingStart() {
        lock.lock()
        pendingStarts = max(0, pendingStarts - 1)
        lock.unlock()
    }
}

final class PlainImpressionSender: @unchecked Sendable {
    static let shared = PlainImpressionSender(resolver: BoundedPublicNetworkHostResolver.shared)
    private let delegate: PlainImpressionSessionDelegate
    private let session: URLSession

    convenience init(
        configuration: URLSessionConfiguration? = nil,
        resolver: @escaping ImpressionHostResolver,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        recordFailure: @escaping @Sendable () -> Void = {
            Telemetry.shared.recordError(signature: plainImpressionFailureSignature)
        }
    ) {
        self.init(
            configuration: configuration,
            resolver: ImmediatePublicNetworkHostResolver(
                resolveSynchronously: resolver,
                monotonicNow: monotonicNow
            ),
            monotonicNow: monotonicNow,
            recordFailure: recordFailure
        )
    }

    init(
        configuration: URLSessionConfiguration? = nil,
        resolver: PublicNetworkHostResolving = BoundedPublicNetworkHostResolver.shared,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        recordFailure: @escaping @Sendable () -> Void = {
            Telemetry.shared.recordError(signature: plainImpressionFailureSignature)
        }
    ) {
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = plainImpressionTimeout
        configuration.timeoutIntervalForResource = plainImpressionTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = PlainImpressionSessionDelegate(
            resolver: resolver,
            monotonicNow: monotonicNow,
            recordFailure: recordFailure
        )
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func send(_ url: URL?) {
        guard let url else { return }
        delegate.send(url, using: session)
    }
}
