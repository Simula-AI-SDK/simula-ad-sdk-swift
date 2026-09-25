# Store dwell telemetry contract

Applies to one fullscreen presentation, including its primary creative and fallback screens.
Tracking is best-effort analytics; it never gates reward delivery or performs disk/network work
inline. Store lifecycle state stays on the main thread; telemetry uses the existing pipeline.

## Events and timing

- `store_opened`: emitted only for a confirmed store visit. `duration_ms` is accumulated ad
  foreground time, not store dwell. On Android it is sampled at the successful route callback;
  on iOS it is banked when the app becomes inactive or an owned sheet covers the ad.
- `store_returned`: `duration_ms` is the visit's elapsed time. Android starts at the successful
  route callback and requires Activity pause within two seconds to confirm the visit. Its duration
  includes the route-to-pause interval. iOS starts at the owned sheet presentation signal or app-away
  signal. Both clocks include device sleep; clock semantics match, but external start boundaries differ.
- `store_abandoned`: a confirmed visit remains unresolved when the whole presentation closes.
  No duration; `end_event = ad_closed`.
- `end_event`: `sheet_dismissed` identifies an owned StoreKit sheet dismissal, `app_foreground`
  an iOS external-store proxy, and `activity_resumed` an Android proxy. Even sheet dwell measures
  the sheet interval, not user attention or a confirmed installation.
- `opens`: confirmed-visit ordinal, one-based and saturated at 1000, shared across all surfaces.
- `serve_id`: the presentation's impression/serve ID for both interstitial and rewarded store rows.

An accepted external launch with no away signal within two seconds produces `store:launch_no_pause`,
without counting an open or emitting a false abandonment. Intentional close before confirmation
silently cancels the attempt on both platforms. Close is terminal: late route callbacks cannot reopen
tracking. Browser/custom-scheme routes on iOS are excluded; Android uses its existing store-route
classification. Lifecycle proxies cannot prove which external screen actually became visible.

## Lifetime and performance

Swift has four fixed presentation-owned observers (two app, two sheet), weak callback captures,
one active sheet owner, and at most one scheduled launch timeout. Surface tokens retain distinct
sheet-routing ownership, but share a presentation ID so fallback visibility and dwell tracking survive
surface replacement. A sibling surface cannot dismiss another surface's sheet. Observers are removed
on close and deallocation. Unexpected off-main notifications hop asynchronously; they never synchronously
wait for the main thread. No observer or token history accumulates across visits.

Android uses one visit-scoped application-context screen-off receiver, removed on return, timeout,
or close, and one launch timeout. No Activity is retained. Failed receiver registration leaves
contamination unknown and records the existing bounded error signature.

No polling, additional permissions, dependencies, filesystem sampling, or direct network sends are
added. These changes do not introduce a reward/close wait for telemetry persistence or delivery.

## Deliberately limited PRD scope

`contaminated` is Android-only: true means screen-off was observed; false means observation was
installed and no screen-off was observed; absent means observation was unavailable. False is NOT a
promise that the visit was uninterrupted. Home/notification interactions inside Play are not observable
from the SDK Activity. Ordinary store navigation itself causes `onStop`, so treating every stop as
contamination would incorrectly mark normal visits.

`free_space_delta_bytes` is schema-only and is never sampled or emitted. Android sampling remains
deferred: do not add filesystem work to CTA or lifecycle callbacks. On iOS, Apple's required-reason
API restrictions do not establish an approved advertising-telemetry purpose for transmitting disk-space
deltas. A missing field is unknown, not zero and not evidence that no install occurred.

The optional single `store_visit` event proposal and inline-install/SKOverlay research remain deferred.
Deploy backend schema support before releasing SDKs to preserve the new fields. Older backend models
ignore unknown fields, so backend-first is a data-completeness requirement.

## Validation

Regression coverage includes confirmed/provisional close, stale timeouts, independent app/sheet
reasons, unrelated sheet ownership, delayed committed routes after primary teardown, subsequent fallback
visits, and observer deallocation. Real-device StoreKit/Play acceptance, sleep, suspension and return
ordering remain release smoke-test coverage; unit/simulator hooks do not prove OS behavior.
