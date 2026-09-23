import CryptoKit
import Foundation

let videoAssetMaximumBytes: Int64 = 50 * 1024 * 1024
let videoAssetCacheMaximumBytes: Int64 = 100 * 1024 * 1024
let videoAssetDownloadTimeout: TimeInterval = 30
let videoAssetOrphanLifetime: TimeInterval = 24 * 60 * 60
let videoAssetMaximumConcurrentTransfers = 2
let videoAssetMaximumPendingTransfers = 16
let videoAssetMaximumRedirects = 5
private let videoAssetCleanupBatchSize = 128
private let videoAssetMaximumCacheFiles = 256

enum VideoAssetCacheError: Error, Equatable, CaseIterable {
    case invalidURL
    case unsafeTarget
    case unavailable
    case tooLarge
    case cacheFull
    case admissionOverflow
    case timedOut
}

struct VideoAssetLoadFailure {
    let callbackError: SimulaAdError
    let telemetryCode: String

    var telemetrySignature: String { "video_asset:\(telemetryCode)" }
}

func videoAssetLoadFailure(for error: VideoAssetCacheError) -> VideoAssetLoadFailure {
    // The public error enums have no cache-specific cases. Keep their ABI stable while using
    // conventional timeout/unavailable statuses to preserve the network distinction.
    switch error {
    case .timedOut:
        return VideoAssetLoadFailure(
            callbackError: .network(.httpError(statusCode: 408)),
            telemetryCode: "cache_timeout"
        )
    case .unavailable:
        return VideoAssetLoadFailure(
            callbackError: .network(.httpError(statusCode: 503)),
            telemetryCode: "transfer_failed"
        )
    case .invalidURL:
        return VideoAssetLoadFailure(callbackError: .noFill, telemetryCode: "invalid_url")
    case .unsafeTarget:
        return VideoAssetLoadFailure(callbackError: .noFill, telemetryCode: "unsafe_target")
    case .tooLarge:
        return VideoAssetLoadFailure(callbackError: .noFill, telemetryCode: "asset_too_large")
    case .cacheFull:
        return VideoAssetLoadFailure(callbackError: .noFill, telemetryCode: "cache_full")
    case .admissionOverflow:
        return VideoAssetLoadFailure(callbackError: .noFill, telemetryCode: "cache_admission")
    }
}

private func normalizedVideoAssetTransferError(_ error: Error) -> Error {
    if error is CancellationError { return CancellationError() }
    if let cacheError = error as? VideoAssetCacheError { return cacheError }
    if (error as? URLError)?.code == .timedOut { return VideoAssetCacheError.timedOut }
    return VideoAssetCacheError.unavailable
}

protocol VideoAssetDownloading: Sendable {
    func download(
        from remoteURL: URL,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws
}

struct VideoAssetDownloadTarget: Sendable {
    let remoteURL: URL
    let admittedRequest: URLRequest?
}

extension VideoAssetDownloading {
    func prepareTarget(from remoteURL: URL, deadline: TimeInterval) async throws -> VideoAssetDownloadTarget {
        VideoAssetDownloadTarget(remoteURL: remoteURL, admittedRequest: nil)
    }

    func download(
        target: VideoAssetDownloadTarget,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        try await download(
            from: target.remoteURL,
            to: temporaryURL,
            maximumBytes: maximumBytes,
            timeout: timeout
        )
    }
}

final class VideoAssetLease: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var referenceCount = 1
        private var releaseAction: (@Sendable () -> Void)?

        init(release: @escaping @Sendable () -> Void) {
            releaseAction = release
        }

        func retain() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard releaseAction != nil else { return false }
            referenceCount += 1
            return true
        }

        func release() {
            lock.lock()
            guard referenceCount > 0 else {
                lock.unlock()
                return
            }
            referenceCount -= 1
            let action = referenceCount == 0 ? releaseAction : nil
            if action != nil { releaseAction = nil }
            lock.unlock()
            action?()
        }
    }

    let localURL: URL
    private let lock = NSLock()
    private let storage: Storage
    private var released = false

    init(localURL: URL, release: @escaping @Sendable () -> Void) {
        self.localURL = localURL
        self.storage = Storage(release: release)
    }

    private init(localURL: URL, storage: Storage) {
        self.localURL = localURL
        self.storage = storage
    }

    func retained() -> VideoAssetLease? {
        lock.lock()
        let canRetain = !released && storage.retain()
        lock.unlock()
        return canRetain ? VideoAssetLease(localURL: localURL, storage: storage) : nil
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        storage.release()
    }

    deinit { release() }
}

