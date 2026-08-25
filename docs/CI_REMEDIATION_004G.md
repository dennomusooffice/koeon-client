# TASK004G CI Remediation Evidence

Status: PRIVATE staging evidence. This document is not publication approval.

## Baseline

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

The authorized Android correction is Git executable mode only. Script bytes, line endings, wrapper properties, and Gradle version must remain unchanged.

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

The hosted runner and both `$RUNNER_TEMP` paths were fresh, and no `actions/cache` step existed. Package resolution completed successfully. The build then matched one Simulator UDID as both `arm64` and `x86_64`, compiled the LiveKit package for `arm64`, and attempted the KOEON target for both architectures. The `x86_64` compile attempted to consume:

`/Users/runner/work/_temp/derived/Build/Products/Debug-iphonesimulator/LiveKit.swiftmodule/arm64-apple-ios-simulator.swiftmodule`

The compiler reported that module as built for an incompatible target and could not resolve `LiveKit` from `AudioSessionController.swift:4`.

## Root cause and Decision Gate

- `MACOS_ROOT_CAUSE_CLASS = SIMULATOR_ARCH_DESTINATION_MISMATCH`
- Secondary classification: `CI_WORKFLOW_CONFIGURATION`
- `PRODUCT_SOURCE_CHANGE_REQUIRED = NO`
- `DEPENDENCY_VERSION_CHANGE_REQUIRED = NO`
- `SAFE_CI_ONLY_REMEDIATION_AVAILABLE = YES`

The remediation keeps Xcode 26.6 and every dependency requirement unchanged. It uses fresh per-run SourcePackages and DerivedData paths and constrains the hosted ARM64 Simulator destination to `arch=arm64` with `ONLY_ACTIVE_ARCH=YES`. This is an invocation-only setting and does not change project architecture support.

The retry records `xcodebuild -version`, `swift --version`, selected developer directory, runner architecture, generated `Package.resolved` evidence, destination, and exact resolution in the GitHub Actions log.

## Trigger budget

Workflow triggers before remote mutation:

- `push`: `main` only
- `pull_request`: enabled
- `workflow_dispatch`: absent
- `PULL_REQUEST_TARGET`: absent

The remediation branch is pushed once without opening a workflow run. A single PR `opened` event is then used for the one authorized macOS validation job. No additional commit, synchronize event, workflow dispatch, rerun, or merge is allowed in TASK004G.

- `ADDITIONAL_MACOS_ATTEMPTS = 1`
- `CI_TRIGGER_BUDGET_UNSAFE = NO`

## Unchanged security and product constraints

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
