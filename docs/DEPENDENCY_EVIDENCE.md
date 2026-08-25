# Dependency / SBOM evidence（依存関係証跡）

状態: technical inventoryはcompleteです。法的結論は示しません。

```text
SBOM_STATUS = COMPLETE_TECHNICAL
SBOM_FORMAT = SPDX 2.3 JSON
SBOM_COMPONENTS = 421
SBOM_PRODUCT_SOURCE_CHANGE = NO
DEPENDENCY_SEMANTIC_CHANGE = NO
LICENSE_CONCLUSIONS = NOASSERTION
```

## Resolve済みinventory

| Ecosystem / scope | Component数 | Source evidence |
|---|---:|---|
| Protocol/npm lock | 103 | `protocol/pnpm-lock.yaml` |
| Android debug runtime | 158 | Gradle `debugRuntimeClasspath` |
| Android debug unit test | 163 | Gradle `debugUnitTestRuntimeClasspath` |
| Android build classpath | 152 | Gradle `buildEnvironment` |
| Android union represented in SBOM | 314 | `sbom/evidence/android-*.txt` |
| iOS SwiftPM | 4 | Xcode 26.6 resolution from main CI run `32814279959` |
| Total unique component records | 421 | `sbom/koeon-client.spdx.json` |

iOS exact package:

- LiveKit 2.16.0
- LiveKitWebRTC 144.7559.11
- LiveKitUniFFI 0.0.6
- SwiftProtobuf 1.38.1

Androidのdirect Google scanner dependencyは`com.google.android.gms:play-services-code-scanner:16.1.0`です。runtimeとprivacy behaviorは`docs/GOOGLE_DEPENDENCY_PRIVACY_REVIEW.md`で別途reviewしています。

## 再生成

```sh
node scripts/collect-dependency-evidence.mjs
node scripts/collect-license-evidence.mjs
node scripts/generate-sbom.mjs
node scripts/generate-third-party-notices.mjs
```

license collectorは、正確なnpm registry metadata、Maven POM metadata、Swift repository tagを使用します。宣言が存在しない、または曖昧な場合は`NOASSERTION`のままです。SPDX documentではcandidate rootをすべてのresolved componentへ保守的にlinkし、正確なtransitive topologyはpnpm lockとGradle evidenceに保持します。

