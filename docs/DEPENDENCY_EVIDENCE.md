# Dependency and SBOM evidence

Status: technical inventory complete; legal conclusions are not made.

```text
SBOM_STATUS = COMPLETE_TECHNICAL
SBOM_FORMAT = SPDX 2.3 JSON
SBOM_COMPONENTS = 421
SBOM_PRODUCT_SOURCE_CHANGE = NO
DEPENDENCY_SEMANTIC_CHANGE = NO
LICENSE_CONCLUSIONS = NOASSERTION
```

## Resolved inventory

| Ecosystem/scope | Components | Source evidence |
|---|---:|---|
| Protocol/npm lock | 103 | `protocol/pnpm-lock.yaml` |
| Android debug runtime | 158 | Gradle `debugRuntimeClasspath` |
| Android debug unit test | 163 | Gradle `debugUnitTestRuntimeClasspath` |
| Android build classpath | 152 | Gradle `buildEnvironment` |
| Android union represented in SBOM | 314 | `sbom/evidence/android-*.txt` |
| iOS SwiftPM | 4 | Xcode 26.6 resolution from main CI run `32814279959` |
| Total unique component records | 421 | `sbom/koeon-client.spdx.json` |

iOS exact packages:

- LiveKit 2.16.0
- LiveKitWebRTC 144.7559.11
- LiveKitUniFFI 0.0.6
- SwiftProtobuf 1.38.1

Android direct Google scanner dependency is `com.google.android.gms:play-services-code-scanner:16.1.0`; runtime and privacy behavior are reviewed separately in `docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md`.

## Reproduction

```sh
node scripts/collect-dependency-evidence.mjs
node scripts/collect-license-evidence.mjs
node scripts/generate-sbom.mjs
node scripts/generate-third-party-notices.mjs
```

The license collector uses exact npm registry metadata, exact Maven POM metadata and exact Swift repository tags. Missing or ambiguous declarations remain `NOASSERTION`. The SPDX document conservatively links the candidate root to every resolved component; exact transitive topology remains in the pnpm lock and Gradle evidence.

