# Android output-volume observation — 2026-11-11

Task: [#82](https://github.com/dennomusooffice/koeon-client/issues/82), R3. Owner authorized implementation and Xiaomi NEW6 testing until 06:00 JST; stop earlier if account remaining usage is below 5%. No public distribution or unrelated feature changes are part of this task.

## Requirement and design

The public 1.0.19 (20), source d38a07db65483387d582f686aee91eee0f5de491, cached VOICE_CALL volume at manager construction and app +/- operations. External volume changes, route-dependent ranges and foreground return could leave the displayed value stale. The OEM reason for the original 11→15 maximum change remains unproven.

Use public AudioManager reads in one foreground-only coroutine, immediately on foreground return and every 500 ms. Background cancels this UI observer without stopping the session or RX. App +/- still adjusts the same VOICE_CALL stream and immediately refreshes. Read maximum/index/maximum, retry once for a changing or invalid range, and show Unavailable after invalid reads or API errors. Do not change audio ownership, PTT/Floor, LiveKit, permissions, registration, or input gain. The API does not provide an atomic snapshot; a subsequent poll corrects route changes occurring outside the read interval.

Acceptance: automatic range/value, API failure, duplicate activation and cancellation tests; device OS/display comparison, +/- restoration, external changes, Bluetooth reconnect, foreground return and normal PTT. The original missing OS baseline is not reconstructed. Capture a new OS baseline before changing volume. Keep raw evidence private, never record actual audio.

## Status

- Implemented: bounded read-only observer and explicit Unavailable UI.
- Automated: 198 Android unit tests, zero failures/skips; lintDebug and assembleDebug successful.
- Candidate: 1.0.19-volume82.1 (20), same application ID and release signer for an in-place local test update. Not a public release.
- Device acceptance: pending. New OS baseline is 8/15; sleep setting before this run was 0 and timeout 30000 ms. Restore temporary settings before stopping.
- Merged/distributed: no.

Rollback: update in place to the original signed 1.0.19 (20) APK; do not uninstall or clear registration. NEW6 audio quality, calibrated gain and long-running reliability remain separate from this UI fix.
