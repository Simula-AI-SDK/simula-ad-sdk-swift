import Foundation

/// Pure one-entry ownership used to bound StoreKit controller allocation and make consumption
/// one-shot. A reservation token prevents an old load completion from clearing a newer entry.
struct StoreProductPrewarmSlot<Key: Equatable, Product> {
    struct Reservation {
        let token: UUID
        let product: Product
    }

    private struct Entry {
        let token: UUID
        let key: Key
        let product: Product
    }

    private var entry: Entry?
    var isOccupied: Bool { entry != nil }

    mutating func reserve(key: Key, makeProduct: () -> Product) -> Reservation? {
        guard entry == nil else { return nil }
        let token = UUID()
        let product = makeProduct()
        entry = Entry(token: token, key: key, product: product)
        return Reservation(token: token, product: product)
    }

    mutating func consume(key: Key) -> Product? {
        guard let current = entry, current.key == key else { return nil }
        entry = nil
        return current.product
    }

    @discardableResult
    mutating func remove(token: UUID) -> Bool {
        guard entry?.token == token else { return false }
        entry = nil
        return true
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
              Int(appID) != nil,
              !slot.isOccupied else { return false }

        let key = StoreProductPrewarmKey(appID: appID, attribution: attribution)
        guard let reservation = slot.reserve(
            key: key,
            makeProduct: { SKStoreProductViewController() }
        ) else { return false }

        let start = DispatchTime.now().uptimeNanoseconds
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            await self?.expire(token: reservation.token)
        }
        reservation.product.loadProduct(
            withParameters: CreativeCTARouter.storeProductParameters(
                appID: appID,
                attribution: attribution
            )
        ) { [weak self] loaded, _ in
            Task { @MainActor [weak self] in
                self?.didComplete(token: reservation.token, loaded: loaded, startedAt: start)
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
        if !loaded, slot.remove(token: token) {
            expiryTask?.cancel()
            expiryTask = nil
        }
    }

    private func expire(token: UUID) async {
        do {
            try await Task.sleep(nanoseconds: Self.maxAgeNanoseconds)
        } catch {
            return
        }
        if slot.remove(token: token) {
            expiryTask = nil
        }
    }
}
#endif
