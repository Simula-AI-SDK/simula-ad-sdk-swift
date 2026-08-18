import Foundation
#if os(iOS)
import MetricKit
#endif

// MARK: - C exception-handler bridge (file-scope, captured by the @convention(c) trampoline)

private typealias SimulaCExceptionHandler = @convention(c) (NSException) -> Void

/// The handler installed before ours, re-invoked after we persist so the host's crash reporter
/// (Crashlytics / Sentry / Bugsnag) and the platform default still run. Set once at install.
private var simulaPreviousExceptionHandler: SimulaCExceptionHandler?

/// Resolved once at install so the crash-time handler does no path math. nil ⇒ persistence disabled.
private var simulaPendingCrashFileURL: URL?

/// The module name as it appears in `callStackSymbols` / a symbolicated MetricKit call-stack tree.
/// Used to report ONLY crashes that involve SDK code.
private let simulaSDKMarker = "SimulaAdSDK"

/// Field separator + newline escape for the flat on-disk record — control chars kept off real text.
/// Identical to the Android `SimulaCrashGuard` so both SDKs share one record format.
private let simulaFieldSep = "\u{1}"
private let simulaNewlineEsc = "\u{2}"
/// Separator between stack frames within the single persisted frames field.
private let simulaFrameSep = "\u{3}"

private let simulaMaxFrames = 8
private let simulaMaxCrashFileBytes: UInt64 = 64 * 1024

// MARK: - MetricKit call-stack parsing (Foundation-only so macOS tests can exercise it)

private let simulaMaxMetricKitJSONBytes = 1024 * 1024
private let simulaMaxMetricKitNodes = 512
private let simulaMaxMetricKitDepth = 64
private let simulaMaxMetricKitFrameLength = 96

struct SimulaMetricKitAttribution: Equatable {
    let frames: [String]
    let fingerprint: String
}

private struct SimulaMetricKitEnvelope: Decodable {
    let callStackTree: SimulaMetricKitTree

    private enum CodingKeys: String, CodingKey {
        case callStackTree
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let wrapped = try container.decodeIfPresent(SimulaMetricKitTree.self, forKey: .callStackTree) {
            callStackTree = wrapped
        } else {
            callStackTree = try SimulaMetricKitTree(from: decoder)
        }
    }
}

private struct SimulaMetricKitTree: Decodable {
    let callStacks: [SimulaMetricKitStack]

    private enum CodingKeys: String, CodingKey {
        case callStacks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callStacks = (try? container.decode([SimulaMetricKitStack].self, forKey: .callStacks)) ?? []
    }
}

private struct SimulaMetricKitStack: Decodable {
    let threadAttributed: Bool
    let callStackRootFrames: [SimulaMetricKitFrame]

    private enum CodingKeys: String, CodingKey {
        case threadAttributed, callStackRootFrames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadAttributed = (try? container.decode(Bool.self, forKey: .threadAttributed)) ?? false
        callStackRootFrames = (try? container.decode([SimulaMetricKitFrame].self, forKey: .callStackRootFrames)) ?? []
    }
}

private struct SimulaMetricKitFrame: Decodable {
    let binaryName: String?
    let binaryUUID: String?
    let offsetIntoBinaryTextSegment: UInt64?
    let subFrames: [SimulaMetricKitFrame]

    private enum CodingKeys: String, CodingKey {
        case binaryName, binaryUUID, offsetIntoBinaryTextSegment, subFrames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binaryName = try? container.decode(String.self, forKey: .binaryName)
        binaryUUID = try? container.decode(String.self, forKey: .binaryUUID)
        offsetIntoBinaryTextSegment = Self.decodeUInt64(container, key: .offsetIntoBinaryTextSegment)
        subFrames = (try? container.decode([SimulaMetricKitFrame].self, forKey: .subFrames)) ?? []
    }

    private static func decodeUInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> UInt64? {
        if let value = try? container.decode(UInt64.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key), value >= 0 { return UInt64(value) }
        if let value = try? container.decode(String.self, forKey: key) { return UInt64(value) }
        return nil
    }
}

