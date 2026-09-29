import Foundation

#if SIMULA_DEV_ARTIFACT
/// Development artifacts only. Configure before initializing any SDK surface.
public enum SimulaDevOptions {
    /// First configuration wins; false means changing it requires a process restart.
    @discardableResult
    public static func configure(hidePlayableCompanion: Bool = false) -> Bool {
        ArtifactRequestOptions.selection.configure(hidden: hidePlayableCompanion)
    }
}

final class ArtifactOptionSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: Bool?

    func configure(hidden: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let selected { return selected == hidden }
        selected = hidden
        return true
    }

    @discardableResult
    func freeze() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = selected ?? false
        selected = value
        return value
    }
    func headers() -> [String: String] {
        freeze() ? ["X-Simula-Dev-Hide-Companion": "true"] : [:]
    }
}
#endif

enum ArtifactRequestOptions {
    #if SIMULA_DEV_ARTIFACT
    static let selection = ArtifactOptionSelection()
    #endif

    static func freeze() {
        #if SIMULA_DEV_ARTIFACT
        selection.freeze()
        #endif
    }

    static func headers() -> [String: String] {
        #if SIMULA_DEV_ARTIFACT
        return selection.headers()
        #else
        return [:]
        #endif
    }
}
