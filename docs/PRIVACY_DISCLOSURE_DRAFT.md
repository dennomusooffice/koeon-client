# Privacy disclosure input — Human/legal draft

This document is technical input for a future privacy policy and store disclosures. It is not an approved privacy policy.

## Google Code Scanner

- Component: `com.google.android.gms:play-services-code-scanner:16.1.0`.
- Purpose: scan a QR invite and return its decoded value to the app.
- Camera/image handling: Google documents on-device processing and states it does not store images or scan results.
- Module delivery: Google Play services may download the unbundled scanner module.
- General ML Kit diagnostics/analytics: device/app information, identifiers, performance/configuration/size/version/event/error metadata are documented by Google.
- Auto-zoom: enabled by KOEON; Google documents scan-session ID, zoom changes and predicted barcode bounding-box coordinates as additional collected data.

The decoded invite value is handled by KOEON enrollment logic. It must not be logged or placed in public diagnostics.

## Human/legal fields required before publication

```text
DATA_CONTROLLER = HUMAN_TBD
PUBLIC_PRIVACY_CONTACT = HUMAN_TBD
RETENTION_DISCLOSURE = HUMAN_TBD
JURISDICTIONAL_BASIS = COUNSEL_TBD
GOOGLE_PLAY_DATA_SAFETY_ANSWERS = HUMAN_TBD
APPLE_PRIVACY_DISCLOSURE = HUMAN_TBD
PRIVACY_POLICY_APPROVED = NO
```

Primary technical sources are linked in `docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md`.

