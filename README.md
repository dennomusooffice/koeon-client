# KOEON Client — pre-publication staging

KOEON Client is a native iOS and Android push-to-talk client with a small, client-safe TypeScript protocol package. This clean-root repository is being prepared for Human and legal review; it is not yet approved for public release.

## Scope and boundaries

Included:

- native iOS client and XCTest suite
- native Android client and unit/lint/debug validation
- client-safe protocol constants, codecs, typecheck and tests
- public-candidate security, dependency, SBOM and governance documents

Not included:

- KOEON private server/backend, token signing or membership services
- Web client
- deployment, database, billing or administration infrastructure
- release signing, TestFlight, App Store or Play publishing pipelines
- event sites/assets, private operational material or private repository history

Safe defaults use reserved `example.invalid` hostnames. The client cannot reach an operational KOEON service without a separately authorized configuration.

## Release-readiness status

```text
PRE_PUBLICATION_STAGING = YES
PUBLICATION_AUTHORIZED = NO
LICENSE_CANDIDATE = MPL-2.0 / LEGAL REVIEW REQUIRED
EXTERNAL_CORE_PRS = CLOSED_INITIAL
CLA_STATUS = LEGAL_REVIEW_REQUIRED
```

The dependency inventory is available as an [SPDX 2.3 SBOM](sbom/koeon-client.spdx.json), with technical notice evidence in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Unknown license metadata is explicitly recorded as `NOASSERTION`.

## Layout

- `ios/` — SwiftUI client and XCTest
- `android/` — Kotlin/Compose client and tests
- `protocol/` — TypeScript protocol package and tests
- `docs/` — public-release review evidence and architecture notes
- `scripts/` — publication and public-CI safety assertions
- `sbom/` — SPDX and exact dependency evidence

## Validation

Protocol (Node.js 22+ and pnpm 10.15.0):

```sh
pnpm --dir protocol install --frozen-lockfile
pnpm --dir protocol lint
pnpm --dir protocol test
```

Android (JDK 17 and Android SDK 36):

```sh
./android/gradlew -p android testDebugUnitTest lintDebug assembleDebug --no-daemon
```

iOS requires Xcode 26.6 and an ARM64 iOS Simulator. CI resolves the exact Swift packages and runs unsigned build/XCTest with signing disabled.

Safety assertions:

```sh
bash scripts/ci-public-safety.sh
bash scripts/publication-safety.sh
```

## Project policies

- [Security policy](SECURITY.md)
- [Contribution policy](CONTRIBUTING.md)
- [Trademark policy draft](TRADEMARKS.md)
- [Public CI threat model](docs/PUBLIC_CI_SECURITY.md)
- [Dependency/license review](docs/DEPENDENCY_LICENSE_REVIEW.md)
- [Google dependency/privacy review](docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md)

No CI in this repository signs, archives, uploads or deploys software.