enum SimulaMetricKitParser {
    static func attribution(from data: Data) -> SimulaMetricKitAttribution? {
        guard !data.isEmpty, data.count <= simulaMaxMetricKitJSONBytes,
              let envelope = try? JSONDecoder().decode(SimulaMetricKitEnvelope.self, from: data) else {
            return nil
        }

        var visited = 0
        var canonicalFrames: [String] = []
        for stack in envelope.callStackTree.callStacks where stack.threadAttributed {
            for root in stack.callStackRootFrames {
                guard collect(
                    root,
                    depth: 0,
                    visited: &visited,
                    canonicalFrames: &canonicalFrames
                ) else {
                    return nil
                }
            }
        }
        guard !canonicalFrames.isEmpty else { return nil }
        let bounded = Array(canonicalFrames.prefix(simulaMaxFrames))
        return SimulaMetricKitAttribution(
            frames: bounded,
            fingerprint: fingerprint(for: bounded)
        )
    }

    private static func collect(
        _ frame: SimulaMetricKitFrame,
        depth: Int,
        visited: inout Int,
        canonicalFrames: inout [String]
    ) -> Bool {
        guard depth <= simulaMaxMetricKitDepth else { return false }
        visited += 1
        guard visited <= simulaMaxMetricKitNodes else { return false }

        if frame.binaryName == simulaSDKMarker, canonicalFrames.count < simulaMaxFrames {
            let uuid = safeToken(frame.binaryUUID, fallback: "unknown", maxLength: 36)
            let offset = frame.offsetIntoBinaryTextSegment.map(String.init) ?? "unknown"
            canonicalFrames.append(
                String("\(simulaSDKMarker) uuid=\(uuid) offset=\(offset)".prefix(simulaMaxMetricKitFrameLength))
            )
        }
        for child in frame.subFrames {
            guard collect(
                child,
                depth: depth + 1,
                visited: &visited,
                canonicalFrames: &canonicalFrames
            ) else {
                return false
            }
        }
        return true
    }

