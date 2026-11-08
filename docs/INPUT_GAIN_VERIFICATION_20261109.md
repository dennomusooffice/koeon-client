# Input gain comparison — 2026-11-09

Tracking: [Issue #43](https://github.com/dennomusooffice/koeon-client/issues/43), [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55).

The owner requested Android/iOS headset gain verification after the mixed-device tests. The morning control matrix passed for eight endpoints; audio acceptance remains incomplete because API35/36 also fail independent output capture. A physical Bluetooth headset is connected to the iPhone. Android endpoints currently use built-in microphones. Synthetic processor tests do not establish headset acoustic quality or Android headset acceptance.

## Confirmed iOS discrepancy

Baseline source `fe668da` (audio implementation included in TestFlight 1.0/2026110902): Android reduces AUTO trim by 1 dB after a completed utterance if input peak is at least −0.5 dBFS or limiter usage is at least 1%. iOS instead skipped all learning when limiter usage reached 5%, and otherwise considered only RMS.

Actual FloatS16 input through the iOS processor reproduced both faults:

- 9,600 samples at 32,000: all samples limited, AUTO remained 0 dB instead of dropping to −1 dB.
- 9,599 samples at 1,000 plus one at 32,000: quiet average but near-clipped input peak; AUTO increased to +1 dB instead of dropping to −1 dB.

The pre-fix test run executed 13 tests with four failing assertions across these two cases. A cancelled overloaded utterance correctly did not train AUTO.

The fix uses the same peak/limiter rule as Android after normal completion. Gain stays fixed during the utterance, changes by at most 1 dB afterward, and remains bounded to −6…+12 dB. Existing silence rejection, route separation, cancellation and calibration behavior are retained. Additional Android tests use the production LiveKit FloatS16 callback with identical input vectors, rather than only testing the scalar formula or legacy PCM16 path.

## Remaining differences to investigate

- The product summary says manual +24 dB for both platforms, but current iOS processor and UI cap manual input at +12 dB; Android allows +24 dB. AUTO remains +12 dB on both. This discrepancy is not resolved by the overload fix.
- iOS processor starts in AUTO; Android starts in OFF. Verify intended default and persistence before changing user-visible behavior.
- Android LiveKit terminal-learning discrepancy was subsequently reproduced and fixed; see below. Physical interrupted-transmission verification remains outstanding.
- Profile keys describe input routes, but route switching and headset-specific identity need physical verification. Do not infer microphone characteristics solely from model or transport names.
- Silence rejection is not voice/noise classification. Steady noise can still influence RMS-based learning.

No new release or device acceptance is implied by implementation or unit tests. The 09:00 JST device deadline remains in force.

## Automated verification of overload fix

iOS: 320 tests executed, 318 passed, 2 dedicated lab tests skipped, no failures. Android: 224 tests passed, Lint and debug build succeeded. Feature-parity gate and diff check passed. The iOS regression run covers the unchanged route-switch, cancellation, fixed-gain and silence behaviors alongside the new overload cases. These are local automated results; no new build has been distributed or installed on the physical headset device for this fix.

## Android LiveKit abort learning

The production session callback treated every exit from TRANSMITTING/RELEASING as successful input for AUTO. Safety stops, microphone-stop failure and normal releases all return to IDLE, so state alone cannot distinguish them.

The callback lifecycle was extracted without changing behavior and tested with the real PttController, synthetic FloatS16 samples and the real gain processor. The baseline test failed on safety stop: AUTO advanced from0 to+1 dB despite an aborted transmission. A normal release correctly advanced to+1 dB. The fix requires both no terminal error and `release.terminalRecoveryResult == NORMAL_COMPLETE` before learning; other paths end measurement without learning. BATv1 retains its separate capture lifecycle. Tests cover normal release, explicit safety stop and microphone-stop failure.

After the Android lifecycle fix: all225 Android tests passed, Lint/debug build and feature-parity checks passed. No new version has been released or installed for this change; device acceptance remains pending.

## Manual range and selected-mode persistence

Further regression atHEAD3b2527b reproduced six failing assertions in two new cases (15gain tests total). iOSmanual+24dB was clamped to+12dB: a FloatS16 sample100 produced398.095 instead of1584.845. A reconstructed processor lost explicitMANUAL/OFF selection and defaultedAUTO, even though routeprofile values themselves were persisted.

The fix extends onlymanual/UI/samplehelper limits to+24dB and persists the selectedmode. Unset/invalidmode retains legacyiOSdefaultAUTO; this is deliberately not an unsolicited migration of existing users toAndroid'sOFFdefault. Storedmanual andAUTO values are bounded independently; non-finite storedvalues become0. AUTOstillcaps+12dB. Tests exercise actualFloatS16processing, symmetricwaveforms, +24dBpeaklimiting, routeisolation, reconstruction, OFFrestoration andAUTOconvergencebound. Full regression:323 tests executed,321 passed,2 dedicated lab tests skipped,no failures; feature-parity gate anddiffcheckpassed. No updatediOSbinary has yetbeen distributed.
