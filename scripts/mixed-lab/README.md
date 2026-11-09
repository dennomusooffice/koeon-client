# Mixed native transport lab

Related tracking: [#52](https://github.com/dennomusooffice/koeon-client/issues/52),
[#53](https://github.com/dennomusooffice/koeon-client/issues/53).

This opt-in lab runs the production Swift/Kotlin HTTP clients and buffered receivers
against a **synthetic protocol fixture**, not the production backend. It does not
exercise LiveKit signaling, enrollment, floor authorization, microphone capture,
Apple PushToTalk activation, Bluetooth, or audible playback. Players are test
sinks that compare every received byte; this is not an acoustic listening test.
The fixture is loopback-only, has no production credentials, and retains only
synthetic PCM in memory. It must never be exposed as an application server.

## Matrix and cases

| Role | Virtual device | OS |
| --- | --- | --- |
| android35 | KOEON_Lab_API35 / Pixel 2 profile | Android 15, ARM64 |
| android36 | KOEON_Lab_API36 / Pixel 10 profile | Android 16, ARM64 |
| ios27 | iPhone 18 Pro Simulator | iOS 27.0 |

Hardware profiles do not reproduce Sony/OPPO firmware or microphone characteristics.

Each role publishes four 32-frame generations through its native HTTP API and
receives all three roles (12 cases each, 36 total): normal; two HTTP 503 responses
and a dropped TCP connection; expired head; a subsequent healthy generation.
The server retains per-receiver attempt counters and independent cursors.

The expired-head case **documents an existing difference**: iOS rejects the
expired timeline with zero frames; Android plays the four remaining frames.
The test does not declare these semantics equivalent or resolve #52.
Android additionally cancels a five-second stalled subscription and must finish
the next generation within two seconds. Unit tests cover cancellation while
waiting for headers and while reading a stalled response body.

## Setup

Install emulator and ARM64 Android 35/36 google_apis images with the Android SDK.
If the SDK CLI itself runs under Rosetta, explicitly use `--platform=mac_arm64`;
the default can incorrectly install an x86_64 emulator despite an ARM host.
Create named AVDs KOEON_Lab_API35 and KOEON_Lab_API36 with those images.
Run them on ports 5554 and 5556. Recommended startup flags on a shared Mac:
`-no-window -no-audio -no-boot-anim -no-snapshot -memory 1536 -cores 2`.
Wait for `sys.boot_completed=1` on **both** before running the lab.

Build Android `assembleDebug assembleDebugAndroidTest` with JDK17. The debug-only
network-security overlay permits cleartext solely to localhost/127.0.0.1;
release policy remains unchanged. `adb reverse` is used on explicitly allowlisted
emulator serials; the script rejects real-device serials.

Build iOS `build-for-testing` with the project's normal arm64 Simulator options,
`-only-testing:KOEONTests/MixedEmulatorTransportTests`, and a chosen Simulator UDID.
Prepare its generated xctestrun (stored alongside it so relative paths stay valid):

```sh
python3 scripts/mixed-lab/prepare-ios.py PATH/KOEON_iphonesimulator27.2-arm64.xctestrun
export LAB_XCTESTRUN=PATH/KOEON_mixed_lab.xctestrun
export LAB_IOS_UDID=YOUR_SIMULATOR_UDID
bash scripts/mixed-lab/run.sh
```

Ordinary XCTest runs skip the lab unless `KOEON_MIXED_LAB_ROLE` is explicitly set
by the prepared test configuration. Never put that variable in release settings.
The runner validates the iOS ID against simctl, owns and stops its fixture server,
and writes logs and structured results under `.build/macos/mixed-lab/`.
It requires the port to be free instead of terminating someone else's service.

Stop only these dedicated AVDs using `adb -s emulator-5554 emu kill` and
`adb -s emulator-5556 emu kill` after testing. Shut down the chosen Simulator
with `simctl shutdown` if this lab started it. No physical-device operation is
part of this workflow.

## Evidence and limitations (2026-11-08)

Initial native mixed run: 36 cases completed (12 per role). The first iOS attempt
started before the new AVDs finished booting and timed out waiting for a peer;
it is an environment-readiness failure, not a product network regression.
Re-running after peer startup passed. Android15/16 instrumentation and iOS27.0
XCTest each passed. iOS27.2 ordinary regression: 300 tests, one opt-in lab skipped,
zero failures.

The stalled HTTP cancellation regression failed before the #53 change with a
read-timeout exception instead of prompt cancellation. The fix connects coroutine
cancellation to OkHttp Call.cancel and closes response bodies in all paths.
Final post-fix run passed all 36 cases and both Android cancellation-to-next-generation tests. Android unit tests: 194 passed; Lint and Debug/test APK builds passed. A subsequent Android15 test startup ANR was captured under high CPU/I/O pressure; preparation was separated from simultaneous execution, and the clean rerun passed. Use `LAB_PREPARED=1` only when the exact current APKs have already been installed; otherwise the runner prepares them first. Full evidence is recorded in #53; neither a release nor physical-device
verification follows automatically from these tests.

## Current standard

The authoritative multi-device operating procedure is now
[docs/testing/README.md](../../docs/testing/README.md). This older fixture lab
remains useful for HTTP compatibility but is not the five-device product test.
