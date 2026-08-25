# Google dependency and privacy review

Status: technical/privacy evidence only; no legal approval.

## Exact component

```text
artifact = com.google.android.gms:play-services-code-scanner
version = 16.1.0
relationship = direct Android runtime dependency
purpose = QR invite scanning
GOOGLE_COMPONENT_STATUS = PRIVACY_DISCLOSURE_REQUIRED
LEGAL_REVIEW_REQUIRED = YES
```

The Android UI builds `GmsBarcodeScannerOptions`, restricts scanning to QR codes, enables auto-zoom, obtains `GmsBarcodeScanning.getClient(...)`, calls `startScan()`, and passes only `Barcode.rawValue` to enrollment handling.

## Runtime behavior from official Google documentation

- The implementation is delivered by Google Play services; the app itself does not request camera permission for this scanner.
- Image processing occurs on-device. Google states it does not store image data or scan results.
- The scanner module is unbundled and may be downloaded by Google Play services when first used if it is not already installed.
- Version 16.1.0 is the documented dependency and the first version supporting the enabled auto-zoom option.

Primary source: [Google Code Scanner for Android](https://developers.google.com/ml-kit/vision/barcode-scanning/code-scanner).

## Data Safety evidence

Google's ML Kit Android disclosure guidance says developers remain responsible for their Google Play Data safety answers. For ML Kit features it documents diagnostic/usage collection including device/app information, identifiers, performance metrics, API configuration, input/output size, feature version, event type and error codes. It states collected data is encrypted in transit and not transferred to third parties.

For `play-services-code-scanner` with auto-zoom enabled, Google additionally lists a dynamically generated scan-session identifier, zoom-level changes and predicted barcode bounding-box coordinates.

Primary source: [ML Kit Android data disclosure guidance](https://developers.google.com/ml-kit/android-data-disclosure).

## Terms/privacy classification

Google API Terms require an accurate privacy policy describing user information collection/use/sharing and compliance with applicable privacy law. Primary source: [Google APIs Terms of Service](https://developers.google.com/terms).

```text
IMAGE_OR_RESULT_TRANSMISSION_TO_GOOGLE = NOT_INDICATED_BY_OFFICIAL_SCANNER_DOCS
IMAGE_OR_RESULT_STORAGE_BY_GOOGLE = NO (official scanner documentation)
DIAGNOSTIC_USAGE_DATA = PRESENT_PER_OFFICIAL_DISCLOSURE_GUIDE
AUTO_ZOOM_ADDITIONAL_DATA = PRESENT
PRIVACY_DISCLOSURE = REQUIRED
LEGAL_APPROVAL = NO
```

A7 must approve the app privacy policy and Google Play Data safety classification before publication/distribution. This audit does not decide whether any item is personal data under a particular jurisdiction.

