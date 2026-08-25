# TASK004G CI remediation evidence

状態: PRIVATE staging evidence。この文書はpublication approvalではありません。

## Baseline（基準状態）

- Repository: `dennomusooffice/koeon-client` (PRIVATE)
- Base main: `8b8dc36182a7b071d1d448d166bc79887b025c12`
- Failed run: `32808988754`
- Remediation branch: `codex/task004g-ci-remediation`
- Approved clean root: `7cf01f85cad29a3acced75113cca92f671d9e2c3`

## Android wrapper

- Git mode before: `100644`
- Required Git mode after: `100755`
- Content SHA-256 before: `734B3879D3501DCE471CF0522D3BCBAFE76873D9FC5129345B67FB43BD15E933`
- Bytes: `8752`
- Line endings: `251 LF`, `0 CRLF`
- Gradle distribution: `gradle-8.13-bin.zip`

承認されたAndroid修正はGit executable modeだけです。script bytes、line ending、wrapper properties、Gradle versionは変更しません。

## macOS failure evidence

- Runner label: `macos-26`
- Runner image: `macos-26-arm64`
- Runner image release: `20260728.0273`
- Selected Xcode: `/Applications/Xcode_26.6.app/Contents/Developer`
- Simulator: iPhone 17 Pro, iOS 26.5, UDID `6EE862FE-93F2-4D55-946E-8745EE2B3A88`
- Original destination: `platform=iOS Simulator,id=6EE862FE-93F2-4D55-946E-8745EE2B3A88`
- Original matching architectures: `arm64` and `x86_64`
- Original package path: `/Users/runner/work/_temp/packages`
- Original DerivedData path: `/Users/runner/work/_temp/derived`
- Cross-run package/DerivedData cache: none configured
- Tracked `Package.resolved`: absent
- LiveKit URL: `https://github.com/livekit/client-sdk-swift.git`
- Project requirement: exact version `2.16.0`
- Resolved version: `2.16.0`
- Tag object: `a3fa0b612b4a0719cf6e8af2f211dd3f4f6fa299`
- Peeled commit revision: `79fb2beee98e45556bffebefa50b5d05c3382af1`
- Resolved transitive evidence: LiveKitWebRTC `144.7559.11`, LiveKitUniFFI `0.0.6`, SwiftProtobuf `1.38.1`

hosted runnerと2つの`$RUNNER_TEMP` pathはfreshで、`actions/cache` stepは存在しませんでした。package resolutionは正常に完了しました。その後、buildは1つのSimulator UDIDを`arm64`と`x86_64`の両方にmatchさせ、LiveKit packageを`arm64`向けにcompileした一方、KOEON targetを両architecture向けにcompileしようとしました。`x86_64` compileは次のmoduleを使用しようとしました:

`/Users/runner/work/_temp/derived/Build/Products/Debug-iphonesimulator/LiveKit.swiftmodule/arm64-apple-ios-simulator.swiftmodule`

compilerは、そのmoduleが互換性のないtarget向けにbuildされていると報告し、`AudioSessionController.swift:4`から`LiveKit`をresolveできませんでした。

## Root causeとDecision Gate

- `MACOS_ROOT_CAUSE_CLASS = SIMULATOR_ARCH_DESTINATION_MISMATCH`
- Secondary classification: `CI_WORKFLOW_CONFIGURATION`
- `PRODUCT_SOURCE_CHANGE_REQUIRED = NO`
- `DEPENDENCY_VERSION_CHANGE_REQUIRED = NO`
- `SAFE_CI_ONLY_REMEDIATION_AVAILABLE = YES`

remediationでは、Xcode 26.6とすべてのdependency requirementを変更しません。runごとにfreshなSourcePackages / DerivedData pathを使用し、hosted ARM64 Simulator destinationを`arch=arm64`と`ONLY_ACTIVE_ARCH=YES`で制約します。これはinvocationだけの設定であり、projectのarchitecture supportは変更しません。

retryでは、`xcodebuild -version`、`swift --version`、selected developer directory、runner architecture、生成された`Package.resolved` evidence、destination、exact resolutionをGitHub Actions logへ記録します。

## Trigger budget

remote mutation前のworkflow trigger:

- `push`: `main` only
- `pull_request`: enabled
- `workflow_dispatch`: absent
- `PULL_REQUEST_TARGET`: absent

remediation branchはworkflow runを開始せず1回だけpushします。その後、1回のPR `opened` eventを使用して、承認されたmacOS validation jobを1回だけ実行します。TASK004Gでは、追加commit、synchronize event、workflow dispatch、rerun、mergeを許可しません。

- `ADDITIONAL_MACOS_ATTEMPTS = 1`
- `CI_TRIGGER_BUDGET_UNSAFE = NO`

## 変更しないsecurity / Product constraint

- Product Swift/Kotlin changes: `0`
- Dependency semantic/revision changes: `0`
- Deployment target changes: `0`
- Signing/entitlement/bundle changes: `0`
- `PULL_REQUEST_TARGET`: `0`
- Signing secrets: `0`
- Production secrets: `0`
- Deploy jobs: `0`
- Signed archive: `NO`
- Publication authorization: `NO`
