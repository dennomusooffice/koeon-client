# Input gain verification — 2026-11-09

Tracking: [Issue #43](https://github.com/dennomusooffice/koeon-client/issues/43), [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55).

## Current result

The owner requested Android/iOS headset gain verification after communication tests in the eight-endpoint lab. Four implementation discrepancies were reproduced and corrected. iOS fixes are included in TestFlight **1.0 (2026110905)**, source `0c5bb16497f7beedf7c6c0874af88ba79b636314`; Android fixes are included in the public **1.0.17 (18)** prerelease, source `45176b1695047b061673de25db8db2b2867a1f80`. Both remain on the unmerged PR branch.

A physical Bluetooth headset was connected to the iPhone. Android physical devices used built-in microphones. Therefore Android headset acoustics and human-speech convergence on the iPhone headset are **not accepted yet**. Automated processor tests, virtual-microphone speech and a physical quiet-input trial are reported separately below.

## Intended behavior retained

| Behavior | Contract |
| --- | --- |
| OFF | No KOEON input gain; platform/WebRTC processing is independent |
| MANUAL | User-selected gain, up to +24 dB |
| AUTO | Bounded −6…+12 dB trim; ordinary adaptation is at most 1 dB after normal completion |
| During speech | Keep gain fixed for the selected input; this is not continuous mid-speech AGC |
| Invalid learning | Do not train from cancelled/interrupted speech, mode changes, mid-capture microphone changes, insufficient samples or silence |
| Overload | Reduce one step when input peak is at least −0.5 dBFS or limiter usage is at least 1% |
| Profiles | Separate input routes; preserve user settings across app restart |

Platform/WebRTC AGC remains enabled in the tested production processing profiles. KOEON AUTO is an additional bounded trim, not proof of a physical microphone's sensitivity or a voice/noise classifier.

## Reproduced discrepancies and fixes

### iOS overload increased or failed to reduce AUTO

Baseline `fe668da` / TestFlight 0902 skipped learning at 5% limiter usage and otherwise considered only RMS. FloatS16 regressions reproduced:

- 9,600 samples at 32,000: all samples limited, but trim stayed 0 instead of −1 dB.
- 9,599 samples at 1,000 plus one at 32,000: quiet average but near-clipped peak; trim rose to +1 instead of falling to −1 dB.

Thirteen baseline gain tests produced four failed assertions in these two cases. A cancelled overloaded utterance already correctly discarded learning. Commit `b361242` applies Android's peak/limiter rule while retaining the bounds, fixed within-utterance gain, silence rejection, route separation and cancellation. Production LiveKit FloatS16 callback tests were added on Android as well. Verification at that stage: iOS 320 executed / 318 passed / two dedicated lab skips; Android 224 tests, Lint and build passed.

### Android LiveKit completion could train cancelled speech

Commit `83ad95c` makes learning depend on normal terminal completion, rather than any microphone disable. Cancellation/interruption paths discard measurements. Subsequent Android signed release source `45176b1695047b061673de25db8db2b2867a1f80` passed 229 tests, Lint, build and parity checks. A physical active-PTT focus interruption was also exercised for safe stop/recovery, but that combined UI cancellation/focus scenario does not establish headset acoustic acceptance.

### iOS manual ceiling and mode persistence differed from the contract

Baseline `3b2527b` produced six failed assertions across two new tests (15 gain tests total). MANUAL +24 dB was clamped to +12 dB: a FloatS16 sample of 100 became 398.095 instead of 1584.845. Recreating the processor lost explicit OFF/MANUAL selection and defaulted to AUTO, although per-route gain values were persisted.

Commit `81cba30881545b1512022605ffb550c205e55e14` separates the manual +24 dB ceiling from AUTO +12 dB and persists the mode. Non-finite profile values are handled safely. iOS verification: 323 executed / 321 passed / two lab skips. This shipped in 0903 and remains in later builds.

On the physical iPhone running 0903, OFF survived terminating/relaunching KOEON; MANUAL also survived a separate restart. Original AUTO was restored afterward, manual profile values were unchanged, enrollment was retained, and the app returned to READY. This is a settings-persistence result, not physical +24 dB sound-quality acceptance.

### iOS initial microphone selection discarded valid learning

Against 0903, a regression modeled Apple PTT exposing the actual input after DOWN but before the first captured sample:

`unavailable input → begin TX → Bluetooth input → 9,600 valid samples → normal end`.

AUTO incorrectly stayed at 0 instead of rising to +1 dB. Sixteen gain tests produced one failure. Commit `7e61fdfb046c5cc88d293e81a32087c434deb0de` permits this initial zero-sample route selection. Changing the microphone after samples have been captured still discards learning, and another route change cannot re-enable already-invalid learning. The fix adds retained `lastLearningDecision` and `lastCompletedSampleCount` diagnostics without storing audio. Full verification: 324 executed / 322 passed / two lab skips, parity and diff checks passed. This shipped in 0904 and remains in 0905.

## Real SDK and physical checks

### Android14 virtual microphone: three ordinary AUTO updates

Signed 1.0.17 (18), production `D_WEBRTC_OWNER` with WebRTC AGC enabled. All eight endpoints were connected. KOEON mode was changed from original OFF to AUTO for the trial. The same 6.88-second known speech was injected after TALKING, with finite gestures and normal release.

| Trial | Input RMS dBFS | Input peak dBFS | Samples | Limiter hits | AUTO trim after |
| --- | --- | --- | --- | --- | --- |
| 1 | −23.837244 | −3.285661 | 421,920 | 0 | +1 dB |
| 2 | −23.840180 | −3.286023 | 422,080 | 3 | +2 dB |
| 3 | −23.842611 | −3.235600 | 422,240 | 83 | +3 dB |

Android15 detected the ordered known speech in all three trials. Whole-utterance RMS includes quiet time surrounding injection; it is not isolated speech RMS or VAD. Original mode OFF and READY were restored, the helper was removed, and manual gain stayed 0 dB. The test AVD's learned AUTO trim of +3 dB is intentionally retained as a test result. This does not prove physical-headset sensitivity compensation or full convergence under changing noise.

### Physical iPhone Bluetooth: quiet-input completion on 0904

The iPhone was updated through TestFlight without re-enrollment; eight participants were present. A finite six-second PTT gesture with Bluetooth connected and no injected speech produced **89,280 captured samples**. On normal completion, the retained diagnostic reported `SILENCE_IGNORED`, AUTO mode and inactive capture. The inactive route showed 0 dB.

Thus initial microphone selection did not discard this particular capture as `ROUTE_CHANGED`, and quiet input did not train an increase. Human speech, subjective loudness/clarity and clipping at the physical headset were not evaluated during this autonomous trial.

## Remaining acceptance work

- Repeat physical human-speech tests on the iPhone headset and an actual Android headset, including reconnect, input changes, interruption, clipping and noisy conditions.
- Verify route-profile identity across different headsets; do not infer microphone characteristics solely from transport or product names.
- Existing new-user defaults remain iOS AUTO / Android OFF. Explicit selection is now persistent; the defaults were not silently unified without a product decision.
- RMS silence rejection is not speech/noise classification; steady noise can influence adaptation.
- Calibration and full adaptation convergence require additional controlled acoustic input.
- Passing unit tests or one device run does not establish general stability. Background receive and emulator audio-capture findings remain separately tracked in #54/#50/#59.

Evidence is stored privately; published records contain only sanitized metrics. Respect the owner's 09:00 JST stop window and restore temporary screen settings before releasing devices.