actor VideoAssetCache {
    static let shared = VideoAssetCache()

    private struct InFlight {
        let generation: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<VideoAssetLease, Error>]
        let deadline: TimeInterval
        var reservation: Int64
    }

    private struct TransferWaiter {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
        var deadlineTask: Task<Void, Never>?
    }

    private struct CacheFile {
        let url: URL
        var bytes: Int64
        var modified: Date
    }

    private let rootURL: URL
    private let downloader: VideoAssetDownloading
    private let fileManager: FileManager
    private let wallNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let maximumConcurrentTransfers: Int
    private var inFlight: [String: InFlight] = [:]
    private var leaseCounts: [String: Int] = [:]
    private var reservedBytes: Int64 = 0
    private var availableTransfers: Int
    private var transferQueue: [TransferWaiter] = []
    private var directoryEnumerator: FileManager.DirectoryEnumerator?
    private var cacheIndex: [String: CacheFile] = [:]
    private var cacheIndexReady = false
    private var maintenanceContinuationScheduled = false
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWorkerCount = 0

    init(
        rootURL: URL? = nil,
        downloader: VideoAssetDownloading = URLSessionVideoAssetDownloader(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        maximumConcurrentTransfers: Int = videoAssetMaximumConcurrentTransfers,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        }
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
        self.wallNow = now
        self.monotonicNow = monotonicNow
        self.sleep = sleep
        self.maximumConcurrentTransfers = max(1, maximumConcurrentTransfers)
        self.availableTransfers = max(1, maximumConcurrentTransfers)
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootURL = caches
                .appendingPathComponent("SimulaAdSDK", isDirectory: true)
                .appendingPathComponent("Video", isDirectory: true)
        }
    }

    func transferAdmissionSnapshot() -> (active: Int, pending: Int) {
        (maximumConcurrentTransfers - availableTransfers, transferQueue.count)
    }

    func waitUntilIdle() async {
        while !inFlight.isEmpty ||
                !leaseCounts.isEmpty ||
                !transferQueue.isEmpty ||
                maintenanceContinuationScheduled ||
                backgroundWorkerCount > 0 {
            await Task.yield()
        }
    }

    func waitUntilMaintenanceComplete() async throws {
        try prepareDirectory()
        guard maintenanceContinuationScheduled else { return }
        await withCheckedContinuation { continuation in
            maintenanceWaiters.append(continuation)
        }
    }

    func acquire(_ remoteURL: URL) async throws -> VideoAssetLease {
        guard let scheme = remoteURL.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              remoteURL.host?.isEmpty == false else { throw VideoAssetCacheError.invalidURL }
        do { try prepareDirectory() }
        catch { throw VideoAssetCacheError.cacheFull }
        let key = Self.key(for: remoteURL)
        let finalURL = rootURL.appendingPathComponent(key, isDirectory: false)
        if validAsset(at: finalURL) {
            touch(finalURL)
            return makeLease(key: key, localURL: finalURL)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerWaiter(
                    continuation,
                    id: waiterID,
                    key: key,
                    remoteURL: remoteURL,
                    finalURL: finalURL
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, key: key) }
        }
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<VideoAssetLease, Error>,
        id: UUID,
        key: String,
        remoteURL: URL,
        finalURL: URL
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let waiterLimit = maximumConcurrentTransfers + videoAssetMaximumPendingTransfers
        let waiterCount = inFlight.values.reduce(0) { $0 + $1.waiters.count }
        if var existing = inFlight[key] {
            guard waiterCount < waiterLimit else {
                continuation.resume(throwing: VideoAssetCacheError.admissionOverflow)
                return
            }
            existing.waiters[id] = continuation
            inFlight[key] = existing
            return
        }
        let deadline = monotonicNow() + videoAssetDownloadTimeout
        guard waiterCount < waiterLimit, inFlight.count < waiterLimit else {
            continuation.resume(throwing: VideoAssetCacheError.admissionOverflow)
            return
        }
        let generation = UUID()
        inFlight[key] = InFlight(
            generation: generation,
            task: nil,
            waiters: [id: continuation],
            deadline: deadline,
            reservation: 0
        )
        backgroundWorkerCount += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTransfer(
                remoteURL: remoteURL,
                key: key,
                generation: generation,
                finalURL: finalURL,
                deadline: deadline
            )
            await self.backgroundWorkerFinished()
        }
        if inFlight[key]?.generation == generation { inFlight[key]?.task = task }
    }

    private func runTransfer(
        remoteURL: URL,
        key: String,
        generation: UUID,
        finalURL: URL,
        deadline: TimeInterval
    ) async {
        let result: Result<URL, Error>
        do {
            result = .success(try await downloadAndCommit(
                remoteURL: remoteURL,
                key: key,
                generation: generation,
                finalURL: finalURL,
                deadline: deadline
            ))
        } catch {
            result = .failure(error)
        }
        finishTransfer(key: key, generation: generation, result: result)
    }

    private func cancelWaiter(id: UUID, key: String) async {
        guard var transfer = inFlight[key], let waiter = transfer.waiters.removeValue(forKey: id) else {
            return
        }
        if transfer.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            reservedBytes = max(0, reservedBytes - transfer.reservation)
            transfer.task?.cancel()
            if let task = transfer.task { await task.value }
            waiter.resume(throwing: CancellationError())
            return
        }
        inFlight[key] = transfer
        waiter.resume(throwing: CancellationError())
    }

    private func downloadAndCommit(
        remoteURL: URL,
        key: String,
        generation: UUID,
        finalURL: URL,
        deadline: TimeInterval
    ) async throws -> URL {
        let target: VideoAssetDownloadTarget
        do { target = try await downloader.prepareTarget(from: remoteURL, deadline: deadline) }
        catch { throw normalizedVideoAssetTransferError(error) }
        try Task.checkCancellation()
        guard monotonicNow() < deadline else { throw VideoAssetCacheError.timedOut }
        let slotID = UUID()
        try await waitForTransferSlot(id: slotID, deadline: deadline)
        defer {
            clearTransferReservation(key: key, generation: generation)
            releaseTransferSlot()
        }
        try reserveForTransfer(key: key, generation: generation)
        let temporaryURL = rootURL.appendingPathComponent("\(key).\(UUID().uuidString).partial")
        defer { removeIndexedFile(temporaryURL) }
        let remaining = deadline - monotonicNow()
        guard remaining > 0 else { throw VideoAssetCacheError.timedOut }
        try Task.checkCancellation()
        do {
            try await downloader.download(
                target: target,
                to: temporaryURL,
                maximumBytes: videoAssetMaximumBytes,
                timeout: remaining
            )
        } catch {
            throw normalizedVideoAssetTransferError(error)
        }
        try Task.checkCancellation()
        guard monotonicNow() <= deadline else { throw VideoAssetCacheError.timedOut }
        guard let bytes = fileSize(temporaryURL), bytes > 0 else {
            throw VideoAssetCacheError.unavailable
        }
        guard bytes <= videoAssetMaximumBytes else { throw VideoAssetCacheError.tooLarge }
        if fileManager.fileExists(atPath: finalURL.path) { removeIndexedFile(finalURL) }
        do { try fileManager.moveItem(at: temporaryURL, to: finalURL) }
        catch { throw VideoAssetCacheError.cacheFull }
        try? (finalURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        cacheIndex[key] = CacheFile(url: finalURL, bytes: bytes, modified: wallNow())
        enforceFileCountLimit()
        return finalURL
    }

    private func finishTransfer(key: String, generation: UUID, result: Result<URL, Error>) {
        guard let transfer = inFlight[key], transfer.generation == generation else {
            if case .success(let localURL) = result,
               inFlight[key] == nil,
               leaseCounts[key, default: 0] == 0 {
                removeIndexedFile(localURL)
            }
            return
        }
        inFlight.removeValue(forKey: key)
        reservedBytes = max(0, reservedBytes - transfer.reservation)
        switch result {
        case .success(let localURL):
            for waiter in transfer.waiters.values {
                waiter.resume(returning: makeLease(key: key, localURL: localURL))
            }
            if transfer.waiters.isEmpty { removeIndexedFile(localURL) }
        case .failure(let error):
            transfer.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

    private func waitForTransferSlot(id: UUID, deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        let remaining = deadline - monotonicNow()
        guard remaining > 0 else { throw VideoAssetCacheError.timedOut }
        if availableTransfers > 0, transferQueue.isEmpty {
            availableTransfers -= 1
            return
        }
        guard transferQueue.count < videoAssetMaximumPendingTransfers else {
            throw VideoAssetCacheError.admissionOverflow
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var waiter = TransferWaiter(
                    id: id,
                    deadline: deadline,
                    continuation: continuation,
                    deadlineTask: nil
                )
                backgroundWorkerCount += 1
                waiter.deadlineTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runTransferWaiterDeadline(id: id, remaining: remaining)
                    await self.backgroundWorkerFinished()
                }
                transferQueue.append(waiter)
            }
        } onCancel: {
            Task { await self.cancelTransferWaiter(id: id) }
        }
    }

    private func runTransferWaiterDeadline(id: UUID, remaining: TimeInterval) async {
        do { try await sleep(remaining) } catch { return }
        guard !Task.isCancelled else { return }
        expireTransferWaiter(id: id)
    }

    private func releaseTransferSlot() {
        while !transferQueue.isEmpty {
            let waiter = transferQueue.removeFirst()
            waiter.deadlineTask?.cancel()
            guard monotonicNow() < waiter.deadline else {
                waiter.continuation.resume(throwing: VideoAssetCacheError.timedOut)
                continue
            }
            waiter.continuation.resume()
            return
        }
        availableTransfers = min(maximumConcurrentTransfers, availableTransfers + 1)
    }

    private func cancelTransferWaiter(id: UUID) {
        guard let index = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = transferQueue.remove(at: index)
        waiter.deadlineTask?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expireTransferWaiter(id: UUID) {
        guard let index = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = transferQueue.remove(at: index)
        waiter.continuation.resume(throwing: VideoAssetCacheError.timedOut)
    }

    private func reserveForTransfer(key: String, generation: UUID) throws {
        guard inFlight[key]?.generation == generation else { throw CancellationError() }
        try reservePartialCapacity(bytes: videoAssetMaximumBytes, replacingKey: key)
        guard inFlight[key]?.generation == generation else {
            reservedBytes = max(0, reservedBytes - videoAssetMaximumBytes)
            throw CancellationError()
        }
        inFlight[key]?.reservation = videoAssetMaximumBytes
    }

    private func clearTransferReservation(key: String, generation: UUID) {
        guard inFlight[key]?.generation == generation,
              let reservation = inFlight[key]?.reservation, reservation > 0 else { return }
        reservedBytes = max(0, reservedBytes - reservation)
        inFlight[key]?.reservation = 0
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? (rootURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        guard !cacheIndexReady, !maintenanceContinuationScheduled else { return }
        scanMaintenanceBatch()
        if !cacheIndexReady { scheduleMaintenanceContinuation() }
    }

    private func validAsset(at url: URL) -> Bool {
        guard let bytes = fileSize(url), bytes > 0, bytes <= videoAssetMaximumBytes else {
            removeIndexedFile(url)
            return false
        }
        cacheIndex[url.lastPathComponent] = CacheFile(
            url: url,
            bytes: bytes,
            modified: wallNow()
        )
        return true
    }

    private func reservePartialCapacity(bytes: Int64, replacingKey: String) throws {
        guard cacheIndexReady else { throw VideoAssetCacheError.cacheFull }
        pruneMissingIndexEntries()
        var files = cacheIndex.values.filter { file in
            isCacheFile(file.url) && !isInFlightPartial(file.url)
        }
        var total = files.reduce(reservedBytes) { $0 + $1.bytes }
        if let replaced = files.first(where: { $0.url.lastPathComponent == replacingKey }) {
            total -= replaced.bytes
            files.removeAll { $0.url == replaced.url }
        }
        let reservedFileSlots = inFlight.values.reduce(0) { count, transfer in
            count + (transfer.reservation > 0 ? 1 : 0)
        }
        if files.count + reservedFileSlots + 1 > videoAssetMaximumCacheFiles {
            for file in files.sorted(by: { $0.modified < $1.modified })
                where files.count + reservedFileSlots + 1 > videoAssetMaximumCacheFiles {
                guard !isActive(file.url) else { continue }
                removeIndexedFile(file.url)
                if !fileManager.fileExists(atPath: file.url.path) {
                    files.removeAll { $0.url == file.url }
                    total -= file.bytes
                }
            }
        }
        guard files.count + reservedFileSlots + 1 <= videoAssetMaximumCacheFiles else {
            throw VideoAssetCacheError.cacheFull
        }
        if total + bytes > videoAssetCacheMaximumBytes {
            for file in files.sorted(by: { $0.modified < $1.modified })
                where total + bytes > videoAssetCacheMaximumBytes {
                guard !isActive(file.url) else { continue }
                removeIndexedFile(file.url)
                if !fileManager.fileExists(atPath: file.url.path) { total -= file.bytes }
            }
        }
        guard total + bytes <= videoAssetCacheMaximumBytes else {
            throw VideoAssetCacheError.cacheFull
        }
        reservedBytes += bytes
    }

    private func isCacheFile(_ url: URL) -> Bool {
        url.pathExtension == "partial" || Self.isOpaqueAssetName(url.lastPathComponent)
    }

    private func isInFlightPartial(_ url: URL) -> Bool {
        guard url.pathExtension == "partial", let owner = partialOwnerKey(url) else { return false }
        return inFlight[owner] != nil
    }

    private func isActive(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if Self.isOpaqueAssetName(name) {
            return leaseCounts[name, default: 0] > 0 || inFlight[name] != nil
        }
        guard let owner = partialOwnerKey(url) else { return false }
        return inFlight[owner] != nil
    }

    private func partialOwnerKey(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard url.pathExtension == "partial", name.utf8.count > 64 else { return nil }
        let key = String(name.prefix(64))
        return Self.isOpaqueAssetName(key) ? key : nil
    }

    private func makeLease(key: String, localURL: URL) -> VideoAssetLease {
        leaseCounts[key, default: 0] += 1
        return VideoAssetLease(localURL: localURL) { [weak self] in
            Task { await self?.releaseLease(key) }
        }
    }

    private func releaseLease(_ key: String) {
        let remaining = max(0, leaseCounts[key, default: 0] - 1)
        if remaining == 0 {
            leaseCounts.removeValue(forKey: key)
            removeIndexedFile(rootURL.appendingPathComponent(key))
        } else {
            leaseCounts[key] = remaining
        }
    }

    private func scanMaintenanceBatch() {
        guard !cacheIndexReady else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if directoryEnumerator == nil {
            directoryEnumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        }
        let cutoff = wallNow().addingTimeInterval(-videoAssetOrphanLifetime)
        var visited = 0
        while visited < videoAssetCleanupBatchSize {
            guard let url = directoryEnumerator?.nextObject() as? URL else {
                directoryEnumerator = nil
                cacheIndexReady = true
                break
            }
            visited += 1
            guard isCacheFile(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let file = CacheFile(
                url: url,
                bytes: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
            if file.modified < cutoff, !isActive(url) {
                removeIndexedFile(url)
            } else {
                cacheIndex[url.lastPathComponent] = file
            }
        }
        enforceFileCountLimit()
    }

    private func scheduleMaintenanceContinuation() {
        guard !maintenanceContinuationScheduled else { return }
        maintenanceContinuationScheduled = true
        backgroundWorkerCount += 1
        Task { [weak self] in
            guard let self else { return }
            await self.runMaintenanceContinuation()
        }
    }

    private func runMaintenanceContinuation() async {
        while !cacheIndexReady {
            await Task.yield()
            scanMaintenanceBatch()
        }
        maintenanceContinuationScheduled = false
        backgroundWorkerFinished()
        let waiters = maintenanceWaiters
        maintenanceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func backgroundWorkerFinished() {
        backgroundWorkerCount = max(0, backgroundWorkerCount - 1)
    }

    private func enforceFileCountLimit() {
        pruneMissingIndexEntries()
        guard cacheIndex.count > videoAssetMaximumCacheFiles else { return }
        for file in cacheIndex.values.sorted(by: { $0.modified < $1.modified }) {
            guard cacheIndex.count > videoAssetMaximumCacheFiles else { break }
            if !isActive(file.url) { removeIndexedFile(file.url) }
        }
    }

    private func removeIndexedFile(_ url: URL) {
        try? fileManager.removeItem(at: url)
        if !fileManager.fileExists(atPath: url.path) {
            cacheIndex.removeValue(forKey: url.lastPathComponent)
        }
    }

    private func pruneMissingIndexEntries() {
        for (key, file) in cacheIndex where !fileManager.fileExists(atPath: file.url.path) {
            cacheIndex.removeValue(forKey: key)
        }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }

    private func touch(_ url: URL) {
        let modified = wallNow()
        try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        if var file = cacheIndex[url.lastPathComponent] {
            file.modified = modified
            cacheIndex[url.lastPathComponent] = file
        }
    }

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isOpaqueAssetName(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

final class URLSessionVideoAssetDownloader: NSObject, VideoAssetDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration?
    private let resolver: PublicNetworkHostResolving
    private let monotonicNow: @Sendable () -> TimeInterval

    init(
        configuration: URLSessionConfiguration? = nil,
        resolver: PublicNetworkHostResolving = BoundedPublicNetworkHostResolver.shared,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.monotonicNow = monotonicNow
    }

    convenience init(
        configuration: URLSessionConfiguration? = nil,
        resolver: @escaping PublicNetworkHostResolver,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.init(
            configuration: configuration,
            resolver: ImmediatePublicNetworkHostResolver(
                resolveSynchronously: resolver,
                monotonicNow: monotonicNow
            ),
            monotonicNow: monotonicNow
        )
    }

    func prepareTarget(from remoteURL: URL, deadline: TimeInterval) async throws -> VideoAssetDownloadTarget {
        let request: URLRequest?
        do {
            request = try await deadlineAdmittedPublicNetworkRequest(
                url: remoteURL,
                deadline: deadline,
                monotonicNow: monotonicNow,
                resolver: resolver
            )
        } catch PublicNetworkResolverError.timedOut {
            throw VideoAssetCacheError.timedOut
        } catch PublicNetworkResolverError.overloaded {
            throw VideoAssetCacheError.admissionOverflow
        } catch PublicNetworkResolverError.unavailable {
            throw VideoAssetCacheError.unavailable
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VideoAssetCacheError.unavailable
        }
        guard let request else { throw VideoAssetCacheError.unsafeTarget }
        return VideoAssetDownloadTarget(remoteURL: remoteURL, admittedRequest: request)
    }

    func download(
        from remoteURL: URL,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        let deadline = monotonicNow() + timeout
        let target = try await prepareTarget(from: remoteURL, deadline: deadline)
        try await download(
            target: target,
            to: temporaryURL,
            maximumBytes: maximumBytes,
            timeout: deadline - monotonicNow()
        )
    }

    func download(
        target: VideoAssetDownloadTarget,
        to temporaryURL: URL,
        maximumBytes: Int64,
        timeout: TimeInterval
    ) async throws {
        guard let initialRequest = target.admittedRequest else {
            throw VideoAssetCacheError.unsafeTarget
        }
        let delegate = StreamingDownloadDelegate(
            destination: temporaryURL,
            maximumBytes: maximumBytes,
            configuration: configuration,
            resolver: resolver,
            monotonicNow: monotonicNow
        )
        try await delegate.run(initialRequest: initialRequest, timeout: timeout)
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let baseConfiguration: URLSessionConfiguration?
    private let resolver: PublicNetworkHostResolving
    private let monotonicNow: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var terminalError: Error?
    private var completionResult: Result<Void, Error>?
    private var deadline: TimeInterval = 0
    private var redirects = 0

    init(
        destination: URL,
        maximumBytes: Int64,
        configuration: URLSessionConfiguration?,
        resolver: PublicNetworkHostResolving,
        monotonicNow: @escaping @Sendable () -> TimeInterval
    ) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.baseConfiguration = configuration
        self.resolver = resolver
        self.monotonicNow = monotonicNow
    }

    func run(initialRequest: URLRequest, timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await runAdmittedTransfer(initialRequest: initialRequest, timeout: timeout)
        } onCancel: {
            self.cancel()
        }
    }

    private func runAdmittedTransfer(initialRequest: URLRequest, timeout: TimeInterval) async throws {
        guard timeout.isFinite, timeout > 0 else { throw VideoAssetCacheError.timedOut }
        let deadline = monotonicNow() + timeout
        setDeadline(deadline)
        try Task.checkCancellation()
        let remaining = deadline - monotonicNow()
        guard remaining > 0 else { throw VideoAssetCacheError.timedOut }
        var request = initialRequest
        request.timeoutInterval = remaining

        do { try Data().write(to: destination, options: .atomic) }
        catch { throw VideoAssetCacheError.unavailable }
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw VideoAssetCacheError.unavailable
        }
        self.handle = handle
        let configuration = (baseConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = remaining
        configuration.timeoutIntervalForResource = remaining
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = videoAssetMaximumConcurrentTransfers
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let terminalError {
                self.continuation = continuation
                completionResult = .failure(terminalError)
                lock.unlock()
                try? handle.close()
                self.handle = nil
                session.invalidateAndCancel()
                return
            }
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.dataTask = task
            lock.unlock()
            task.resume()
        }
    }

    private func cancel() {
        lock.lock()
        if terminalError == nil { terminalError = CancellationError() }
        let task = dataTask
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let expectedRedirects = redirects
        let deadline = self.deadline
        let failed = terminalError != nil
        lock.unlock()
        guard !failed else {
            completionHandler(nil)
            return
        }
        guard let url = request.url else {
            setTerminalError(VideoAssetCacheError.unsafeTarget)
            completionHandler(nil)
            return
        }
        let remaining = deadline - monotonicNow()
        guard remaining > 0 else {
            setTerminalError(VideoAssetCacheError.timedOut)
            completionHandler(nil)
            return
        }
        let resolver = self.resolver
        Task(priority: .utility) { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            guard expectedRedirects < videoAssetMaximumRedirects else {
                self.setTerminalError(VideoAssetCacheError.unsafeTarget)
                completionHandler(nil)
                return
            }
            let redirected: URLRequest?
            do {
                redirected = try await deadlineAdmittedPublicNetworkRequest(
                    url: url,
                    deadline: deadline,
                    monotonicNow: self.monotonicNow,
                    resolver: resolver
                )
            } catch PublicNetworkResolverError.timedOut {
                self.setTerminalError(VideoAssetCacheError.timedOut)
                completionHandler(nil)
                return
            } catch PublicNetworkResolverError.overloaded {
                self.setTerminalError(VideoAssetCacheError.admissionOverflow)
                completionHandler(nil)
                return
            } catch PublicNetworkResolverError.unavailable {
                self.setTerminalError(VideoAssetCacheError.unavailable)
                completionHandler(nil)
                return
            } catch {
                self.setTerminalError(VideoAssetCacheError.unavailable)
                completionHandler(nil)
                return
            }
            let now = self.monotonicNow()
            guard let redirected = self.claimRedirect(
                redirected,
                expectedRedirects: expectedRedirects,
                deadline: deadline,
                now: now
            ) else {
                completionHandler(nil)
                return
            }
            completionHandler(redirected)
        }
    }

    private func setDeadline(_ deadline: TimeInterval) {
        lock.lock(); self.deadline = deadline; lock.unlock()
    }

    private func claimRedirect(
        _ request: URLRequest?,
        expectedRedirects: Int,
        deadline: TimeInterval,
        now: TimeInterval
    ) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        guard terminalError == nil,
              redirects == expectedRedirects,
              now < deadline,
              let request else {
            if terminalError == nil {
                terminalError = now >= deadline
                    ? VideoAssetCacheError.timedOut
                    : VideoAssetCacheError.unsafeTarget
            }
            return nil
        }
        redirects += 1
        return request
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            setTerminalError(VideoAssetCacheError.unavailable)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > maximumBytes {
            setTerminalError(VideoAssetCacheError.tooLarge)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        received += Int64(data.count)
        let tooLarge = received > maximumBytes
        if tooLarge { terminalError = VideoAssetCacheError.tooLarge }
        lock.unlock()
        guard !tooLarge else {
            dataTask.cancel()
            return
        }
        do { try handle?.write(contentsOf: data) }
        catch {
            setTerminalError(VideoAssetCacheError.unavailable)
            dataTask.cancel()
        }
    }

    private func setTerminalError(_ error: Error) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        lock.lock()
        let terminalError = terminalError
        dataTask = nil
        if let terminalError { completionResult = .failure(terminalError) }
        else if let error { completionResult = .failure(normalizedVideoAssetTransferError(error)) }
        else { completionResult = .success(()) }
        lock.unlock()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let completion = continuation
        let result = completionResult
            ?? terminalError.map { .failure($0) }
            ?? error.map { .failure(normalizedVideoAssetTransferError($0)) }
            ?? .failure(VideoAssetCacheError.unavailable)
        continuation = nil
        completionResult = nil
        self.session = nil
        lock.unlock()
        completion?.resume(with: result)
    }
}
