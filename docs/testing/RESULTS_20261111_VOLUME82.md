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
- Local candidate installed in place with registration retained: 32059ffb1bdd3cc2836c2cdb50a45c641c8634ff, APK SHA256 `6e607c9871a183da81a6df509d27f3e7e706430dbfa0af564a3c76318d707a92`.
- Device display checks: Xiaomi Android 16, Bluetooth connected. App minus/plus 8→7→8 / 15; injected OS volume-down 8→7 / 15; foreground return 7/15; Bluetooth OFF 11/11 and ON 7/15; UI matched the OS at every observed checkpoint. Restored 8/15. This run directly observed route-dependent maximum changes; it does not retroactively establish the old incident's exact sequence.
- Shell absolute volume-set was ignored by the OEM during communication; this was an invalid stimulus, excluded from acceptance. The initial test expected 6 after an unapplied set and correctly failed its assertion. The verified rerun used app adjustments and an actual external key-induced change.
- Bluetooth reconnection followed by Xiaomi→Android 15: five consecutive 8-second PTT trials passed TALKING/BUSY_REMOTE and both READY after release. An earlier trial's automatic result was inconclusive because OCR missed the peer READY text; the saved image showed READY. Later trials use structured UI state after release. These are control-state checks, not audible acceptance.
- Android 15→Xiaomi: sender TALKING and receiver BUSY_REMOTE observed at 2 and 5 seconds; receiver diagnostic returned CONNECTED/IDLE/READY. Acoustic delivery is not established.
- New OS baseline is 8/15; sleep setting before this run was 0 and timeout 30000 ms. Restore temporary settings before stopping.
- Merged/distributed: no.

Rollback: update in place to the original signed 1.0.19 (20) APK; do not uninstall or clear registration. NEW6 audio quality, calibrated gain and long-running reliability remain separate from this UI fix.

## Gain and mixed-peer limits

The complete 198-test run includes 19 InputGainProcessor tests: bounded AUTO convergence, negligible/silent input, overload reduction, limiter ceiling, route-isolated profiles, route-change learning cancellation and FloatS16 handling. No gain implementation change was needed for this volume fix.

Device MANUAL +6 dB: pre RMS −63.071255 dBFS, post −57.07126, 344640 samples, limiter hits 0. AUTO: pre −62.752037, post −63.75204, 347040 samples, last applied gain −1 dB, limiter hits 0. The below −60 dBFS observation does not train AUTO upward, consistent with the specified negligible-input gate; this is not calibrated speech convergence or intelligibility evidence. OFF/manual 0/effective 0 restored; the previously learned AUTO profile remains intact.

AUTO control trial 1 passed; trial 2 captured Android 15 peer 1.0.21 (22) temporarily RECONNECTING/OFFLINE, then READY after release. Xiaomi remained TALKING→READY. The trial is failed, not an OCR false negative: its image actually shows OFFLINE. Private diagnostics preserved; later diagnostic showed CONNECTED/READY. The cause is unestablished, and has not been attributed to gain or this display patch. This peer uses a different pre-existing build from the physical candidate. No public claim of NEW6 completion.

## Network shaping calibration

Owned Android 15 AVD only, while the physical device was left in screen-on background wait. A 256 KiB synthetic TCP transfer through the shaped host path measured 92.22 kbps download and 118.08 kbps upload. Both passed the existing 70–145 kbps calibration gate for the 128 kbit/s TBF configuration (8 KiB burst, 1000 ms queue). The wrapper removed its qdiscs/filters with zero cleanup failures; adbd was returned to shell UID 2000. This is host-path TCP calibration, not carrier/UDP/audio quality or a codec recommendation. The later background RX test runs after shaping is removed.

The installed physical base APK was independently hashed over USB and exactly matched the candidate hash above. No registration data was extracted for this identity check.

## Recovery checks

After 905 seconds of screen-on background wait, the peer performed one finite 8-second PTT (TALKING observed at 2 and 5 seconds). Returning to the physical app showed CONNECTED/READY, RX_IDLE and audio READY; journal correlation is recorded below after collection. This does not test PIN lock, Doze, or acoustic playback.

Both Wi-Fi and mobile-data settings were saved as ON, then temporarily disabled. The physical UI showed OFFLINE. Both settings were independently restored and verified ON. Subsequent observations progressed OFFLINE→INTERRUPTED→READY without POWER operations or enrollment changes. Post-recovery Xiaomi→Android15 finite PTT passed TALKING/BUSY_REMOTE and both READY; local counters reached 10 DOWN / 10 UP / 0 CANCEL. This is one bounded recovery sequence, not a general stability guarantee.

## Journal correlation and final disposition

Physical journal: 1379 records, dropped 0, I/O failures 0. The background trial recorded RX_STARTING→RX_ACTIVE→RX_DRAINING→RX_IDLE while lifecycle remained BACKGROUND_OR_LOCKED. The sender's normal app export supplied 2500 records and one matching lease hash. Sender TRANSMITTING→RELEASING lasted approximately 7.297 s; receiver STARTING→IDLE lasted approximately 1.422 s. This is a same-lease control-state duration discrepancy, not acoustic clipping proof; input/DTX and drain trigger remain unresolved. Follow-up [#85](https://github.com/dennomusooffice/koeon-client/issues/85) records evidence, hypotheses and next diagnostics. Do not infer cross-device transport latency from wall-clock offsets.

The AVD export collector initially selected an existing filename from the save-dialog listing instead of the filename EditText. Its stale manifest exposed the mistake. The existing file was restored from the saved copy with matching hash, the current export was retrieved, and the collector now checks EditText and manifest freshness before deleting only its new export. This was a test-tool error, not evidence that the app exported stale data. Physical export freshness was also checked separately. No decryption keys or private credentials were extracted.

Post-network reverse-direction control: sender TALKING and physical receiver BUSY_REMOTE at 2/5 s, then physical CONNECTED/READY. Final physical state was READY, Bluetooth selected, gain OFF/manual 0/effective 0, STANDARD 24 kbps, OS/UI volume 8/15. Stay-awake restored to 0, screen timeout 30000 ms, Wi-Fi/Bluetooth ON; mobile-data restored ON to its separately captured baseline. Owned control forwards 0. Current candidate and registration retained. Newly created device export removed after verified retrieval. Owned Android 15 AVD stopped; no other physical devices operated.

**#82: implemented / automatic checks passed / local candidate installed and display behavior verified / not publicly distributed / not merged.** NEW6 remains ENV_BLOCKED/partial: real headset button, calibrated headset audibility and gain convergence, lock/Doze, full SIM5, codec audio under 128 kbps, transient AVD reconnect and #85 are unresolved or unverified. The physical testing window ended by operator completion before the owner's 06:00 deadline, with usage remaining above the 5% stop threshold. No automatic continuation of physical tests is scheduled.
