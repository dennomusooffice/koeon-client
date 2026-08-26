# Public CI security model（公開CIのsecurity設計）

状態: public-client CI security policy。通常のuntrusted PR CIと、Human-approved internal TestFlight releaseを別trust domainとして管理します。

## Trust boundary

pull-request contentはuntrustedとして扱います。workflowがuntrustedなbuild / test codeを実行するのは、`contents: read`だけを持つephemeral GitHub-hosted runner上に限定します。repository secret、private network、signing state、deploy authorityは与えません。

```text
PULL_REQUEST_TARGET = 0
WORKFLOW_RUN_TRUSTED_PR_EXECUTION = 0
PR_SECRET_REFERENCES = 0
WORKFLOW_WRITE_PERMISSIONS = 0
SIGNING_DEPLOY_JOBS = 0
UNPINNED_ACTIONS = 0
```

## Workflow job

| Job | Runner | 許可する処理 | Credential |
|---|---|---|---|
| protocol | Linux | frozen install、typecheck、test | read-only tokenのみ |
| android | Linux | unit、lint、unsigned debug build | read-only tokenのみ |
| publication-safety | Linux | clean-root tree / history全体のscan | read-only tokenのみ |
| ci-public-safety | Linux | workflow policyのmachine test | read-only tokenのみ |
| ios-simulator | macOS | exact Swift resolution、unsigned ARM64 Simulator build、XCTest | read-only tokenのみ |

すべてのexternal Actionをimmutable 40-hex commitへpinします。checkout credentialはpersistしません。初期public CIではcacheやartifact transfer channelを有効にしません。

## Threat review

| Threat | Control | Residual status |
|---|---|---|
| privileged PR trigger / pwn-request | privileged / chained PR triggerを禁止 | findingなし |
| shell injection | PR metadataをinterpolateしない。`eval`を禁止 | findingなし |
| cache poisoning | shared cache Actionなし | なし |
| artifact poisoning | upload / download artifact Actionなし | なし |
| unpinned Action supply chain | immutable full SHAとversion comment | findingなし |
| writable checkout credentials | 全箇所で`persist-credentials: false` | findingなし |
| signing / deploy abuse | credential / jobなし。xcodebuildでもsigning無効 | findingなし |
| dependency registry compromise | 対応可能な範囲でfrozen lock / exact package resolution | residual ecosystem risk |
| malicious test / build execution | ephemeral hosted runner、timeout、read-only token | residual compute / log risk |

将来、privileged trigger、secret reference、write permission、PR metadata interpolation、shared cache / artifact Action、signing / deploy semantics、mutable Action reference、persistされたcheckout credentialが追加された場合、`scripts/ci-public-safety.sh`はfailureにします。

## Protected internal TestFlight workflow

`.github/workflows/ios-testflight-internal.yml`は通常Public CIではありません。`workflow_dispatch`だけをtriggerとし、protected `main`由来workflow、unprivileged exact-source trust gate、`testflight-internal` Environment required reviewerの三段階で保護します。

Environment secretsを参照するmacOS jobはPR eventから起動せず、fork codeをauthorityとして受け入れません。protected main ancestryまたはauthorized maintainerのsame-repository PR exact headだけを許可し、後者ではPublic CIの全必須jobが同一SHAで成功していることを確認します。signed IPAはartifactへ保存せず、candidate validationとSHA-256記録後に削除します。詳細は[`TESTFLIGHT_INTERNAL_RELEASE.md`](TESTFLIGHT_INTERNAL_RELEASE.md)を参照してください。

## Fork test

```text
ACTUAL_FORK_PR_TEST = NOT_SUPPORTED_WHILE_PRIVATE
A8_POST_PUBLIC_FORK_PR_SMOKE_TEST = REQUIRED
```

公開後、non-member forkから無害なdocumentation-only PRを作成し、secret、write permission、signing / deploy behavior、private network access、duplicate macOS executionが公開されないことを確認します。

