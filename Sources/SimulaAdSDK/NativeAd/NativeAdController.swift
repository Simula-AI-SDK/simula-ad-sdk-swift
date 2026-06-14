#if os(iOS)
import Foundation

/// Resolves a session and performs one `POST /load/native`, mapping transport failures onto the
/// public `SimulaAdError` taxonomy per the PRD's error table. The native targeting context is read
/// from the provider, so a slot never threads it through.
///
/// A no-fill (`ad_inserted == false`) is NOT an error — it comes back as a normal `NativeAdResponse`
/// with `hasCreative == false`, and the caller collapses the slot silently. Only genuine failures
/// throw.
@MainActor
enum NativeAdController {
    static func load(
        provider: SimulaProvider,
        adUnitId: String?,
        position: Int
    ) async throws -> NativeAdResponse {
        let sessionId = await provider.ensureSession()
        guard let sessionId, !sessionId.isEmpty else { throw SimulaAdError.noSession }

        do {
            return try await SimulaAPI().loadNative(
                position: position,
                sessionId: sessionId,
                adUnitId: adUnitId,
                context: provider.adContext
            )
        } catch let SimulaAPIError.httpError(code) where code == 401 {
            // Bad/unknown session — non-retryable (PRD).
            throw SimulaAdError.noSession
        } catch let apiError as SimulaAPIError {
            throw SimulaAdError.network(apiError)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SimulaAdError.network(.invalidResponse)
        }
    }
}
#endif
