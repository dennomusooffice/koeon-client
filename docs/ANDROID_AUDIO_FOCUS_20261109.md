# Android audio focus recovery — 2026-11-09

Tracking: [Issue #63](https://github.com/dennomusooffice/koeon-client/issues/63), [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55).

## Observed device failure

Physical moto g64 5G,1.0.16(17), APK matchinge7cf936: after official DHU/Android Auto setup was cancelled without accepting data-sharing consent, Android Auto retained audio focus. KOEON correctly disabled PTT while the other app owned focus. After ending the test-started Android Auto process, the OS focus stack was empty but KOEON remainedINTERRUPTED and PTT disabled. No POWER reset was used. This stopped the eight-device retest after three successful senders; the remaining senders were not accepted.

The UI displayedREADY alongside an interruption warning. Field JSON similarly reportedREADY/pttEligible=true whileaudio.focus=Lost. The operational button was disabled, so this was an observability and presentation bug in addition to unresolved focus recovery.

## Presentation and diagnostic fix

Shared Android PTT semantics now includeINTERRUPTED and take audio availability into account. Recovery failure maps toERROR, recovery-in-progress toRECOVERING. Both the screen and diagnostic generator use this classification. Diagnostic eligibility also checks the operational/channel/connection/audio gates used by input handling. Block reasons distinguishAUDIO_INTERRUPTED, AUDIO_RECOVERING, AUDIO_RECOVERY_FAILED and inactive session. The audio section includes availability and interruption/recovery metadata; no raw audio or identifiers are added.

The reproduction test failed before the fix on interruption eligibility. Afterward, all226 Android tests passed; Lint/debug build, feature-parity and diff checks passed. Coverage includesREADY, INTERRUPTED, RECOVERING andRECOVERY_FAILED. This change is implemented and automatically tested, not distributed or device-verified.

## Recovery still outstanding

The current controller merges permanent/transient/duck focus losses into one state and only resumes after aGAIN callback. Its `validateAudioRecovery()` checks LiveKit connectivity but does not request or verify Android audio focus. The existing retry path must not declare success solely from room connectivity.

[Android's audio-focus guidance](https://developer.android.com/media/optimize/audio-focus) requires checking the focus-request result before playback and distinguishes permanent loss from transient loss. Permanent loss must not be handled by repeatedly taking focus from another active app. [LiveKit2.28.0 AudioSwitchHandler](https://github.com/livekit/client-sdk-android/blob/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/audio/AudioSwitchHandler.kt) owns focus by default and requests it onstart; callingstart on an already-started switch does not establish a fresh request/result for KOEON.

Next: provide a bounded, verifiable recovery request for an explicit resume action, preserve automatic recovery on transientGAIN, and keep PTT blocked when focus is denied or a real call still has priority. Validate against a controlled competing-focus helper before repeating the physical Android Auto scenario. Do not mark #63 resolved until actual focus and subsequent transmission agree with diagnostics.
