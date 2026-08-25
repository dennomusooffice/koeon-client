# KOEON Client

KOEON Client is a native iOS and Android push-to-talk client with a small, client-safe TypeScript protocol package. This clean-root source repository contains only the approved public-client boundary; private service implementations and private repository history are not included.

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

## Source release status

```text
PUBLIC_SOURCE_LICENSE = MPL-2.0
A7_SOURCE_HUMAN_GATE = PASS
FORMAL_COUNSEL_REVIEW = NOT_PERFORMED
COMMERCIAL_ANDROID_IOS_DISTRIBUTION = SEPARATE_GATE_REQUIRED
EXTERNAL_CORE_PRS = CLOSED_INITIAL
CLA_REQUIRED_BEFORE_EXTERNAL_CODE = YES
```

Source code controlled by the KOEON rights holder is licensed under the [Mozilla Public License 2.0](LICENSE). Third-party dependencies remain under their own licenses and terms. The dependency inventory is available as an [SPDX 2.3 SBOM](sbom/koeon-client.spdx.json), with technical notice evidence in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Unknown license metadata is explicitly recorded as `NOASSERTION`.

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
- [Trademark policy](TRADEMARKS.md)
- [Public CI threat model](docs/PUBLIC_CI_SECURITY.md)
- [Dependency/license review](docs/DEPENDENCY_LICENSE_REVIEW.md)
- [Google dependency/privacy review](docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md)

No CI in this repository signs, archives, uploads or deploys software.

