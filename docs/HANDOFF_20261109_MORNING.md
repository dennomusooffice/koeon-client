# 2026-11-09 morning handoff

This records the authorized autonomous test window ending at **09:00 JST**. Do not resume physical-device operations after that window without a new user instruction. Issue/PR comments remain the authoritative incremental history; raw diagnostics, audio-related inputs and credentials are private.

## Source and distribution

- Branch: `codex/livekit-128kbps-investigation`, [draft PR #55](https://github.com/dennomusooffice/koeon-client/pull/55), stacked on #44, not merged into main.
- Device-tested iOS **1.0 (2026110905)**, source `0c5bb16497f7beedf7c6c0874af88ba79b636314`: signed/archive/export/upload passed; Apple VALID; internal/external IN_BETA_TESTING; two internal and one external tester groups assigned. Installed on the connected physical iPhone through TestFlight without re-enrollment.
- Android **1.0.17 (18)**, source `45176b1695047b061673de25db8db2b2867a1f80`: [public prerelease](https://github.com/dennomusooffice/koeon-client/releases/tag/android-v1.0.17-18), installed on both physical Androids and four AVDs. The enrolled iOS simulator uses its existing signed foreground test build; do not describe all eight endpoints as the same latest source.
- Latest code is `e68565f46a161599659d9387cb4b99b5196ccf5c`, adding monotonic subscription generations and original-Room SDK/completion fencing. iOS **1.0 (2026110906)** upload succeeded; fresh Apple reads confirmed VALID, internal/external IN_BETA_TESTING, and two internal/one external groups assigned. Physical-device verification applies to 0905, not this additional change.
- Latest iOS regression: 327 executed, 325 passed, two dedicated lab tests skipped. Android release: 229 tests, Lint/build passed. Parity/diff checks passed.

## Confirmed progress and boundaries

| Area | Result | Remaining acceptance |
| --- | --- | --- |
| Eight-endpoint control | Eight senders, seven other receivers each: BUSY_REMOTE during finite PTT, READY afterward; 56 receiver observations | This does not establish sound quality or every network recovery scenario |
| iOS input gain | Overload reduction, manual +24 ceiling, persisted mode, initial microphone selection before sampling corrected | Physical human-speech convergence and acoustic clipping/clarity |
| Android input gain | Normal completion alone trains AUTO; real SDK virtual input advanced 0→1→2→3 dB over three successful known-speech trials | Actual Android headset route and noisy speech |
| Physical iPhone headset | 0904 captured 89,280 samples on finite PTT and correctly reported SILENCE_IGNORED | Human listening was unavailable during autonomous testing |
| Android focus / Android Auto | Physical moto transient interruption recovered; permanent loss and DHU shutdown recovered after explicit audio reconnect | Real car audio routing; first-run sharing permissions were not newly accepted |
| CarPlay | Route classification/safety behavior corrected and unit-tested | Additional Tools/real CarPlay environment and reproduction still required |
| iOS background RX | 0905 gates room PCM on current subscription and RX start time; first background trial has a retained PCM-time wake completion before foreground | Two independent waits (323/335 seconds) retained PCM-time wake completion before foreground; no human listening |
| Android15 capture | QEMU hang/exit, then abnormal gRPC sample rate; independent AudioTrack also fails, including with KOEON stopped | Repair/validate capture infrastructure before using its negative audio results |

The physical OPPO A79 5G retained its existing speed-limited povo LTE configuration. No network setting was changed to improve the test result.

## Important diagnostic interpretation

In the 0905 background trial after 323 seconds, the push arrived at 23:36:18 UTC and `lastCompletedWake.completedAt` was 23:36:20 UTC. The app was foregrounded only after 23:36:51 UTC. Current `firstPcmAt` was subsequently overwritten by a fresh runtime's 23:36:53 UTC event. Looking only at that current field initially produced an incorrect “no background PCM” conclusion; the completed ledger and code path corrected it. This supports accepted PCM during background, not subjective audibility. Keep completed runtime/receive/lifecycle evidence explicit in future diagnostics (#50).

## Priorities for the next authorized window

1. [#54](https://github.com/dennomusooffice/koeon-client/issues/54) / [#50](https://github.com/dennomusooffice/koeon-client/issues/50): repeated long background/lock first-receive tests with human listening or a validated acoustic capture path. Retain completed PCM evidence across foreground restoration. Do not classify every room callback as delivered speech.
2. [#43](https://github.com/dennomusooffice/koeon-client/issues/43): actual Android headset and controlled human speech on the iPhone headset. Compare fixed within-utterance gain, bounded end-of-utterance learning, reconnect, route changes and interruption. Existing iOS AUTO / Android OFF new-user defaults were not silently unified.
3. [#59](https://github.com/dennomusooffice/koeon-client/issues/59) / [#56](https://github.com/dennomusooffice/koeon-client/issues/56): stabilize Android15 audio capture; independent 660Hz output and sample-count sanity must pass before judging KOEON. Android16/17 detected the same known speech in the 0905 foreground comparison.
4. [#58](https://github.com/dennomusooffice/koeon-client/issues/58) / [#63](https://github.com/dennomusooffice/koeon-client/issues/63): real CarPlay/Android Auto route testing when the environment and any necessary consent are available.

Detailed evidence: [eight-device lab](EIGHT_DEVICE_LAB_20261108.md), [gain verification](INPUT_GAIN_VERIFICATION_20261109.md), [Android focus](ANDROID_AUDIO_FOCUS_20261109.md). Implementation, automated testing, distribution, device verification and merge status are intentionally separate.

## Window-end restoration

Completed at 08:46 JST: all eight endpoints were READY, USB stay-awake values were restored (OPPO/moto 0; each AVD 1), temporary probe helpers were removed, and the iPhone's original Auto-Lock Never was preserved. Enrollment, gains and the povo network were retained. No PTT gesture or test tone remains running. The four AVDs were then stopped without data deletion for final simulator-only regression; physical-device operations ended. The Android14 test AVD intentionally retains learned AUTO trim +3 dB with its original mode OFF and manual gain 0 dB restored. The second background trial retained PCM-time wake completion at 23:44:09 UTC, before foregrounding after 23:44:38 UTC. Human headset listening remains unverified.

## Stop status

Physical operations ended at 08:46 JST, and distribution/records were finalized before the requested 09:00 JST pause. No additional test or upload is scheduled to resume automatically. The goal remains incomplete: physical listening, vehicle routes, diagnostic retention and emulator capture limitations above are still open. The next device window requires a new user instruction.

Final cleanup also stopped the enrolled iOS simulator and its WebDriverAgent xcodebuild runner without deleting data. Android AVDs and the dedicated regression simulator were already stopped. No build/upload/test gesture remains pending; the latest Apple distribution read is recorded above.
