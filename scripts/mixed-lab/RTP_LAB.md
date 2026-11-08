# LiveKit RTP restoration investigation — 2026-11-08

Tracking: [Issue #54](https://github.com/dennomusooffice/koeon-client/issues/54).

## Status

This is an opt-in transport feasibility test, **not a product transport cutover**.
The released app and current session constructors still use BATv1 HTTP PCM.
No build/version was released by this investigation. Base source: `e786f0de06645f457bc13cfb9f8580ba33a24e66`.

User acceptance requirements remain: restore standard LiveKit audio, preserve leading/trailing speech and background recovery, verify constrained transport and reconnection, and record changes on GitHub.

## What was exercised

- LiveKit server v1.13.11, built locally from its official Go module; not production.
- Android SDK 2.28.0 and Swift SDK 2.16.0 (unchanged dependencies).
- Android 15 / Android 16 ARM64 AVDs, then Android 15 / iOS 27.0 Simulator.
- Real native SDK audio tracks, SFU forwarding, Opus target 12,000bps, remote decoded PCM callbacks. Synthetic 660Hz tone only; no microphone recordings or audio files.
- Android sender: prewarm, 300ms pre-roll, publish silent track, wait for receiver subscription acknowledgement, authorize FIFO, capture 2.5s, freeze, drain, mute.
- FIFO tests: pre-roll/live order, short release while waiting for readiness, capacity failure without dropping the head, format change/reset without replaying stale samples.

The proxy shares one 16,000-byte/s upload budget and one download budget **per Android endpoint**, across signaling and ICE/TCP connections. It does not multiply the budget for additional sockets. It forwards at most 512 bytes per reservation, with TCP backpressure.

This counts application TCP bytes, not TCP/IP headers, cellular retransmissions or carrier queues. The iOS peer connects directly to the local SFU: Android↔iOS traffic crosses the Android 128kbps bottleneck in both directions, but iOS's own signaling is not independently shaped. UDP, loss, carrier latency and background radio sleep are not covered.

## Results

| Run | Endpoint | Decoded samples | Samples above amplitude threshold | Result |
| --- | --- | ---: | ---: | --- |
| Android↔Android | Android 15 | 364800 | 218571 | PASS |
| Android↔Android | Android 16 | 227520 | 205378 | PASS |
| Android↔iOS rerun | Android 15 | 174720 | 53318 | PASS |
| Android↔iOS rerun | iOS 27.0 | — | 19925 | PASS |

Android FIFO drained in each successful run. Both Android instrumentations passed one test each; iOS rerun passed one XCTest. Sample counts are not directly comparable across platforms and do not prove perceptual quality or sample-exact preservation through the lossy codec. The constant-tone test does not prove on-wire leading/trailing marker order.

Initial Android↔iOS attempt failed: XCTest reported `Test crashed with signal kill`, and Android timed out after 15 seconds. Rerun passed after granting the actual Simulator app bundle `org.example.koeon` microphone permission, explicitly enabling/restoring the SDK engine in the test, and stopping the unused Android 16 AVD. The kill's exact cause is not established.

Local sanitized numeric evidence: `.build/macos/livekit-lab/results.json` and `results-ios.json`. Detailed local logs are not uploaded.

## Reproduction

Build the app/tests as in the mixed-lab README. For the SFU, use official `github.com/livekit/livekit-server@v1.13.11` source as the main Go module (`go install ...@version` fails because this release has replace directives), and build `./cmd/server`. Keep its output under ignored `.build/macos/livekit-lab`.

Test-only config:

```yaml
port: 19080
bind_addresses: [127.0.0.1]
rtc:
  tcp_port: 19081
  force_tcp: true
  enable_loopback_candidate: true
  use_external_ip: false
  node_ip: 127.0.0.1
  ips:
    includes: [127.0.0.1/32]
keys:
  koeon-local-lab: koeon-local-lab-only-not-a-production-secret
logging:
  level: warn
```

The key is a public test fixture, never a production credential. The SFU TCP mux listens on all host interfaces despite loopback advertised candidates; use a trusted local machine/network and stop it after the test. No production accounts or tokens are used.

Start the SFU with `--config` and `python3 scripts/mixed-lab/rtp-proxy.py`. Prepare dedicated AVDs only using `android-test.sh ... prepare`. Grant RECORD_AUDIO on the test app. Map these ports with `adb -s SERIAL reverse tcp:DEVICE tcp:HOST`:

| Serial | Signaling | ICE/TCP | Test status/token |
| --- | --- | --- | --- |
| emulator-5554 | 18080→18180 | 19081→18181 | 18766→18766 |
| emulator-5556 | 18080→18280 | 19081→18281 | 18766→18766 |

Run the instrumentation class `com.dennomuso.koeon.LiveKitRtpLabTest` concurrently with `-e rtpLabRole android35` / `android36`. Require `OK (1 test)`, not merely adb exit 0.

For iOS, build-for-testing `KOEONTests/LiveKitRtpLabTests`, set `KOEON_RTP_LAB=1` in the copied xctestrun's `KOEONTests.EnvironmentVariables`, set `OnlyTestIdentifiers` to `LiveKitRtpLabTests`, and keep the file beside the original so `__TESTROOT__` resolves. Grant microphone to `org.example.koeon` on the dedicated Simulator. Start it alongside **only one** Android instrumentation. Physical devices are excluded. Inspect `/status` at loopback port 18766 for numeric results; `/token` contains ephemeral lab tokens and must not be published.

## Product integration work still required

1. Wire the bounded FIFO to both production capture pipelines and make standard START advertise RTP, while retaining old BATv1 receive compatibility during migration.
2. Preserve floor/RX_READY authorization and exact generation ownership on cancellation/reconnect. Add endpoint failure propagation, not just FIFO tests.
3. Fix iOS release ownership before switching. Current app touch release issues Apple stop while floor cleanup is still draining; pending short-press HTTP frames can currently send after local recording stops. RTP injection relies on active SDK capture callbacks. System/headset release can end Apple's session independently. Merely replacing the HTTP transmitter loses this protection.
4. Resolve RTP end/control ordering and late receiver behavior; a drained capture FIFO is **not** remote playback completion.
5. Exercise three simultaneous receivers, disconnect/reconnect and bandwidth recovery through production session/control code; assert marked leading/trailing audio, not just nonzero tone.
6. Apple PushToTalk background activation is unsupported by Simulator. Keep this explicit limitation and retain physical acceptance as unverified; do not claim the SDK-only test verified background wake.

Do not enable the product switch based solely on the passing transport probes above.
