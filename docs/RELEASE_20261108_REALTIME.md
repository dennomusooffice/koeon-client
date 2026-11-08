# Real-time audio field-test release, 2026-11-08

Authorized by the repository owner. Related: [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55), [Issue #54](https://github.com/dennomusooffice/koeon-client/issues/54).

- Source: `44b6eb3cb68b508577c14fc2ff34c11ff945ed6f`
- Tree: `5ac546b09ccc16dbac91fd9bd476c75d3ed1805b`
- Android **1.0.14 (15)**: [GitHub field-test prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.14-15).
- APK SHA-256: `44ed51f326b1054c8e6540da2301c6bfb211fe9c905852ba7fe7d43e8848f5f4`. APK and checksum attachments verified; signing certificate matches the 1.0.13 release.
- iOS **1.0 (2026110803)**: signed validation and Apple upload succeeded. Apple processing `VALID`, audience `APP_STORE_ELIGIBLE`, beta review `APPROVED`; internal and external state `IN_BETA_TESTING`. Assigned to the existing external tester group with Japanese test notes. Distribution confirmed on 2026-11-08; see Issue #54 for subsequent field results.

## Changes and evidence

Standard TX uses LiveKit Opus. Receiver readiness waits at most 500ms; the app start cue follows SDK publication; app-owned release allows a 180ms tail. Speech before readiness is not replayed. Legacy BATv1 reception and existing background recovery/safety mechanisms remain.

Functional commit `16b192e` passed 200 Android and 300 iOS unit tests (two opt-in iOS probes skipped), Android lint/build and iOS Simulator build. The release commit updates Android version and its contract. Both releases were signed and validated from isolated exact-source checkouts.

Android 15 AVD, upload/download 128kbps, Opus 12kbps, real SDK/local SFU: bidirectional UDP audio with iOS 27.0 and new PTT after Android disconnect/rejoin passed. Floor and control adapters are lab fixtures. Production backend latency, carrier loss, acoustic edge quality and physical background/Bluetooth behavior remain unverified. See [lab details](../scripts/mixed-lab/RTP_LAB.md).

## Field procedure

Update both platforms, then POWER OFF/ON. For restricted bandwidth, choose low quality (12kbps), reconnect and speak after the start cue. Check both directions, multiple receivers, locked-screen reception, Bluetooth reconnection and short utterances. On failure, preserve diagnostic JSON before POWER operations and record time, direction and output route.

Distribution does not establish physical acceptance. Main remains unmerged and Issue #54 stays open. No physical devices were operated during this release task.
