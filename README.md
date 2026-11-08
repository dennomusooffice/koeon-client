# KOEON Client

KOEON Clientは、iOS / Android向けのネイティブPush-to-Talk（PTT）クライアントと、クライアントで安全に利用できる小さなTypeScript protocol packageです。このclean-root repositoryに含まれるのは、公開対象として承認されたclient boundaryだけです。private serviceの実装やprivate repositoryの履歴は含まれません。

## Repositoryの対象範囲

含まれるもの:

- ネイティブiOS clientとXCTest suite
- ネイティブAndroid clientとunit / lint / debug validation
- client-safeなprotocol constants、codec、typecheck、test
- 公開候補のsecurity、dependency、SBOM、governance文書

含まれないもの:

- KOEONのprivate server/backend、token signing、membership service
- Web client
- deployment、database、billing、administration infrastructure
- Production deployment、App Store / Google Playでの一般公開設定
- event site/assets、privateな運用資料、private repositoryの履歴

安全な初期値には予約済みhostname `example.invalid`を使用しています。別途承認された設定がない限り、このclientから稼働中のKOEON serviceへ接続することはできません。

## ソース公開の状態

```text
PUBLIC_SOURCE_LICENSE = MPL-2.0
A7_SOURCE_HUMAN_GATE = PASS
FORMAL_COUNSEL_REVIEW = NOT_PERFORMED
COMMERCIAL_ANDROID_IOS_DISTRIBUTION = SEPARATE_GATE_REQUIRED
EXTERNAL_CORE_PRS = CLOSED_INITIAL
CLA_REQUIRED_BEFORE_EXTERNAL_CODE = YES
```

KOEON rights holderが権利を管理するsource codeには、[Mozilla Public License 2.0](LICENSE)を適用します。third-party dependencyには、それぞれのlicenseとtermsが引き続き適用されます。dependency inventoryは[SPDX 2.3 SBOM](sbom/koeon-client.spdx.json)として公開し、技術的なnotice evidenceは[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)に記録しています。不明なlicense metadataは`NOASSERTION`として明示します。

## 構成

- `ios/` — SwiftUI clientとXCTest
- `android/` — Kotlin / Compose clientとtest
- `protocol/` — TypeScript protocol packageとtest
- `docs/` — 公開review evidenceとarchitecture文書
- `scripts/` — publication / public CIのsafety assertion
- `sbom/` — SPDXと正確なdependency evidence

## 不具合・修正の記録

[共通製品仕様・設計・検証台帳](docs/PRODUCT_SPEC_AND_VERIFICATION.md)に、実装済みの動作、両OSの差、今後の実装予定と受入条件をまとめています。

[追跡ルールとIssue一覧](docs/BUG_TRACKING.md)から、再現条件、修正PR、配信ビルド、検証結果と残件を確認できます。開発者・AIエージェントは調査や修正の都度、関連IssueとPRを更新してください。

## BuildとTest

Macでの環境構築・ローカルビルドは[Macローカルビルド手順](docs/MACOS_LOCAL_BUILD.md)を参照してください。
Macからの内部TestFlight配布は[ローカルTestFlight手順](docs/LOCAL_TESTFLIGHT.md)を参照してください。

Protocol（Node.js 22以上、pnpm 10.15.0）:

```sh
pnpm --dir protocol install --frozen-lockfile
pnpm --dir protocol lint
pnpm --dir protocol test
```

Android（JDK 17、Android SDK 36）:

```sh
./android/gradlew -p android testDebugUnitTest lintDebug assembleDebug --no-daemon
```

iOSにはXcode 26.6とARM64 iOS Simulatorが必要です。CIではSwift packageを正確にresolveし、signingを無効にしたunsigned buildとXCTestを実行します。

Safety assertion:

```sh
bash scripts/ci-public-safety.sh
bash scripts/publication-safety.sh
```

## Project policy

- [Security policy](SECURITY.md)
- [Contribution policy](CONTRIBUTING.md)
- [Trademark policy](TRADEMARKS.md)
- [Public CI threat model](docs/PUBLIC_CI_SECURITY.md)
- [Dependency / license review](docs/DEPENDENCY_LICENSE_REVIEW.md)
- [Google dependency / privacy review](docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md)
- [日本語用語集](docs/JAPANESE_TERMINOLOGY.md)

このrepositoryのCIは、softwareのsigning、archive、upload、deployを行いません。
