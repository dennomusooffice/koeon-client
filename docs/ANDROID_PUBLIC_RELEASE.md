# Android Public Release

KOEON Androidの正式なdirect-distribution APKは、Public repositoryのGitHub Releasesから配布します。通常のPublic PR CIはDebug buildとtestだけを行い、署名secretへアクセスできません。

## Release identity

```text
namespace = com.dennomuso.koeon
applicationId = com.dennomuso.koeon
versionName = 1.0.0
versionCode = 1
```

最初の正式Public direct-distribution release以降、`versionCode`は単調増加させます。Google Play distributionは別gateであり、このworkflowはGitHub Releaseだけを対象にします。

## Runtime configuration

Debug/local buildは`https://example.invalid`へfail-closedします。Release buildではprotected input `KOEON_API_BASE_URL`が必須です。HTTPSでない値、credentialを含むURL、`.invalid` placeholderはbuild前に拒否します。

runtime endpointの実値をsource、PR、Actions log、reportへ記録してはいけません。

## Protected Environment

```text
Environment = android-public-release
Trigger = workflow_dispatch only
Source authority = current protected main exact SHA/TREE
```

Environment Secrets:

```text
ANDROID_KEYSTORE
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
ANDROID_STORE_PASSWORD
KOEON_API_BASE_URL
```

`ANDROID_KEYSTORE`はJKS bytesのBase64表現です。通常PR、fork PR、`pull_request_target`からこのEnvironmentへ到達する経路を作ってはいけません。

## Candidateとpublish

1. `CANDIDATE_ONLY`でexact mainをclean buildする。
2. JKS entry、certificate validity/algorithm、private-key accessを検証する。
3. `assembleRelease`、`apksigner`、application ID、non-debuggable、runtime endpoint、SHA-256を検証する。
4. Candidate PASS後だけ、同じexact SHA/TREEを`PUBLISH_GITHUB_RELEASE`でclean rebuildする。
5. `koeon-android.apk`と`SHA256SUMS.txt`だけをGitHub Releaseへ添付する。

JKS、password、certificate temp file、decoded secret、signed APKをActions artifactへ保存しません。runner上の一時signing materialは`always()` cleanupで削除します。
