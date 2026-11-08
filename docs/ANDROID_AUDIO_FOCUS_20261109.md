# Android audio focus recovery — 2026-11-09

Tracking: [Issue #63](https://github.com/dennomusooffice/koeon-client/issues/63), [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55).

## Observed device failure

Physical moto g64 5G,1.0.16(17), APK matchinge7cf936: after official DHU/Android Auto setup was cancelled without accepting data-sharing consent, Android Auto retained audio focus. KOEON correctly disabled PTT while the other app owned focus. After ending the test-started Android Auto process, the OS focus stack was empty but KOEON remainedINTERRUPTED and PTT disabled. No POWER reset was used. This stopped the eight-device retest after three successful senders; the remaining senders were not accepted.

The UI displayedREADY alongside an interruption warning. Field JSON similarly reportedREADY/pttEligible=true whileaudio.focus=Lost. The operational button was disabled, so this was an observability and presentation bug in addition to unresolved focus recovery.

## Presentation and diagnostic fix

Shared Android PTT semantics now includeINTERRUPTED and take audio availability into account. Recovery failure maps toERROR, recovery-in-progress toRECOVERING. Both the screen and diagnostic generator use this classification. Diagnostic eligibility also checks the operational/channel/connection/audio gates used by input handling. Block reasons distinguishAUDIO_INTERRUPTED, AUDIO_RECOVERING, AUDIO_RECOVERY_FAILED and inactive session. The audio section includes availability and interruption/recovery metadata; no raw audio or identifiers are added.

The reproduction test failed before the fix on interruption eligibility. Afterward, all226 Android tests passed; Lint/debug build, feature-parity and diff checks passed. Coverage includesREADY, INTERRUPTED, RECOVERING andRECOVERY_FAILED. This change is implemented and automatically tested, not distributed or device-verified.

## Recovery investigation (before implementation)

The current controller merges permanent/transient/duck focus losses into one state and only resumes after aGAIN callback. Its `validateAudioRecovery()` checks LiveKit connectivity but does not request or verify Android audio focus. The existing retry path must not declare success solely from room connectivity.

[Android's audio-focus guidance](https://developer.android.com/media/optimize/audio-focus) requires checking the focus-request result before playback and distinguishes permanent loss from transient loss. Permanent loss must not be handled by repeatedly taking focus from another active app. [LiveKit2.28.0 AudioSwitchHandler](https://github.com/livekit/client-sdk-android/blob/v2.28.0/livekit-android-sdk/src/main/java/io/livekit/android/audio/AudioSwitchHandler.kt) owns focus by default and requests it onstart; callingstart on an already-started switch does not establish a fresh request/result for KOEON.

Next: provide a bounded, verifiable recovery request for an explicit resume action, preserve automatic recovery on transientGAIN, and keep PTT blocked when focus is denied or a real call still has priority. Validate against a controlled competing-focus helper before repeating the physical Android Auto scenario. Do not mark #63 resolved until actual focus and subsequent transmission agree with diagnostics.


## Explicit focus ownership and resume implementation

Android candidate1.0.17(18) now uses a single app-owned AudioFocusRequest while retaining LiveKit AudioSwitchHandler for device routing (`manageAudioFocus=false` on the routing delegate). Initial start and explicit resume check AUDIOFOCUS_REQUEST_GRANTED; denied requests keep the app interrupted and cannot be turned into success by stale callbacks. Stop and replacement invalidate older callback generations. A transientGAIN resumes automatically; permanentLOSS does not trigger periodic requests that would steal focus from another active app.

The interrupted/failed screen exposes「音声を再接続」. That action requests focus once and starts recovery only if granted. LiveKit recovery validation now refuses success without owned focus, rather than treating room connectivity as focus proof. Routing starts on gain and stops on loss. PTT is not automatically restarted after recovery.

All229 Android tests passed, Lint/debug build and feature-parity checks succeeded. New owner tests cover permanent loss→explicit resume, transient loss→GAIN without another request, denial and old/stopped request callbacks. Implementation is committed for signed-candidate/device testing; it is not yet distributed or device-verified. Physical Android Auto reproduction and normal/denied recovery remain release acceptance conditions.

## Signed candidate and limited physical verification

Source45176b1695047b061673de25db8db2b2867a1f80, Android1.0.17(18), signed APK SHA25672e946a17e672b22b0d00585f9ecb961561fde25b7af2b4fe4d261fb8ff6c085. Local candidate validation passed; GitHub Release has not been published for this build.

The candidate was installed in place onmoto, retaining registration. A finite focus-only helper (no audio capture/playback, no personal-data permissions) obtained focus for10seconds:

- TRANSIENT: READY/enabled→INTERRUPTED/disabled→automaticREADY/enabled after release; no manual recovery.
- PERMANENT: READY/enabled→INTERRUPTED/disabled, remaining interrupted after release as expected. One explicit「音声を再接続」restoredREADY/enabled. OS focus stack contained oneKOEON owner and no other owner.
- Original DHU procedure: USB protocol1.7/TLS1.2 established, no sharing consent accepted, DHU and test-started Android Auto then stopped. The retry action restoredREADY/enabled with oneKOEON focus owner and no other owner, without POWER cycling or re-enrollment.

Fresh22:18:42Z field JSON agrees: CONNECTED/READY/pttEligible=true, audioavailabilityREADY, focusGranted/RX validated, autoRecoveryResultsuccess. The retained latest interruption reason isDUCK; do not classify every DHU event as permanentLOSS. ExplicitPERMANENT behavior was verified separately with the helper. The test helper and diagnostic helper were removed frommoto afterward.

This is limited focus/state verification, not proof of subsequent audible media, actual telephone-call rejection or all vehicle implementations. Denial/stale-callback cases are automated-unit coverage only. Follow-up eight-endpoint transmission and receivedPCM checks remain required. OPPO and fourAVDs are being updated to the same candidate before that retest; the povo network condition is preserved.
