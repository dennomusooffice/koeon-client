# Apple accessory event isolation probe

Investigation fixture for [Issue #86](https://github.com/dennomusooffice/koeon-client/issues/86).
**Not a product app entry point. Never add ProbeApp.swift to the product target.**

The fixture creates one Apple PushToTalk channel, enables accessory events, and counts
delegate callbacks. It does not instantiate IntercomSessionController, connect to a
server, acquire a Floor, start LiveKit or an audio engine, capture, or transmit audio.
An OS transmission request is only a control-plane probe. Every successful begin is
stopped after three seconds. Its cache contains only bounded counts, source enum,
status and timestamp; ephemeral push tokens are discarded.

## Controlled procedure

1. Obtain a current device-testing window. Record the normal app build and settings.
2. POWER OFF the normal app and confirm it leaves its Apple channel.
3. Export the required repository commit's `ios/` tree into a temporary directory.
   Replace **only that copy's** `KOEON/App/KOEONApp.swift` with this fixture.
   Build using the existing authorized development app ID/profile and a distinct
   probe build number. Do not create developer-account resources automatically.
4. Verify the signature and PTT entitlement. Install as an update, never uninstall
   or erase the enrolled application. This temporarily replaces the normal UI.
5. Press Join Probe. Require `JOINED_ACCESSORY_ENABLED` before testing. If an old
   channel remains, Leave Probe first; do not treat it as this probe's channel.
6. Control Begin (3s) must produce begin/end and activation callbacks without audio.
   Next have the user press the actual headset button. Compare `handsfree` and
   source, foreground/background separately. A programmatic begin is not proof of
   physical-button delivery. No automatic retry, persistent keepalive or fake RX.
7. Read only `Library/Caches/accessory-probe.json` from this app's container.
   The timestamp changes on events, not on polling. Unchanged counters alone must
   be paired with the user's confirmation of the physical button operation.
8. Leave Probe, verify LEFT, and restore the normal signed app before the window
   ends. Restore the normal POWER and headset settings. Re-check registration and
   READY. End the owned automation session without terminating the restored app.

The normal Action button intent is not part of the probe entry point. Do not use
it while the probe is installed. User credentials/preferences are not modified by
the fixture. If interrupted, the next operator must restore the normal app and
clear the probe channel before claiming normal operation.

2026-11-11 build 1105 used this fixture over product source 0a726e3. Results and
restoration are recorded in `docs/testing/RESULTS_20261111_BLUETOOTH_BUTTON.md`.
