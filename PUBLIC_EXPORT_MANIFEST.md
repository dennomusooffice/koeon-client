# Public Export Manifest（公開export manifest）

```text
source repository = dennomusooffice/koeon (PRIVATE)
source branch = main
source main SHA = 2158c6fbb18a0004eade7650162ebbc9a512d666
export timestamp = 2026-08-25T12:45:31+09:00
export method = ALLOWLIST-BASED CLEAN-ROOT
source Git history copied = NO
public status at export timestamp = NOT AUTHORIZED
```

## 含まれるroot

- `ios/` — source file 30件
- `android/` — source file 65件
- `protocol/src/` — safe shared subsetから移動したsource file 8件
- 新規作成したgeneric docs、test configuration、safety script、public CI candidate

## 除外したroot / category

- Web applicationとdeferred Web client
- server / API implementation、auth / membership / Floor backend、token signing、APNs provider、persistent-listening backend
- database / migration、Admin / Billing、Production deployment / operation
- legacy event landing page / document、raw asset、sanitized screenshot derivative
- private task / audit evidence、private access code、signing material、build / cache output
- private Git historyのすべて

## Sanitized source path

このderivativeだけで18 source fileを変更しました。対象は、Xcode team / bundle / AppIcon setting、iOS API / invite / LiveKit host、queue / Keychain identifier、Info.plist、development entitlementとfixture、Android application ID / API default、manifest host / icon verification、LiveKit / invite fixture、synthetic workspace / user fixtureです。Androidのlicense-metadata packaging exclusionは削除しました。

安全な初期値には`example.invalid`と`livekit.example.invalid`を使用します。実在するendpoint credentialは含まれません。

## 現在のソース公開判断と独立したcommercial gate

- `A7_SOURCE_HUMAN_GATE = PASS`はHuman risk decisionによるものです。formal counsel reviewは実施していません。
- KOEON rights holderが権利を管理するsource codeには`PUBLIC_SOURCE_LICENSE = MPL-2.0`を適用します。
- `KOEON_RIGHTS_OWNER_DISPLAY = 電脳夢創企画（個人事業）`です。
- third-party dependencyにはそれぞれのlicenseとtermsが適用されます。technical evidenceは法的compatibilityを主張しません。
- `EXTERNAL_CORE_PRS = CLOSED_INITIAL`です。外部codeを受け入れる前にCLAまたは同等のrights-chain processが必要です。
- `A7_COMMERCIAL_BINARY_GATE = BLOCKED`です。
- `JAIN_SIP_COMMERCIAL_BINARY_GATE = REVIEW_REQUIRED`です。
- `GOOGLE_COMMERCIAL_PRIVACY_GATE = REVIEW_REQUIRED`です。
- iOS AppIconは、Humanが公開を承認した必要最小限のbrand assetとして、由来とblobを固定して含めます。公式logo packとその他のbrand assetの公開はdeferredです。
- historical invite / Production reviewは、このpublic client repositoryの対象外です。

```text
REMOTE_CONFIGURATION_AUTHORIZED = NO
FORMAL_COUNSEL_REVIEW = NOT_PERFORMED
COMMERCIAL_ANDROID_IOS_DISTRIBUTION = SEPARATE_GATE_REQUIRED
```
