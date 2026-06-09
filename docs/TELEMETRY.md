# Simula SDK Telemetry — Backend Contract & Behavior

In-house telemetry: the SDK reports **handled errors** and **performance metrics** to the
Simula backend so we get fleet-level visibility into SDK behavior **without** Firebase
Crashlytics/Perf (which are app-level singletons that would report into the *host app's*
project, not ours, and conflict with the host's own crash reporter).

The Swift and Kotlin SDKs emit an **identical wire format**. This document is the
authoritative contract for the backend endpoint plus a description of client behavior.

> **Status:** the SDK side ships behind the `telemetryEnabled` flag (default on). The
> `POST /v1/telemetry/events` endpoint below is a **backend deliverable**; until it exists
> in an environment, batches simply fail and are retried/dropped per the rules below — no
> SDK behavior depends on it being live.

---

## Endpoint

```
POST /v1/telemetry/events
Authorization: Bearer <apiKey>
Content-Type: application/json
X-Simula-GDPR-Applies, X-Simula-Consent-TCString, X-Simula-Consent-USP,
X-Simula-Consent-GPP, X-Simula-Consent-GPP-SID, X-Simula-Consent-Purpose1,
X-Simula-COPPA      # same consent headers the SDK already sends on tracking calls
```

Body: a single **envelope** object (below).

### Response semantics (the client maps status → action)

| Status | Client action |
|--------|---------------|
| `2xx` | **Accepted** — events dropped from the buffer. Treat as idempotent on `event_id`. |
| `4xx` (except `408`, `429`) | **Permanent** — client drops the batch (won't retry). |
| `5xx`, `408`, `429`, timeout, no connectivity | **Transient** — client keeps the batch and retries with exponential backoff (2s, 4s, 8s … capped 60s). |

The backend should be **idempotent on `event_id`** (a UUID per event) since a transient
failure after the server committed will cause a resend.

---

## Envelope

Sent once per batch; the events array follows.

| Field | Type | Notes |
|-------|------|-------|
| `sdk_version` | string | e.g. `"1.0.2"` |
| `platform` | string | `"ios"` or `"android"` |
| `os_version` | string | e.g. `"17.4.1"` / `"14"` |
| `device_model` | string | e.g. `"iPhone15,2"` / `"Google Pixel 8"` |
| `host_app_id` | string | host app bundle / package id |
| `dev_mode` | bool | mirrors SDK `devMode` |
| `session_id` | string? | the Simula session id, when established |
| `primary_user_id` | string? | PPID — **only present when consent allows** (see Privacy) |
| `advertising_id` | string? | IDFA / GAID — **only present when collected & allowed** |
| `events` | array | one or more event objects |

---

## Event object

One flat shape covers every event `type`; parse on the `type` discriminator. Absent
fields are omitted from the JSON.

| Field | Type | Applies to | Notes |
|-------|------|-----------|-------|
| `type` | string | all | `network` \| `operation` \| `ad_lifecycle` \| `error` \| `meta` |
| `name` | string | all | endpoint path / operation / stage / error signature |
| `event_id` | string | all | UUID; idempotency key |
| `timestamp` | number | all | wall-clock **epoch milliseconds** |
| `duration_ms` | number? | network/operation/lifecycle | **monotonic** elapsed ms |
| `status_code` | number? | network | HTTP status (absent on connectivity failure) |
| `request_bytes` | number? | network | request body bytes |
| `response_bytes` | number? | network | response body bytes |
| `failure_class` | string? | network | `timeout`\|`dns`\|`tls`\|`connection`\|`http_<code>`\|`unknown` |
| `success` | bool? | operation | operation outcome |
| `ad_format` | string? | lifecycle | `interstitial` \| `rewarded` |
| `ad_unit_id` | string? | lifecycle | host placement id |
| `ad_id` | string? | lifecycle | server ad id |
| `serve_id` | string? | lifecycle | rewarded serve id |
| `error_code` | string? | lifecycle/error | low-cardinality code |
| `message` | string? | error | sanitized, length-capped; never URLs/tokens/PII |
| `breadcrumb` | string? | error | call-site hint (iOS: file/func/line; Android: filtered frames) |
| `cache_hit` | bool? | operation | reserved |
| `retry_count` | number? | — | reserved |
| `count` | number? | error/meta | occurrence count for a deduped error signature / dropped count |

### Event catalog

**`network`** — one per SDK HTTP request. `name` is `"<METHOD> <path>"` (path only — no
query string, so no PII). iOS harvests `URLSessionTaskMetrics` via a session task delegate
(so DNS/connect/TLS/TTFB detail is available to add later); Android measures at the
`SimulaHttp` chokepoint. The `/v1/telemetry/events` request itself is **never** recorded
(recursion guard).

**`operation`** — timed internal operations. `name` ∈ `session_create`,
`reward_verification` (end-to-end incl. retry backoff), `image_load` / `image_decode`,
`image_cache_hit`, `webview_acquire_warm`, `webview_acquire_cold`.

**`ad_lifecycle`** — `name` (stage) ∈ `load_success`, `load_fail`, `show_fail`,
`displayed`, `click`, `closed`, `reward_earned`, `reward_verified`,
`reward_verification_failed`. `duration_ms` is latency since the previous stage where
meaningful (e.g. `displayed` = since show start). Failures carry `error_code`.

**`error`** — handled exceptions caught at SDK boundaries (e.g. `interstitial:load`,
`rewarded:load`, `rewarded:verify`). **Deduped by `name` within a flush window** with an
occurrence `count`, so high-frequency errors report a rate rather than flooding.

**`meta`** — `name="dropped"`, `count=N`: the client dropped N events under a cap (buffer
overflow or distinct-error-signature cap). Surfaces truncation rather than hiding it.

---

## Example request body

```json
{
  "sdk_version": "1.0.2",
  "platform": "ios",
  "os_version": "17.4.1",
  "device_model": "iPhone15,2",
  "host_app_id": "ad.simula.hostexample",
  "dev_mode": false,
  "session_id": "sess_f20e83011a",
  "events": [
    { "type": "network", "name": "POST /session/create", "event_id": "0c…",
      "timestamp": 1717941230000, "duration_ms": 142, "status_code": 200,
      "request_bytes": 256, "response_bytes": 1024 },
    { "type": "ad_lifecycle", "name": "load_success", "event_id": "1a…",
      "timestamp": 1717941231000, "ad_format": "interstitial",
      "ad_unit_id": "placement_1", "ad_id": "ad_77", "duration_ms": 380 },
    { "type": "operation", "name": "reward_verification", "event_id": "2b…",
      "timestamp": 1717941238000, "duration_ms": 5120, "success": true },
    { "type": "error", "name": "rewarded:verify", "event_id": "3c…",
      "timestamp": 1717941240000, "error_code": "URLError",
      "message": "The request timed out.", "count": 4 }
  ]
}
```

---

## Server-side control (recommended, optional)

The `/session/create` **response** may carry a telemetry directive the SDK applies for the
rest of the session — a runtime kill-switch and perf sampling rate, so volume can be dialed
without an SDK release:

```json
{ "sessionId": "sess_…", "telemetry_enabled": true, "telemetry_sample_rate": 0.25 }
```

- `telemetry_enabled: false` — the SDK stops sending (errors and perf) for the session.
- `telemetry_sample_rate` — fraction of **sessions** sampled in for **perf** events
  (`0.0`–`1.0`). **Errors are always sent** regardless of sampling (they're low-volume,
  deduped). Absent fields → SDK defaults (enabled, rate 1.0).

---

## Client behavior (for reference)

- **Batched + durable.** Events buffer in memory and persist to `UserDefaults` /
  `SharedPreferences`; errors persist immediately (most likely to precede a process kill)
  and trigger an eager flush. The buffer is recovered and flushed on next launch.
- **Flush triggers:** ~20 buffered events, ~30s timer, app background, or an error.
- **Bounded:** buffer caps at ~200 events (oldest dropped), distinct error signatures at
  ~50; both emit a `meta`/`dropped` count.
- **Monotonic durations** (`DispatchTime` / `nanoTime`); wall-clock only for `timestamp`.

## Privacy & consent

- PII (`primary_user_id`, `advertising_id`) is gated on the **same consent snapshot** as ad
  tracking and **suppressed under COPPA** — re-checked at each flush, so a consent change is
  honored. Performance/error events themselves carry no identity.
- Endpoint `name`s are **paths only** (no query params); error `message`s are sanitized and
  length-capped. The privacy manifest declares Performance Data + Crash Data
  (not identity-linked, not tracking).
- Host apps can disable telemetry entirely via `telemetryEnabled = false` at SDK init.
