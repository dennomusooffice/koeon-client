# SBOM evidence

`koeon-client.spdx.json` is the A6 technical Software Bill of Materials in SPDX 2.3 JSON format.

```text
COMPONENTS = 421
PROTOCOL_NPM = 103
ANDROID_MAVEN = 314
IOS_SWIFTPM = 4
NOASSERTION_LICENSES = 52
PRODUCT_SOURCE_CHANGE = NO
DEPENDENCY_SEMANTIC_CHANGE = NO
```

Evidence inputs are retained under `sbom/evidence/`:

- exact pnpm lock data remains in `protocol/pnpm-lock.yaml`;
- Android runtime/test/build coordinates are Gradle-resolved outputs;
- iOS packages are exact Xcode 26.6 SwiftPM resolution from validated main CI;
- license evidence comes from exact npm registry metadata, Maven POMs and exact Swift repository tags.

`NOASSERTION` is intentional where metadata is absent, ambiguous or governed by non-open-source SDK terms. The SBOM's `licenseConcluded` values remain `NOASSERTION`; A6 does not make legal conclusions.

Run the scripts documented in `docs/DEPENDENCY_EVIDENCE.md` to regenerate the evidence without changing dependency versions.