    static func fingerprint(for frames: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for frame in frames {
            for byte in frame.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            hash ^= 0
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func watchdogContext(from reason: String?) -> (event: String, visibility: String)? {
        guard let reason, !reason.isEmpty else { return nil }
        let lower = reason.lowercased()
        let isWatchdog = lower.contains("0x8badf00d")
            || lower.contains("2343432205")
            || lower.contains("watchdogevent:")
            || lower.contains("watchdog transgression")
        guard isWatchdog else { return nil }

        let rawEvent = token(after: "watchdogevent:", in: lower)
            ?? knownWatchdogEvent(in: lower)
            ?? "unknown"
        let visibility = token(after: "watchdogvisibility:", in: lower)
            ?? token(after: "processvisibility:", in: lower)
            ?? "unknown"
        return (normalizeWatchdogEvent(rawEvent), normalizeVisibility(visibility))
    }

    static func incidentBreadcrumb(
        fatal: String,
        watchdog: (event: String, visibility: String)?,
        attribution: SimulaMetricKitAttribution,
        applicationVersion: String?,
        applicationBuild: String?,
        windowStart: Date,
        windowEnd: Date,
        detail: String? = nil
    ) -> (breadcrumb: String, dedupe: String) {
        let startMs = epochMilliseconds(windowStart)
        let endMs = epochMilliseconds(windowEnd)
        let version = safeToken(applicationVersion, fallback: "unknown", maxLength: 32)
        let build = safeToken(applicationBuild, fallback: "unknown", maxLength: 32)
        let event = watchdog?.event ?? fatal
        let visibility = watchdog?.visibility ?? "unknown"
        let dedupe = attribution.fingerprint
        let boundedDetail = detail.map { String($0.prefix(80)) + ";" } ?? ""
        let value = "fatal=\(fatal);event=\(event);visibility=\(visibility);\(boundedDetail)fp=\(attribution.fingerprint);" +
            "appVersion=\(version);appBuild=\(build);windowStartMs=\(startMs);windowEndMs=\(endMs)"
        return (String(value.prefix(300)), dedupe)
    }

    private static func safeToken(_ value: String?, fallback: String, maxLength: Int) -> String {
        guard let value else { return fallback }
        let filtered = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
        }
        let token = String(String.UnicodeScalarView(filtered)).prefix(maxLength)
        return token.isEmpty ? fallback : String(token)
    }

    private static func token(after marker: String, in value: String) -> String? {
        guard let range = value.range(of: marker) else { return nil }
        let suffix = value[range.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        let token = suffix.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return token.isEmpty ? nil : String(token)
    }

    private static func knownWatchdogEvent(in value: String) -> String? {
        for event in ["scene-create", "scene-update", "process-exit", "background-task", "app-launch"] {
            if value.contains(event) { return event }
        }
        return nil
    }

    private static func normalizeWatchdogEvent(_ value: String) -> String {
        switch value.replacingOccurrences(of: "-", with: "_") {
        case "scene_create": return "scene_create"
        case "scene_update": return "scene_update"
        case "process_exit": return "process_exit"
        case "background_task": return "background_task"
        case "app_launch": return "app_launch"
        default: return "unknown"
        }
    }

    private static func normalizeVisibility(_ value: String) -> String {
        switch value {
        case "foreground": return "foreground"
        case "background": return "background"
        default: return "unknown"
        }
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(Int64.max) else { return 0 }
        return Int64(value)
    }
}

/**
 Process-wide crash capture for the SDK, routed into `Telemetry`. No third-party framework, no
 signal handlers:

 - **Uncaught Objective-C exceptions** are caught via `NSSetUncaughtExceptionHandler` — symbolicated
   live (so attribution works whether the SDK is statically or dynamically linked) and persisted
   synchronously, then replayed into `Telemetry` on the next launch.
 - **All other crashes (Swift traps / signals) + hangs** — which the exception handler can't see —
   are harvested from **MetricKit** (`MXCrashDiagnostic` / `MXHangDiagnostic`, iOS 14+) on the next
   launch. This is Apple's sanctioned, async-signal-safe path; it's the iOS analog of Android's
   `ApplicationExitInfo` sweep.

 Deliberately NOT installed: POSIX `signal()` handlers. They'd let us catch Swift traps in-process,
 but embedded in a host app they fight the host's own crash reporter (chaining is fragile and
 order-dependent) and run in an async-signal-unsafe context. MetricKit covers those cases safely, so
 the trade — slightly later delivery for being a good SDK citizen — is the right one.

 SDK-citizen rules (mirror the Android guard):
 - **Only the SDK's own crashes are reported** — an exception only when its `callStackSymbols`
   mention `simulaSDKMarker`; a MetricKit diagnostic only when Apple's `threadAttributed` stack
   contains SDK frames. The host's unrelated crashes / hangs are never exfiltrated. (Caveat: a
   *statically*-linked SDK's MetricKit call stacks carry the host binary name, so the MetricKit path
   under-reports there — the live-symbolicated exception path is unaffected.)
 - **The host's crash handling is preserved** — we always chain to the previously-installed
   uncaught-exception handler.
 - **The crash path does no async work** — `Telemetry.recordError` persists on a serial queue, which
   a dying process won't drain, so the handler writes a small record to disk synchronously and the
   next `install` replays it.

 Gated by the same `telemetryEnabled` flag as the rest of the pipeline: host opt-out ⇒ no capture,
 no replay, no send. `install` is idempotent; call it once from the provider's deferred startup
 (`runStartupPrewarm`), right after `Telemetry.shared.initialize` — the replay records into the
 pipeline, so telemetry must exist first, and the call site is off the main thread already.
 */
final class SimulaCrashGuard: NSObject, @unchecked Sendable {
    static let shared = SimulaCrashGuard()

    private let lock = NSLock()
    private let launchGate: LaunchSettling
    private var installed = false

    private override init() {
        launchGate = LaunchSettledGate.shared
        super.init()
    }

    init(launchGate: LaunchSettling) {
        self.launchGate = launchGate
        super.init()
    }

    func install(enabled: Bool) {
        guard enabled else { return }
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        lock.unlock()

        simulaPendingCrashFileURL = Self.resolvePendingURL()
        installUncaughtExceptionHandler()

        #if os(iOS)
        if #available(iOS 14.0, *) {
            // MetricKit wants its subscriber added on the main thread.
            DispatchQueue.main.async { MXMetricManager.shared.add(self) }
        }
        #endif

        // File I/O off the caller's thread. recordError persists durably on its own, so no explicit
        // flush is needed — the eager flush recordError schedules delivers it.
        Task { [weak self] in await self?.replayAfterLaunchSettles() }
    }

    private func replayAfterLaunchSettles() async {
        await launchGate.waitUntilSettled()
        guard !Task.isCancelled else { return }
        replayPending()
    }

    // MARK: - Uncaught Objective-C exceptions

    private func installUncaughtExceptionHandler() {
        simulaPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // No-captures C trampoline: persist (best-effort), then hand off so the host's reporter
            // and the platform default still fire.
            SimulaCrashGuard.handleUncaughtException(exception)
            simulaPreviousExceptionHandler?(exception)
        }
    }

