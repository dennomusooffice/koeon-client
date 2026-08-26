# iOS TestFlight内部検証リリース

この文書は、Public repositoryのままApple署名を行うためのsecurity boundaryを定義します。商用配布、App Store公開、外部TestFlight、署名済み成果物の一般配布を承認するものではありません。

```text
A7_COMMERCIAL_BINARY_GATE = BLOCKED
JAIN_SIP_COMMERCIAL_BINARY_GATE = REVIEW_REQUIRED
GOOGLE_COMMERCIAL_PRIVACY_GATE = REVIEW_REQUIRED
```

## Trust boundary

通常の`.github/workflows/public-ci.yml`は`pull_request`と`main`への`push`で動作しますが、secretを参照せず、署名・archive・uploadを行いません。

署名用`.github/workflows/ios-testflight-internal.yml`は`workflow_dispatch`でしか開始できません。dispatch元はprotected default `main`に限定し、secretを参照するmacOS jobにはGitHub Environment `testflight-internal`を必須とします。Environment approval前に、Linuxのread-only trust gateが指定sourceを検証します。

指定できるsource authorityは次のいずれかです。

- protected `main`の祖先であるfull commit SHA
- 同一repository内のauthorized maintainerによるopen PRのexact head SHA。Human指定tree SHAとの一致と、Protocol、Android、Publication Safety、Public CI Security、iOS Simulatorの成功を必須とする

fork SHA、unknown SHA、short SHA、branch名だけの指定、tree mismatch、必要CIの不足・失敗は拒否します。`pull_request_target`、`workflow_run`、issue comment経由のprivileged executionは使用しません。

## GitHub Environment

Environment名は`testflight-internal`です。

```text
Required reviewer = dennomusooffice
Prevent self-review = NO
Deployment branch policy = protected/default main
Concurrency = one deployment at a time; cancel disabled
```

必要なEnvironment secretsは次の2件だけです。

- `IOS_APP`: App Store Connect APIのKey ID、Issuer ID、private p8を含む既存credential contract
- `KOEON_API_BASE_URL`: `https`のabsolute URL。credential、query、fragmentを含めない

Environment variablesは次の3件です。

- `APPLE_TEAM_ID`
- `KOEON_BUNDLE_ID`
- `KOEON_ASSOCIATED_DOMAIN`

secret値はrepository、workflow、log、step summary、artifactへ保存しません。GitHub APIから既存secret plaintextを読み戻す運用も行いません。

## Exact input contract

dispatchでは次をHumanが指定します。

```text
mode = CANDIDATE_ONLY | TESTFLIGHT_UPLOAD
client_sha = full 40-hex commit SHA
expected_tree_sha = full 40-hex Git tree SHA
marketing_version = two or three numeric components
build_number = unused positive integer
what_to_test = internal tester note
upload_confirmation = TESTFLIGHT_UPLOAD時のみUPLOAD_TESTFLIGHT
```

`TESTFLIGHT_UPLOAD`はconfirmation文字列だけでは開始できません。Environment required reviewerによる別のHuman approvalも必要です。

## Candidateとuploadの分離

`CANDIDATE_ONLY`は次の順で処理します。

1. exact SHA/treeをclean checkoutして再attestationする。
2. App Store Connect authenticationとbuild number未使用を確認する。
3. fresh Swift package stateとDerivedDataでarchiveする。
4. Environment secretのruntime URLをbuild settingから注入する。Swift sourceをpatchしない。
5. production APS、PushToTalk、Associated Domainsを持つ一時Release entitlementsを適用する。
6. neutralなinternal-test AppIconを一時生成する。official logo/AppIconは使用しない。
7. cloud signing後、signature、provisioning、entitlements、runtime endpoint、version/build、runtime frameworkを検証する。
8. signed IPAのSHA-256だけをsanitized evidenceとしてstep summaryへ残す。
9. archive、IPA、credential、AppIcon、entitlements、runtime一時情報を削除する。

signed IPAをGitHub Actions artifactとしてuploadしません。

後日Humanが`TESTFLIGHT_UPLOAD`を承認した場合は、同一のexact SHA/treeをclean stateから再build・再sign・再検証し、そのrun内からApp Store Connectへ直接uploadします。candidateのIPAを再利用しません。

## Release entitlements audit

`ios/KOEON/KOEON.Release.entitlements`はcapabilityのPublic-safe templateです。

| Difference from development | Classification | Handling |
|---|---|---|
| `aps-environment = production` | `PUBLIC_SAFE_CAPABILITY` | internal distribution signingで必要 |
| `com.apple.developer.push-to-talk = true` | `PUBLIC_SAFE_CAPABILITY` |既存Product capability |
| Associated DomainsのEnvironment variable placeholder | `PUBLIC_SAFE_CAPABILITY` |実値はEnvironment variableから一時plistへ展開 |
| Apple private key / provisioning material | `SECRET` |commit禁止、`$RUNNER_TEMP`だけでmaterialize |
| official logo/AppIcon | `BRAND_PRIVATE` |使用禁止、neutral iconを一時生成 |

秘密値やbrand assetをRelease entitlementsへ埋め込みません。

## Manual test procedure

このworkflowをmerge後に初めて使う場合は、次を確認します。

1. protected `main`からworkflowを開く。
2. Human-approved full commit SHAとtree SHAを入力する。
3. 初回は`CANDIDATE_ONLY`を選ぶ。
4. `testflight-internal`のrequired reviewer画面でexact inputを再確認する。
5. candidate summaryにsource SHA/tree、version/build、SHA-256、artifact retention `NO`が表示されることを確認する。
6. workflow終了後、signed IPA artifactとcredential artifactが存在しないことを確認する。

## Known limitations

- GitHub-hosted macOS runnerでの最初の実signingは別Human Gateです。本architecture作成だけではbilling/signing成功を証明しません。
- Environment secretのplaintextは移行できません。安全なlocal copyがない場合はHumanがGitHub UIから再登録する必要があります。
- TestFlight upload後のApple processing確認とphysical acceptanceは後続TASKで扱います。
