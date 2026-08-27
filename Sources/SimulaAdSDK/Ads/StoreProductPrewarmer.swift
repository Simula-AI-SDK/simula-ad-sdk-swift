import Foundation

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
    }

    private var entry: Entry?
    private var pendingKey: Key?
    var isOccupied: Bool { entry != nil }

    mutating func reserve(key: Key, makeProduct: () -> Product) -> Reservation? {
        if let current = entry {
            switch current.status {
            case .loading:
                if current.key != key { pendingKey = key }
                return nil
            case .ready:
                guard current.key != key else { return nil }
                entry = nil
            }
        }
        let token = UUID()
        let product = makeProduct()
        entry = Entry(token: token, key: key, product: product, status: .loading)
        if pendingKey == key { pendingKey = nil }
        return Reservation(token: token, product: product)
    }

    mutating func consume(key: Key) -> Product? {
        guard var current = entry, current.key == key, let product = current.product else { return nil }
        if current.status == .ready {
            entry = nil
        } else {
            // Keep a marker until the in-flight StoreKit callback returns, preventing another
            // speculative allocation while this controller is already being presented.
            current.product = nil
            entry = current
        }
        return product
    }

    mutating func complete(token: UUID, loaded: Bool) -> Completion {
        guard var current = entry, current.token == token else {
            return Completion(retainedReadyProduct: false, nextKey: nil)
        }
        if loaded, current.product != nil, pendingKey == nil {
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
}

#if os(iOS)
import StoreKit
import UIKit

private struct StoreProductPrewarmKey: Equatable {
    let appID: String
    let attribution: AdAttribution?
}

/// Process-wide, bounded StoreKit preparation. Only fullscreen ready-state hooks feed this cache;
/// native feeds deliberately stay cold to avoid product loads for dozens of unviewed ads.
@MainActor
final class StoreProductPrewarmer {
    static let shared = StoreProductPrewarmer()

    private static let maxAgeNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
    private var slot = StoreProductPrewarmSlot<StoreProductPrewarmKey, SKStoreProductViewController>()
    private var expiryTask: Task<Void, Never>?

    private init() {}

    @discardableResult
    func prewarm(appID: String, attribution: AdAttribution?) -> Bool {
        guard UIApplication.shared.applicationState == .active,
              Int(appID) != nil else { return false }

        let key = StoreProductPrewarmKey(appID: appID, attribution: attribution)
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
        let product = slot.consume(key: StoreProductPrewarmKey(appID: appID, attribution: attribution))
        if product != nil {
            expiryTask?.cancel()
            expiryTask = nil
        }
        return product
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
