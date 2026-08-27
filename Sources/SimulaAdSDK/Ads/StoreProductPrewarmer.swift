import Foundation

enum StoreProductPrewarmMiss: String, Equatable {
    case empty
    case keyMismatch = "key_mismatch"
    case alreadyConsumed = "already_consumed"
    case disabled
}

enum StoreProductPrewarmLookup<Product> {
    case hit(Product, ready: Bool)
    case miss(StoreProductPrewarmMiss)
}

/// Pure one-entry ownership used to bound StoreKit controller allocation and make consumption
/// one-shot. A reservation token prevents an old load completion from clearing a newer entry.
struct StoreProductPrewarmSlot<Key: Equatable, Product> {
    struct Completion {
        let retainedReadyProduct: Bool
        let nextKey: Key?
    }

    struct Reservation {
        let token: UUID
        let product: Product
    }

    private enum Status {
        case loading
        case ready
    }

    private struct Entry {
        let token: UUID
        let key: Key
        var product: Product?
        var status: Status
        var useEnabled: Bool
    }

    private var entry: Entry?
    private var pendingKey: Key?
    var isOccupied: Bool { entry != nil }

    mutating func reserve(key: Key, makeProduct: () -> Product) -> Reservation? {
        if let current = entry {
            switch current.status {
            case .loading:
                if current.key != key || !current.useEnabled { pendingKey = key }
                return nil
            case .ready:
                guard current.key != key else { return nil }
                entry = nil
            }
        }
        let token = UUID()
        let product = makeProduct()
        entry = Entry(token: token, key: key, product: product, status: .loading, useEnabled: true)
        if pendingKey == key { pendingKey = nil }
        return Reservation(token: token, product: product)
    }

    mutating func consume(key: Key) -> Product? {
        guard case .hit(let product, _) = lookup(key: key) else { return nil }
        return product
    }

    mutating func lookup(key: Key) -> StoreProductPrewarmLookup<Product> {
        guard var current = entry else { return .miss(.empty) }
        guard current.key == key else {
            if pendingKey == key { pendingKey = nil }
            return .miss(.keyMismatch)
        }
        guard current.useEnabled else {
            if pendingKey == key { pendingKey = nil }
            return .miss(.disabled)
        }
        guard let product = current.product else {
            if pendingKey == key { pendingKey = nil }
            return .miss(.alreadyConsumed)
        }
        let ready = current.status == .ready
        if current.status == .ready {
            entry = nil
        } else {
            // Keep a marker until the in-flight StoreKit callback returns, preventing another
            // speculative allocation while this controller is already being presented.
            current.product = nil
            entry = current
        }
        return .hit(product, ready: ready)
    }

    mutating func complete(token: UUID, loaded: Bool) -> Completion {
        guard var current = entry, current.token == token else {
            return Completion(retainedReadyProduct: false, nextKey: nil)
        }
        if loaded, current.product != nil, current.useEnabled, pendingKey == nil {
            current.status = .ready
            entry = current
            return Completion(retainedReadyProduct: true, nextKey: nil)
        }
        entry = nil
        let next = pendingKey
        pendingKey = nil
        return Completion(retainedReadyProduct: false, nextKey: next)
    }

    mutating func expire(token: UUID) -> Key? {
        guard entry?.token == token else { return nil }
        entry = nil
        let next = pendingKey
        pendingKey = nil
        return next
    }

    mutating func disable() {
        pendingKey = nil
        guard var current = entry else { return }
        if current.status == .loading {
            // StoreKit has no cancellation API. Retain the controller as a disabled marker until
            // its callback returns so another speculative load cannot overlap it.
            current.useEnabled = false
            entry = current
        } else {
            entry = nil
        }
    }

}

#if os(iOS)
import StoreKit
import UIKit

private struct StoreProductPrewarmKey: Equatable {
    let appID: String
    let attribution: AdAttribution?
}

/// Process-wide, bounded StoreKit preparation. Only displayed fullscreen ads feed this cache;
/// native feeds deliberately stay cold to avoid product loads for dozens of unviewed ads.
@MainActor
final class StoreProductPrewarmer {
    static let shared = StoreProductPrewarmer()

    private static let maxAgeNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
    private var slot = StoreProductPrewarmSlot<StoreProductPrewarmKey, SKStoreProductViewController>()
    private var expiryTask: Task<Void, Never>?
    private var lastAttemptedKey: StoreProductPrewarmKey?

    private init() {}

    @discardableResult
    func prewarm(appID: String, attribution: AdAttribution?) -> Bool {
        guard UIApplication.shared.applicationState == .active,
              Int(appID) != nil else { return false }

        let key = StoreProductPrewarmKey(appID: appID, attribution: attribution)
        lastAttemptedKey = key
        return startPrewarm(key: key)
    }

    private func startPrewarm(key: StoreProductPrewarmKey) -> Bool {
        guard let reservation = slot.reserve(
            key: key,
            makeProduct: { SKStoreProductViewController() }
        ) else { return false }

        let start = DispatchTime.now().uptimeNanoseconds
        expiryTask?.cancel()
        expiryTask = nil
        let token = reservation.token
        reservation.product.loadProduct(
            withParameters: CreativeCTARouter.storeProductParameters(
                appID: key.appID,
                attribution: key.attribution
            )
        ) { [weak self] loaded, _ in
            Task { @MainActor [weak self] in
                self?.didComplete(token: token, loaded: loaded, startedAt: start)
            }
        }
        return true
    }

    func take(appID: String, attribution: AdAttribution?) -> SKStoreProductViewController? {
        let requestedKey = StoreProductPrewarmKey(appID: appID, attribution: attribution)
        switch slot.lookup(key: requestedKey) {
        case .hit(let product, let ready):
            expiryTask?.cancel()
            expiryTask = nil
            Telemetry.shared.recordOperation(
                name: "store_product_prewarm_use",
                durationMs: 0,
                success: true,
                breadcrumb: "result=hit_\(ready ? "ready" : "loading")"
            )
            if lastAttemptedKey == requestedKey { lastAttemptedKey = nil }
            return product
        case .miss(let reason):
            if lastAttemptedKey == requestedKey {
                Telemetry.shared.recordOperation(
                    name: "store_product_prewarm_use",
                    durationMs: 0,
                    success: false,
                    failureClass: reason.rawValue,
                    breadcrumb: "result=miss"
                )
                if lastAttemptedKey == requestedKey { lastAttemptedKey = nil }
            }
            return nil
        }
    }

    func disable() {
        slot.disable()
        expiryTask?.cancel()
        expiryTask = nil
        lastAttemptedKey = nil
    }

    private func didComplete(token: UUID, loaded: Bool, startedAt: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        Telemetry.shared.recordOperation(
            name: "store_product_prewarm",
            durationMs: Int(elapsed / 1_000_000),
            success: loaded,
            failureClass: loaded ? nil : "load_failed"
        )
        let completion = slot.complete(token: token, loaded: loaded)
        if completion.retainedReadyProduct {
            expiryTask = Task { [weak self] in
                await self?.expire(token: token)
            }
        } else if let nextKey = completion.nextKey,
                  UIApplication.shared.applicationState == .active {
            _ = startPrewarm(key: nextKey)
        }
    }

    private func expire(token: UUID) async {
        do {
            try await Task.sleep(nanoseconds: Self.maxAgeNanoseconds)
        } catch {
            return
        }
        let nextKey = slot.expire(token: token)
        expiryTask = nil
        if let nextKey, UIApplication.shared.applicationState == .active {
            _ = startPrewarm(key: nextKey)
        }
    }
}
#endif
