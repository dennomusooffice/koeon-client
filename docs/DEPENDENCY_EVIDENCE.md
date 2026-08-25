# Preliminary dependency and NOTICE evidence

Status: technical evidence only; no legal compatibility decision.

```text
SBOM_STATUS = PARTIAL
NOTICE_STATUS = PARTIAL
MPL_2_0 = PREFERRED / REVIEW
LEGAL_PRIVACY_REVIEW_REQUIRED = YES
A7_LEGAL_GATE = BLOCKED
```

## Evidence captured for A5

| Ecosystem | Evidence | Result |
|---|---|---|
| Protocol/TypeScript | `protocol/pnpm-lock.yaml` | 103 resolved package entries; SHA-256 `5301B76582D1610A02B795356F0EC202DC7E20C8D9B44B5356DD99A05E342D35` |
| Android runtime | Gradle `debugRuntimeClasspath` resolution | 158 unique resolved coordinates |
| Android direct declarations | Gradle build files and existing inventory | exact direct versions retained |
| iOS | Xcode project exact SPM pin | LiveKit Swift 2.16.0; full resolved graph awaits the authorized macOS CI run |
| Project license candidate | official unmodified MPL-2.0 text | SHA-256 `3F3D9E0024B1921B067D6F7F88DEB4A60CBE7A78E76C64E3F1D7FC3B779B9D04` |

Notable resolved Android runtime coordinates include:

- `io.livekit:livekit-android:2.28.0`
- `io.github.webrtc-sdk:android-prefixed:144.7559.09`
- `com.github.davidliu:audioswitch:039a35aefab7747c557242fa216c9ea11743b604`
- `com.google.android.gms:play-services-code-scanner:16.1.0`
- `com.squareup.okhttp3:okhttp:4.12.0`
- `androidx.compose.material3:material3-android:1.4.0`
- `androidx.compose.ui:ui-android:1.11.3`

## Outstanding A6–A7 work

1. Generate a machine-readable CycloneDX/SPDX document covering Android, Swift and protocol artifacts.
2. Collect license and NOTICE text from the exact resolved artifacts, including native WebRTC/LiveKit components.
3. Review Google Code Scanner API terms and privacy/disclosure obligations.
4. Review JUnit EPL-1.0 and all bundled/transitive notices.
5. Have assigned counsel decide MPL-2.0 compatibility, Commercial OEM/dual-license structure, CLA and trademark policy.

No dependency row is marked legally compatible by this evidence. `LEGAL_BUSINESS_OWNER` and `COUNSEL` remain `HUMAN_TBD`.