    /// Static so the `@convention(c)` trampoline can call it without capturing an instance.
    private static func handleUncaughtException(_ exception: NSException) {
        guard let url = simulaPendingCrashFileURL else { return }
        let frames = exception.callStackSymbols
        // Report only crashes that involve SDK code (live-symbolicated frames carry the module name).
        guard frames.contains(where: { $0.contains(simulaSDKMarker) }) else { return }
        let sdkFrames = frames.filter { $0.contains(simulaSDKMarker) }.prefix(simulaMaxFrames).map { cleanFrame($0) }
        let record = [
            String(Int(Date().timeIntervalSince1970 * 1000)),
            "uncaught",
            signature(fromFrames: frames),
            exception.name.rawValue,
            compactMessage(name: exception.name.rawValue, reason: exception.reason, frames: frames),
            sdkFrames.joined(separator: simulaFrameSep),
        ]
        .map { $0.replacingOccurrences(of: simulaFieldSep, with: " ").replacingOccurrences(of: "\n", with: simulaNewlineEsc) }
        .joined(separator: simulaFieldSep)
        appendRecord(record, to: url)
    }

    private func replayPending() {
        guard let url = simulaPendingCrashFileURL ?? Self.resolvePendingURL() else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else { return }
        try? FileManager.default.removeItem(at: url) // consumed; recreated lazily on the next crash
        for raw in content.split(separator: "\n") {
            let fields = String(raw).components(separatedBy: simulaFieldSep)
            guard fields.count >= 5 else { continue }
            // 6th field (frames) is present on records written by this SDK version; older 5-field
            // records simply carry no structured stack.
            let stack = (fields.count >= 6 && !fields[5].isEmpty) ? fields[5].components(separatedBy: simulaFrameSep) : nil
            let fingerprint = stack.flatMap { $0.isEmpty ? nil : SimulaMetricKitParser.fingerprint(for: $0) }
            let breadcrumb = "fatal=uncaught;thread=\(fields[1])" +
                (fingerprint.map { ";fp=\($0)" } ?? "")
            Telemetry.shared.recordError(
                signature: fields[2],
                errorCode: fields[3],
                message: fields[4].replacingOccurrences(of: simulaNewlineEsc, with: "\n"),
                breadcrumb: breadcrumb,
                stack: stack,
                dedupeDiscriminator: fingerprint
            )
        }
    }

    // MARK: - On-disk record helpers

    /// Pure path math — NO disk I/O, so it's free to call on the main thread at install. The
    /// directory is created lazily in `appendRecord` (crash path) / `replayPending` (background).
    private static func resolvePendingURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("SimulaCrash", isDirectory: true).appendingPathComponent("pending_crashes.txt")
    }

    /// Append one record + newline, synchronously. Capped so a crash-on-launch loop can't grow it.
    /// Every call here must use only Swift-throwing APIs (caught by `try?`/`do-catch`): this runs
    /// inside the uncaught-exception handler, and a legacy `FileHandle` method that raised an ObjC
    /// exception would propagate out and `abort()` BEFORE we chain to the host's crash reporter.
    private static func appendRecord(_ record: String, to url: URL) {
        let fm = FileManager.default
        // Idempotent + cheap; ensures the container exists without any main-thread I/O at install.
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64, size >= simulaMaxCrashFileBytes {
            return
        }
        let data = Data((record + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Throwing variants (iOS 13.4+) so a disk error surfaces as a Swift error we can swallow,
            // never an ObjC exception that would escape the crash handler and abort the process.
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch { /* disk error mid-crash — drop this record so we still chain to the host handler */ }
        } else {
            try? data.write(to: url, options: .atomic) // file didn't exist yet
        }
    }

    /// Dedup key: the top SDK frame's symbol, so repeats at one crash site aggregate.
    private static func signature(fromFrames frames: [String]) -> String {
        guard let line = frames.first(where: { $0.contains(simulaSDKMarker) }) else { return "crash:uncaught" }
        // callStackSymbols columns: <index> <module> <address> <symbol> + <offset>
        let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let symbol = parts.count > 3 ? parts[3] : (parts.count > 1 ? parts[1] : "uncaught")
        return "crash:\(String(symbol.prefix(60)))"
    }

    /// Exception name + reason + the top SDK frames; `Telemetry` caps it to 300 chars.
    private static func compactMessage(name: String, reason: String?, frames: [String]) -> String {
        var s = name
        if let reason, !reason.isEmpty { s += ": \(reason)" }
        let sdkFrames = frames.filter { $0.contains(simulaSDKMarker) }.prefix(simulaMaxFrames).map { cleanFrame($0) }
        if !sdkFrames.isEmpty { s += " @ " + sdkFrames.joined(separator: " <- ") }
        return s
    }

    private static func cleanFrame(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let module = parts.count > 1 ? parts[1] : ""
        let symbol = parts.count > 3 ? parts[3] : ""
        return String("\(module).\(symbol)".prefix(40))
    }
}

