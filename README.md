# KOEON Client — pre-publication staging

This clean local tree contains the native iOS and Android clients plus a small, client-safe protocol subset. It was exported from a private source repository with an explicit path allowlist; it contains no server implementation, Web client, Event site/assets, signing pipeline, deployment material, or private Git history.

## Safety status

- Publication is **not authorized**.
- MPL-2.0 is the preferred license candidate, subject to legal review before A7 publication.
- The included API and invite defaults use `https://example.invalid`; the tree cannot reach a real service without an explicit local configuration change.
- Signing, TestFlight, store upload and Production deployment are outside this repository.
- External core pull requests are closed initially. See `CONTRIBUTING.md`.

## Layout

- `ios/`: SwiftUI native client and XCTest suite
- `android/`: Kotlin/Compose native client and tests
- `protocol/`: safe TypeScript protocol constants, codecs and tests
- `docs/`: public-safe architecture and protocol notes
- `.github/workflows/public-ci.yml`: untrusted build/test-only CI candidate

## Local validation

Protocol (Node.js 22+):

```sh
pnpm --dir protocol install --frozen-lockfile
pnpm --dir protocol lint
pnpm --dir protocol test
```

Android (JDK 17 and Android SDK 36):

```sh
./android/gradlew -p android testDebugUnitTest lintDebug assembleDebug --no-daemon
```

iOS requires macOS/Xcode 26 and an available iOS simulator. Use `CODE_SIGNING_ALLOWED=NO` for both build and XCTest. No Apple signing identity is required.

Publication-safety assertion (Git Bash/Linux/macOS):

```sh
bash scripts/publication-safety.sh
```

## Manual test procedure

1. Confirm the app launches as an unsigned simulator/debug build and presents enrollment UI.
2. Confirm a synthetic invite URL under `example.invalid` is parsed but no Production service is contacted.
3. With a separately authorized development backend configuration, verify Join keeps one room session, TX occurs only after Floor control, and RX remains active while TX is off.
4. Confirm logs and exported field diagnostics contain no access token, invite value, credential or private key.
5. Confirm leaving a channel clears ephemeral runtime credentials without recording audio.

## Known limitations

- No server is included, so end-to-end enrollment/Floor/LiveKit operation is unavailable from the safe defaults.
- iOS PushToTalk/APNs behavior requires private signing/capability infrastructure and is not exercised by public CI.
- Android OEM background-kill behavior requires physical-device testing.
- Current RX_READY maximum waits remain 4000 ms; older 1200/600 ms documents are known protocol documentation drift, not a change request in this export.
- P0 startup-latency and control/media RX divergence work is intentionally not implemented here.
