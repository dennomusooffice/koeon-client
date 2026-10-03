# Android Public Release

KOEON Androidの正式なdirect-distribution APKは、Public repositoryのGitHub Releasesから配布します。通常のPublic PR CIはDebug buildとtestだけを行い、署名secretへアクセスできません。

## Release identity

```text
namespace = com.dennomuso.koeon
applicationId = com.dennomuso.koeon
versionName = 1.0.9
versionCode = 10
```

最初の正式Public direct-distribution release以降、`versionCode`は単調増加させます。Google Play distributionは別gateであり、このworkflowはGitHub Releaseだけを対象にします。

## 1.0.9の署名鍵変更（再インストール必須）

1.0.9（versionCode 10）は新しい署名鍵で配布します。以前の鍵では署名できなくなったため、
テスト利用者が再インストールする前提で鍵を変更しました。applicationIdは変更しません。
旧版への上書き更新はできません。旧版をアンインストールしてから新しいAPKをインストールしてください。
アンインストールにより端末内の設定・登録情報等が消える可能性があります。
必要な招待情報等を事前に確認し、インストール後に登録とマイク等の権限設定を行ってください。

新しい鍵とパスワードはMacのGit管理対象外の`.secret/android-release/`に保存しています。
紛失すると今後の上書き更新に影響するため、安全な場所へのバックアップが必要です。
GitHub Environmentの既存署名Secretsは旧鍵のままです。今後Actionsで配布する場合は、
ローカルの新しい鍵・alias・passwordへ揃えてから実行してください。

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