// MARK: - MetricKit harvest (Swift traps / signals / hangs; iOS 14+)

#if os(iOS)
@available(iOS 14.0, *)
extension SimulaCrashGuard: MXMetricManagerSubscriber {
    /// Performance metrics — not crash data; ignored.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    /// Crash + hang diagnostics from the previous period, delivered at most once each.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let start = payload.timeStampBegin
            let end = payload.timeStampEnd
            payload.crashDiagnostics?.forEach {
                handleCrashDiagnostic($0, windowStart: start, windowEnd: end)
            }
            payload.hangDiagnostics?.forEach {
                handleHangDiagnostic($0, windowStart: start, windowEnd: end)
            } // the iOS analog of an ANR
        }
    }

    private func handleCrashDiagnostic(
        _ crash: MXCrashDiagnostic,
        windowStart: Date,
        windowEnd: Date
    ) {
        guard let attribution = attribution(from: crash.callStackTree) else { return }
        let excType = crash.exceptionType?.intValue ?? -1
        let signal = crash.signal?.intValue ?? -1
        let watchdog = SimulaMetricKitParser.watchdogContext(from: crash.terminationReason)
        let context = SimulaMetricKitParser.incidentBreadcrumb(
            fatal: watchdog == nil ? "crash" : "watchdog",
            watchdog: watchdog,
            attribution: attribution,
            applicationVersion: crash.applicationVersion,
            applicationBuild: crash.metaData.applicationBuildVersion,
            windowStart: windowStart,
            windowEnd: windowEnd,
            detail: "excType=\(excType);excCode=\(crash.exceptionCode?.intValue ?? -1);signal=\(signal)"
        )
        Telemetry.shared.recordError(
            signature: "crash:exc_\(excType)_sig_\(signal)",
            errorCode: "metrickit",
            message: crash.terminationReason,
            breadcrumb: context.breadcrumb,
            stack: attribution.frames,
            dedupeDiscriminator: context.dedupe
        )
    }

    private func handleHangDiagnostic(
        _ hang: MXHangDiagnostic,
        windowStart: Date,
        windowEnd: Date
    ) {
        guard let attribution = attribution(from: hang.callStackTree) else { return }
        let context = SimulaMetricKitParser.incidentBreadcrumb(
            fatal: "hang",
            watchdog: nil,
            attribution: attribution,
            applicationVersion: hang.applicationVersion,
            applicationBuild: hang.metaData.applicationBuildVersion,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        Telemetry.shared.recordError(
            signature: "exit:hang",
            errorCode: "metrickit",
            message: "hangDuration=\(hang.hangDuration)",
            breadcrumb: context.breadcrumb,
            stack: attribution.frames,
            dedupeDiscriminator: context.dedupe
        )
    }

    /// Conservative attribution: only an Apple-attributed thread containing SDK frames qualifies.
    /// A malformed/merged tree is skipped — under-reporting is safer than exfiltrating a host crash.
    private func attribution(from tree: MXCallStackTree) -> SimulaMetricKitAttribution? {
        SimulaMetricKitParser.attribution(from: tree.jsonRepresentation())
    }
}
#endif

// MARK: - Debug/QA crash trigger

#if DEBUG
public extension SimulaAds {
    /// **Debug/QA only — compiled out of release builds.** Deliberately raises an uncaught exception
    /// from *inside* the SDK to exercise the crash → telemetry pipeline end-to-end: because the throw
    /// originates in SDK code, its stack carries `SimulaAdSDK` frames and so passes `SimulaCrashGuard`'s
    /// SDK-only attribution filter — the crash is persisted and replayed to telemetry on the next
    /// launch (in devMode, watch the console tag `[SimulaTelemetry]` for a `crash:…` error event).
    ///
    /// This lives in the SDK (rather than the demo app) because a crash raised from the host app's own
    /// module would be correctly rejected by the attribution filter as "not the SDK's".
    static func simulateCrash(_ reason: String = "Simula debug: forced crash to test crash telemetry") {
        NSException(name: NSExceptionName("SimulaDebugForcedCrash"), reason: reason, userInfo: nil).raise()
    }
}
#endif
