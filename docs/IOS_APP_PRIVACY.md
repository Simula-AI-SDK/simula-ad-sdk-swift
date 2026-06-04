# iOS App Privacy Guide for Simula Ad SDK (Swift)

This document helps you complete the **App Privacy** section in App Store Connect and configure your iOS app for Simula Ad SDK compliance.

---

## Quick Setup Checklist

- [ ] Verify `PrivacyInfo.xcprivacy` is bundled (automatic via SPM)
- [ ] Add SKAdNetwork identifiers to `Info.plist`
- [ ] Complete App Privacy nutrition labels in App Store Connect
- [ ] Update your Privacy Policy

---

## 1. Privacy Manifest (iOS 17+ Required)

### Automatic via SPM

The `PrivacyInfo.xcprivacy` is bundled as a resource inside the `SimulaAdSDK` Swift package. When you add the SDK via Swift Package Manager, Xcode automatically aggregates it into your app's privacy report. **No manual file copying required.**

### What's Declared

| API Category | Reason Code | Why We Use It |
|--------------|-------------|---------------|
| User Defaults | CA92.1 | Store consent state locally |
| System Boot Time | 35F9.1 | Measure viewability timing |

Collected data types declared: *Other Usage Data*, *Other Data* (contextual), and
*Device ID* — all **not linked, not tracking** (temporary session IDs, not IDFA).
IDFA is opt-in and declared at the app level only (see §4).

### Verification

After building, check your app's privacy report:
1. Product → Archive
2. Distribute App → App Store Connect
3. Review "Privacy Report" in the distribution wizard

---

## 2. SKAdNetwork Configuration

### Installation

Add these entries to your app's `Info.plist`:

```xml
<key>SKAdNetworkItems</key>
<array>
    <!-- Simula Ad Network -->
    <dict>
        <key>SKAdNetworkIdentifier</key>
        <string>simula123456.skadnetwork</string>
    </dict>

    <!-- Google Ads -->
    <dict>
        <key>SKAdNetworkIdentifier</key>
        <string>cstr6suwn9.skadnetwork</string>
    </dict>

    <!-- Meta/Facebook -->
    <dict>
        <key>SKAdNetworkIdentifier</key>
        <string>v9wttpbfk9.skadnetwork</string>
    </dict>
    <dict>
        <key>SKAdNetworkIdentifier</key>
        <string>n38lu8286q.skadnetwork</string>
    </dict>

    <!-- See docs/SKAdNetworkItems.plist for full list -->
</array>
```

Or copy all entries from `docs/SKAdNetworkItems.plist`.

### Why SKAdNetwork?

- Enables privacy-preserving ad attribution on iOS 14+
- Advertisers can measure campaign performance without tracking users
- Higher CPMs because advertisers can prove ROI

---

## 3. App Store Connect Privacy Labels

When submitting your app, complete the App Privacy section with these responses:

### Data Linked to You: **No**

Simula SDK does NOT link collected data to user identity.

### Data Used to Track You: **No**

Simula SDK does NOT track users across apps or websites.

### Data Types Collected

#### Usage Data → Product Interaction

| Question | Answer |
|----------|--------|
| Collected? | Yes |
| Linked to identity? | No |
| Used for tracking? | No |
| Purpose | Third-Party Advertising |

> **Reason:** Ad impressions and clicks are recorded.

#### Usage Data → Advertising Data

| Question | Answer |
|----------|--------|
| Collected? | Yes |
| Linked to identity? | No |
| Used for tracking? | No |
| Purpose | Third-Party Advertising |

> **Reason:** Contextual ad targeting based on conversation content.

#### Identifiers → Device ID

| Question | Answer |
|----------|--------|
| Collected? | Yes |
| Linked to identity? | No |
| Used for tracking? | No |
| Purpose | Third-Party Advertising |

> **Reason:** Temporary session IDs (NOT IDFA).

### Data Types NOT Collected

Select "No" for all of these:

- Contact Info (name, email, phone, address)
- Health & Fitness
- Financial Info
- Location
- Sensitive Info
- Contacts
- User Content (photos, videos, audio)
- Browsing History
- Search History
- Identifiers → User ID
- Purchases
- Diagnostics

---

## 4. ATT (App Tracking Transparency) & Consent

### Default: contextual, no ATT required

Out of the box the SDK is **contextual-only**: it does **not** read the IDFA,
does not track across apps, and its bundled `PrivacyInfo.xcprivacy` keeps
`NSPrivacyTracking = false`. Most integrations need no ATT prompt.

### Passing consent signals (GDPR / CCPA / GPP / COPPA)

The SDK consumes — it does not gather — consent. Supply signals two ways:

1. **Automatic (recommended).** If your app uses an IAB-registered CMP, the SDK
   auto-reads the standard `UserDefaults` keys it writes (`IABTCF_TCString`,
   `IABTCF_gdprApplies`, `IABTCF_PurposeConsents`, `IABUSPrivacy_String`,
   `IABGPP_HDR_GppString`, `IABGPP_GppSID`) and refreshes when they change.
