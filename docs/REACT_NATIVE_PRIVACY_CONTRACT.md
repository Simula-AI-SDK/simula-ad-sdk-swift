# React Native ↔ Native Privacy Contract

This document specifies what the React Native layer (`SimulaProvider.tsx` in the
host RN app, e.g. `epitaxy`) must forward to the native Simula modules so the
iOS (Swift) and Android (Kotlin) SDKs receive consent, attribution, and privacy
signals. It is the source-of-truth contract — the native side is already
implemented (`SimulaPrivacyConfig` / `SimulaPrivacy` on both platforms).

> **Key principle:** the native SDKs already **auto-read** the IAB-standard keys
> a CMP writes (`IABTCF_*`, `IABUSPrivacy_String`, `IABGPP_*`) from
> `UserDefaults` / `SharedPreferences`. So an RN app using a **native** CMP gets
> consent with *zero* prop plumbing. The props below are the **explicit override**
> path (and the only path if your CMP is JS-only).

---

## 1. Provider props

Replace the single `hasPrivacyConsent` boolean with the granular set. Keep
`hasPrivacyConsent` as a back-compat alias.

```ts
interface SimulaPrivacyProps {
  /** Legacy coarse flag. When false, suppresses PII (ppid). Default true. */
  hasPrivacyConsent?: boolean;
  /** IAB TCF v2.2 consent string. */
  tcString?: string;
  /** IAB US Privacy (CCPA) string, e.g. "1YNN". */
  uspString?: string;
  /** IAB GPP string. */
  gppString?: string;
  /** Applicable GPP section IDs, comma-separated e.g. "2,6". */
  gppSid?: string;
  /** Whether GDPR applies. Omit when unknown. */
  gdprApplies?: boolean;
  /** COPPA (child-directed). When true, suppresses ppid + IDFA/GAID. Default false. */
  coppaApplies?: boolean;
  /** Opt-in IDFA (iOS) / GAID (Android) collection. Default false. */
  enableAdvertisingId?: boolean;
}
```

These map 1:1 to the native `SimulaPrivacyConfig` (Swift `struct` / Kotlin
`data class`). Field names and semantics are identical across all three layers.

---

## 2. Bridging on mount / prop change

On mount and whenever any privacy prop changes, call the native update method
(do **not** rebuild the whole provider):

```ts
NativeModules.SimulaPrivacy.updateConsent({
  hasPrivacyConsent, tcString, uspString, gppString, gppSid,
  gdprApplies, coppaApplies, enableAdvertisingId,
});
```

Native handlers to implement in the bridge module:

| JS call | iOS (Swift) | Android (Kotlin) |
|---|---|---|
| `updateConsent(config)` | `SimulaPrivacy.shared.apply(SimulaPrivacyConfig(...))` | `SimulaPrivacy.apply(SimulaPrivacyConfig(...))` |
| `requestTrackingAuthorization()` *(iOS only)* | `await SimulaPrivacy.shared.requestTrackingAuthorization()` → resolve raw status | resolve `-1` / no-op |

> Android needs no ATT prompt. Expose `requestTrackingAuthorization` as a
> Promise that resolves immediately to a sentinel (e.g. `-1`) on Android so JS
> can call it unconditionally.

---

## 3. ATT / IDFA flow (iOS)

When `enableAdvertisingId` is true, JS should trigger the prompt from a user-ready
moment (launch or post-CMP), then let native handle gating:

```ts
if (Platform.OS === 'ios' && enableAdvertisingId) {
  const status = await NativeModules.SimulaPrivacy.requestTrackingAuthorization();
  // status: 0 notDetermined, 1 restricted, 2 denied, 3 authorized
}
```

The host app must declare `NSUserTrackingUsageDescription` in `Info.plist` and,
when enabling IDFA, add the app-level tracking privacy-manifest block — see
[IOS_APP_PRIVACY.md](./IOS_APP_PRIVACY.md) §4. Android hosts add the `AD_ID`
permission + Play Services dependency — see the Kotlin repo's
`docs/GOOGLE_PLAY_DATA_SAFETY.md`.

---

## 4. What native does with the signals (for reference)

The native SDKs forward consent to the backend automatically — JS does not build
any request:

- **Session body:** a `privacy` block on `POST /session/create`
  (`hasPrivacyConsent`, `gdprApplies`, `tcString`, `uspString`, `gppString`,
  `gppSid`, `coppaApplies`, `attStatus`, `idfa`/`gaid`).
- **Headers:** `X-Simula-Consent-*`, `X-Simula-GDPR-Applies`, `X-Simula-COPPA`,
  and `X-Simula-IDFA`/`X-Simula-GAID` on every request.
- **Client-side gating:** `ppid` dropped without consent or under COPPA;
  IDFA/GAID only when authorized, opted-in, and not COPPA; non-essential caching
  suppressed when TCF Purpose 1 is denied.

A consent change re-syncs the session so the backend always sees current signals.

---

## 5. Migration checklist (RN host)

- [ ] Add the granular props to `SimulaProvider.tsx`; keep `hasPrivacyConsent` as alias.
- [ ] Call `updateConsent(...)` on mount and on every CMP refresh.
- [ ] Wire `requestTrackingAuthorization()` (iOS) into launch / post-CMP flow.
- [ ] iOS: add `NSUserTrackingUsageDescription`; add app-level tracking manifest if IDFA on.
- [ ] Android: add `AD_ID` permission + `play-services-ads-identifier` if GAID on.
- [ ] Implement the native bridge module methods in the table above.