2. **Explicit overrides** via `SimulaPrivacyConfig`:

```swift
SimulaProviderView(
    apiKey: "your-key",
    privacy: SimulaPrivacyConfig(
        tcString: tc, uspString: usp, gppString: gpp,
        coppaApplies: false
    )
) { ContentView() }
```

Refresh at runtime when your CMP updates (handle inside child views via
`@EnvironmentObject var simula: SimulaProvider`):

```swift
simula.updateConsent(tcString: newTC, gppString: newGPP)
```

`coppaApplies: true` suppresses the `ppid` and the IDFA regardless of ATT.

**Storage degradation (TCF Purpose 1).** When Purpose 1 ("store/access information
on a device") is denied — or GDPR applies and it's unknown — the SDK's WebViews use
a **non-persistent** `WKWebsiteDataStore`: cookies and `localStorage` work in memory
for the session but nothing is written to disk. If you don't use a TCF CMP you can
drive this directly with `SimulaPrivacyConfig(tcfPurpose1Consent: false)`.

### Enabling IDFA attribution (opt-in)

IDFA collection is **off by default**. To turn it on:

**1. Opt in** when configuring the provider:

```swift
SimulaProviderView(
    apiKey: "your-key",
    privacy: SimulaPrivacyConfig(enableAdvertisingId: true)
) { ContentView() }
```

**2. Request authorization** (the SDK reads the IDFA only on `.authorized`):

```swift
// From your launch flow or a post-CMP callback:
await simula.requestTrackingAuthorization()
```

**3. Add the usage string** to your app's `Info.plist`:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>This allows us to show you relevant ads based on your interests.</string>
```

**4. Declare tracking at the APP level.** Because Apple's privacy manifest is
static and the SDK keeps its bundled manifest contextual, when you enable IDFA
you must add an **app-level** `PrivacyInfo.xcprivacy` (or merge into your
existing one) declaring tracking + the IDFA data type:

```xml
<key>NSPrivacyTracking</key>
<true/>
<key>NSPrivacyTrackingDomains</key>
<array>
    <string>simula-api-701226639755.us-central1.run.app</string>
</array>
<key>NSPrivacyCollectedDataTypes</key>
<array>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeDeviceID</string>
        <key>NSPrivacyCollectedDataTypeLinked</key>
        <false/>
        <key>NSPrivacyCollectedDataTypeTracking</key>
        <true/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array>
            <string>NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising</string>
        </array>
    </dict>
</array>
```

Then update your App Store Connect nutrition labels: **Data Used to Track You →
Yes** for *Device ID*.

> ⚠️ If you do **not** enable IDFA, change nothing here — the contextual default
> keeps your app out of "tracking" territory.

---

## 5. Privacy Policy Requirements

Your app's privacy policy must disclose:

### Data Collection

```
Our app uses the Simula Ad SDK to display contextual advertisements.

The SDK collects:
- Conversation context (message content) for contextual ad targeting
- Ad interaction events (when ads are viewed or clicked)
- Temporary session identifiers

The SDK does NOT collect:
- Apple Advertising Identifier (IDFA)
- Location data
- Personal information (name, email, phone)
- Device fingerprints
```

### Third-Party Sharing

```
We share data with the following third parties for advertising purposes:
- Simula Ad Network (https://simula.ad)

Data shared includes conversation context and ad interaction metrics.
No data is sold or used for cross-app tracking.
```

### User Rights

```
You may opt out of personalized ads by:
- Declining consent when prompted in the app
- Contacting us at [your-email]

To request data deletion, contact support@simula.ad.
```

---

## 6. Common App Review Issues

### Issue: "Your app uses the AppTrackingTransparency framework"

**Cause:** Another SDK in your app uses IDFA.
**Solution:** Simula SDK doesn't require ATT. Check other SDKs.

### Issue: "Privacy nutrition labels incomplete"

**Cause:** Missing data type declarations.
**Solution:** Declare Usage Data and Identifiers per this guide.

### Issue: "Privacy manifest missing"

**Cause:** `PrivacyInfo.xcprivacy` not aggregated.
**Solution:** Verify the SimulaAdSDK package is properly added via SPM. Check the privacy report during archiving.

---

## Summary Table

| Requirement | Status | Details |
|-------------|--------|---------|
| Privacy Manifest | Included (automatic via SPM) | `PrivacyInfo.xcprivacy` |
| SKAdNetwork | Recommended | `docs/SKAdNetworkItems.plist` |
| App Privacy Labels | Required | App Store Connect |
| ATT Permission | Not required by default | Opt-in for IDFA attribution (§4) |
| Privacy Policy | Required | Your website |

---

## Questions?

Contact admin@simula.ad for App Store submission assistance.
